/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Svyrg / pte.rvy tests (RV64 only; run with -cpu rv64,Svyrg=on).
 *
 * Sets up Sv39 paging with 1 GiB gigapage aliases of the RAM at
 * PA 0x80000000, each with different pte.rvy bits, then verifies from
 * S-mode (and M-mode with MPRV=1):
 *
 *  Base mode (sstatus.YRGE=0, the reset state):
 *   - pte.y=1 page: capability loads/stores work normally.
 *   - pte.y=0 page: loads and amoswap.y have the tag cleared (no trap);
 *     stores with a set tag raise CHERI Store/AMO Page Fault (cause 36);
 *     untagged stores are unaffected.
 *   - a page carrying the bits Svyrg allocates may be populated ahead of
 *     time, but using it while they are still reserved raises an ordinary
 *     load page fault (cause 13).
 *
 *  Svyrg mode (after setting sstatus.YRGE, which must be writable):
 *   - rvy=0 page: yr=0/yrg=0 clears loaded tags on ly and amoswap.y;
 *     yw=0 faults tagged stores (same observable behavior as base mode).
 *   - yr=1/yrg=1 S-page: loading or swapping a tagged capability in memory
 *     raises CHERI Load Capability Fault (cause 35) while sstatus.SYRG=0
 *     (generation mismatch) without modifying cd or memory even when yw=1/yd=1
 *     permits stores, whereas loading or swapping an untagged value in memory
 *     only traps if svyrg_traps_conservatively is set, and tagged loads work
 *     normally once SYRG is set.
 *   - yr=0/yrg=0 S-page with SYRG=1: generation mismatch with yr=0 strips
 *     the loaded tag on ly and amoswap.y without faulting.
 *   - non-zero rvy on a non-leaf PTE is reserved and raises cause 13/15.
 *   - yr=1/yrg=0 U-page (via sstatus.SUM): normal while UYRG=0, faults
 *     with cause 35 once UYRG is set (with SYRG still set, proving the
 *     generation is selected by pte.u).
 *   - yw=1/yd=0 page: loads normal (yr=0/yrg=1); storing a tagged
 *     capability via sy or sc.y raises cause 36 unless the authorizing
 *     capability lacks PERM_C (so will_store_tag is false); untagged stores
 *     are unaffected.
 *   - yr=1/yrg=0/yw=0 page, which refuses loads (generation mismatch, 35)
 *     and tagged stores (36) alike: an AMO with a tagged source trips both
 *     and 36 wins, whereas an AMO with x0 raises 35 without modifying memory.
 *   - M-mode with mstatus.MPRV=1 and MPP=S enforces Svyrg load and store
 *     checks.
 *
 * Register use: s2 = tagged root capability, s1 = distinct tagged store
 * capability, s7 (svyrg_conservative) = target_info.svyrg_traps_conservatively,
 * a0-a7 = VA aliases of the test buffer.
 */
#define TEST_NAME "svyrg"
#ifdef CHERI_093
#error "Requires RVY >= 0.9.7 for the 4-bit pte.rvy field and the Svyrg extension"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define svyrg_conservative s7
#pragma GCC poison s7

#define PTE_LEAF_RWAD  (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
#define PTE_LEAF_RWXAD (PTE_LEAF_RWAD | PTE_X)

/* Root table indices for the 1 GiB gigapage aliases of PA 0x80000000. */
#define IDX_CODE         2       /* VA 0x0_80000000: code and data (yd=1) */
#define IDX_RVY0         3       /* VA 0x0_C0000000: rvy = 0 */
#define IDX_YR_YRG_YW_YD 4       /* VA 0x1_00000000: yr|yrg|yw|yd */
#define IDX_USER_YR      5       /* VA 0x1_40000000: U-page, yr|yw|yd (yrg=0) */
#define IDX_YRG_YW       6       /* VA 0x1_80000000: yrg|yw (yd=0) */
#define IDX_YR_ONLY      7       /* VA 0x1_C0000000: yr only */
#define IDX_YW_YD        8       /* VA 0x2_00000000: yw|yd (yr=0, yrg=0) */
#define IDX_NONLEAF_RVY  9       /* VA 0x2_40000000: non-leaf PTE with rvy!=0 */

#define ALIAS_OFF(idx) (((idx) - IDX_CODE) << 30)

.macro SET_LEAF_PTE idx, bits
    li   t2, \bits
    or   t2, t2, t1
    sd   t2, (\idx * 8)(t0)
.endm

.macro SET_ALIAS reg, idx
    li   t0, ALIAS_OFF(\idx)
    add  \reg, a0, t0
.endm

/* Run \insn in M-mode with MPRV=1 and MPP=S, then clear MPRV before checking. */
.macro RUN_MPRV_S insn:vararg
    li   t0, MSTATUS_MPP_MASK
    csrc CSR_MSTATUS, t0
    li   t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs CSR_MSTATUS, t0
    \insn
    csrc CSR_MSTATUS, t0
.endm

.macro CHECK_BUF load_alias, store_alias=a0
    LY   t0, 0(\load_alias)
    EXPECT_CAP_EQ t0, s2
    SY   s2, 0(\store_alias)
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    LOAD_TARGET_FLAG svyrg_conservative, TARGET_INFO_OFF_SVYRG_TRAPS_CONSERVATIVELY

    /* Keep a tagged root capability in s2 and a distinct store capability in s1. */
    csrrs s2, CSR_DDC, x0
    li   t0, 0xdeadbeef
    YADDRW s1, s2, t0

    PMP_ALLOW_ALL

    /* Enable CHERI and U-page access for S-mode. */
    li   t0, MENVCFG_CRE
    csrs CSR_MENVCFG, t0
    li   t0, SSTATUS_SUM
    csrs CSR_MSTATUS, t0

    /*
     * Build the Sv39 root table: gigapage leaves, all mapping
     * PA 0x80000000 (PPN 0x80000 -> PTE PPN field 0x80000 << 10).
     */
    lla  t0, pagetable
    li   t1, 0x80000 << 10
    /*
     * IDX_CODE (code + data) runs before YRGE is set, so it must carry only
     * yd (pte.y); the other Svyrg bits are reserved while YRGE is clear.
     */
    SET_LEAF_PTE IDX_CODE,         PTE_YD_BIT | PTE_LEAF_RWXAD
    SET_LEAF_PTE IDX_RVY0,         PTE_LEAF_RWAD
    SET_LEAF_PTE IDX_YR_YRG_YW_YD, PTE_YR_BIT | PTE_YRG_BIT | PTE_YW_BIT | PTE_YD_BIT | PTE_LEAF_RWAD
    SET_LEAF_PTE IDX_USER_YR,      PTE_YR_BIT | PTE_YW_BIT | PTE_YD_BIT | PTE_LEAF_RWAD | PTE_U
    SET_LEAF_PTE IDX_YRG_YW,       PTE_YRG_BIT | PTE_YW_BIT | PTE_LEAF_RWAD
    SET_LEAF_PTE IDX_YR_ONLY,      PTE_YR_BIT | PTE_LEAF_RWAD
    SET_LEAF_PTE IDX_YW_YD,        PTE_YW_BIT | PTE_YD_BIT | PTE_LEAF_RWAD
    /* Non-leaf PTE (R=W=X=0, V=1) with rvy!=0 (reserved). */
    srli t3, t0, 12
    slli t3, t3, 10
    li   t2, PTE_YD_BIT | PTE_V
    or   t2, t2, t3
    sd   t2, (IDX_NONLEAF_RVY * 8)(t0)

    ENABLE_PAGING pagetable, SATP_SV39
    ENTER_PRIV MSTATUS_MPP_S, s_entry

s_entry:
    /* VA aliases of the test buffer for each mapping */
    lla  a0, buf                 /* IDX_CODE: normal */
    SET_ALIAS a1, IDX_RVY0
    SET_ALIAS a2, IDX_YR_YRG_YW_YD
    SET_ALIAS a3, IDX_USER_YR
    SET_ALIAS a4, IDX_YRG_YW
    SET_ALIAS a5, IDX_YR_ONLY
    SET_ALIAS a6, IDX_YW_YD
    SET_ALIAS a7, IDX_NONLEAF_RVY

    /* Normal page: capability store + load round-trips the tag */
    NEXT_TEST "a normal page round-trips a capability tag"
    SY   s2, 0(a0)
    LY   t1, 0(a0)
    EXPECT_TAG t1, 1

    /* Base mode, pte.y=0: load and amoswap.y clear tag, tagged store faults */
    NEXT_TEST "base mode pte.y=0 clears loaded tags on ly"
    LY   t1, 0(a1)  /* via rvy=0 alias */
    EXPECT_TAG t1, 0

    NEXT_TEST "base mode pte.y=0 clears loaded tags on amoswap.y"
    AMOSWAP_Y t1, a1, x0         /* untagged store succeeds, loaded tag is stripped */
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 0

    NEXT_TEST "base mode pte.y=0 faults tagged sy"
    SY   s2, 0(a0)               /* restore tagged capability in buffer */
    SY   s1, 0(a1)               /* tagged -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF a0

    NEXT_TEST "base mode pte.y=0 faults tagged amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a1, s1         /* tagged amoswap.y -> cause 36 without modifying cd or memory */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a0

    NEXT_TEST "base mode pte.y=0 faults tagged sc.y"
    LR_Y t1, a1
    EXPECT_NO_TRAP
    POISON_REG t1
    SC_Y t1, a1, s1              /* reserved tagged sc.y -> cause 36 without modifying cd or memory */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a0

    NEXT_TEST "base mode pte.y=0 allows untagged sy"
    SY   x0, 0(a1)               /* NULL (untagged) -> no trap */
    EXPECT_NO_TRAP
    /* the untagged store went through: repair the buffer for later tests */
    SY   s2, 0(a0)

    /*
     * a2's PTE already carries yr|yrg|yw|yd for the tests below.
     * Populating it early is fine, but until YRGE is set those bits are
     * reserved, so using the page now must fault like any other reserved
     * PTE bit would.
     */
    NEXT_TEST "a page carrying the Svyrg bits faults ly while they are reserved"
    POISON_REG t1
    LY   t1, 0(a2)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "a page carrying the Svyrg bits faults lr.y while they are reserved"
    POISON_REG t1
    LR_Y t1, a2
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "a page carrying the Svyrg bits faults amoswap.y while they are reserved"
    POISON_REG t1
    AMOSWAP_Y t1, a2, s1
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF a0

    /* Enable Svyrg; the bit must read back as set */
    NEXT_TEST "sstatus.YRGE reads back as set"
    li   t0, SSTATUS_YRGE
    csrs CSR_SSTATUS, t0
    csrr t1, CSR_SSTATUS
    and  t1, t1, t0
    EXPECT_NONZERO t1
    /*
     * Under Svyrg, yr=0/yrg=1 with yw=1/yd=1 is the normal capability R/W
     * encoding; update the code/data gigapage (index 2) from yd alone to
     * yrg|yw|yd now that YRGE is set so capability loads and stores on the
     * image mapping work normally.
     */
    lla  t0, pagetable
    ld   t1, 16(t0)
    li   t2, PTE_YRG_BIT | PTE_YW_BIT
    or   t1, t1, t2
    sd   t1, 16(t0)
    sfence.vma

    /* rvy=0 page under Svyrg behaves like base pte.y=0 */
    NEXT_TEST "rvy=0 under Svyrg clears loaded tags on ly"
    LY   t1, 0(a1)
    EXPECT_TAG t1, 0

    NEXT_TEST "rvy=0 under Svyrg clears loaded tags on amoswap.y"
    AMOSWAP_Y t1, a1, x0
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 0

    NEXT_TEST "rvy=0 under Svyrg faults tagged sy"
    SY   s2, 0(a6)
    SY   s1, 0(a1)  /* tagged -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF a4, a6

    NEXT_TEST "rvy=0 under Svyrg faults tagged amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a1, s1
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    NEXT_TEST "rvy=0 under Svyrg faults tagged sc.y"
    LR_Y t1, a1
    EXPECT_NO_TRAP
    POISON_REG t1
    SC_Y t1, a1, s1
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    /*
     * yr=1/yrg=1 S-page: a tagged capability in memory faults with cause 35
     * while SYRG=0, whereas an untagged value in memory loads and swaps
     * without raising cause 35 unless svyrg_traps_conservatively is set; once
     * SYRG=1 is set, tagged loads succeed too.
     */
    NEXT_TEST "yr=1/yrg=1 faults a tagged ly while SYRG=0"
    POISON_REG t1
    LY   t1, 0(a2)               /* tagged in memory -> cause 35 (mismatch) */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr=1/yrg=1 faults a tagged lr.y while SYRG=0"
    POISON_REG t1
    LR_Y t1, a2
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr=1/yrg=1 allows an untagged ly while SYRG=0"
    li   t0, 0x12345678
    sd   t0, 0(a0)               /* overwrite buffer with untagged data */
    LY   t1, 0(a2)               /* untagged in memory -> no cause 35 unless conservative */
    beqz svyrg_conservative, 1f
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    j    2f
1:  EXPECT_NO_TRAP
    EXPECT_TAG t1, 0
    EXPECT_EQ t1, t0
2:

    NEXT_TEST "yr=1/yrg=1 allows an untagged lr.y while SYRG=0"
    LR_Y t1, a2
    beqz svyrg_conservative, 1f
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    j    2f
1:  EXPECT_NO_TRAP
    EXPECT_TAG t1, 0
    EXPECT_EQ t1, t0
2:

    NEXT_TEST "yr=1/yrg=1 allows amoswap.y when old memory is untagged while SYRG=0"
    AMOSWAP_Y t1, a2, s2         /* old memory is untagged -> no cause 35, stores tagged s2 */
    beqz svyrg_conservative, 1f
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    SY   s2, 0(a6)
    j    2f
1:  EXPECT_NO_TRAP
    EXPECT_TAG t1, 0
    EXPECT_EQ t1, t0
2:

    NEXT_TEST "yr=1/yrg=1 faults a tagged ly again after amoswap.y wrote a tag"
    POISON_REG t1
    LY   t1, 0(a2)               /* memory is now tagged again -> cause 35 */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr=1/yrg=1 faults a tagged lr.y again after amoswap.y wrote a tag"
    POISON_REG t1
    LR_Y t1, a2
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr=1/yrg=1/yw=1/yd=1 faults tagged amoswap.y on tagged memory with cause 35 without modifying cd or memory"
    POISON_REG t1
    AMOSWAP_Y t1, a2, s1         /* store side is permitted (yw=1/yd=1), load side faults (35) */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1          /* cd was not modified */
    CHECK_BUF a4, a6             /* memory still holds s2, not s1 */

    NEXT_TEST "yr=1/yrg=1/yw=1/yd=1 faults untagged amoswap.y on tagged memory with cause 35 without modifying cd or memory"
    POISON_REG t1
    AMOSWAP_Y t1, a2, x0         /* untagged rs2 also faults on the tagged load with no side effect */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    NEXT_TEST "yr=1/yrg=1 allows a tagged load once SYRG=1 matches"
    li   t0, SSTATUS_SYRG
    csrs CSR_SSTATUS, t0         /* SYRG = 1: generations match */
    LY   t1, 0(a2)               /* normal */
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 1

    /* yr=0/yrg=0 with SYRG=1 strips loaded tags on ly and amoswap.y without faulting */
    NEXT_TEST "yr=0/yrg=0 with SYRG=1 strips loaded tags on ly"
    LY   t1, 0(a6)
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 0

    NEXT_TEST "yr=0/yrg=0 with SYRG=1 strips loaded tags on amoswap.y"
    AMOSWAP_Y t1, a6, s2
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 0

    /* Non-zero rvy on a non-leaf PTE is reserved even when YRGE=1 */
    NEXT_TEST "rvy bits on a non-leaf PTE fault ly as reserved"
    POISON_REG t1
    LY   t1, 0(a7)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "rvy bits on a non-leaf PTE fault lr.y as reserved"
    POISON_REG t1
    LR_Y t1, a7
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "rvy bits on a non-leaf PTE fault sy as reserved"
    SY   s1, 0(a7)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF a4, a6

    NEXT_TEST "rvy bits on a non-leaf PTE fault amoswap.y as reserved"
    POISON_REG t1
    AMOSWAP_Y t1, a7, s1
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    /* yr=1/yrg=0 U-page: UYRG (not SYRG) selects the generation */
    NEXT_TEST "yr=1/yrg=0 on a U-page allows a tagged load while UYRG=0 matches"
    LY   t1, 0(a3)  /* UYRG=0 matches yrg=0: normal */
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 1

    NEXT_TEST "yr=1/yrg=0 on a U-page faults a tagged ly once UYRG=1 mismatches"
    li   t0, SSTATUS_UYRG
    csrs CSR_SSTATUS, t0         /* UYRG = 1: mismatch */
    POISON_REG t1
    LY   t1, 0(a3)  /* cause 35 */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr=1/yrg=0 on a U-page faults a tagged lr.y once UYRG=1 mismatches"
    POISON_REG t1
    LR_Y t1, a3
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr=1/yrg=0 on a U-page faults a tagged amoswap.y once UYRG=1 mismatches"
    POISON_REG t1
    AMOSWAP_Y t1, a3, s1
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    /* yw=1/yd=0: loads normal, tagged stores fault, PERM_C=0 stores strip tag and succeed */
    NEXT_TEST "yw=1/yd=0 allows a tagged load"
    LY   t1, 0(a4)  /* yr=0/yrg=1 -> normal */
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 1

    NEXT_TEST "yw=1/yd=0 faults a tagged sy"
    SY   s1, 0(a4)  /* tagged -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF a4, a6

    NEXT_TEST "yw=1/yd=0 faults a tagged amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a4, s1
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    NEXT_TEST "yw=1/yd=0 faults a tagged sc.y"
    LR_Y t1, a4
    POISON_REG t1
    SC_Y t1, a4, s1 /* reserved tagged sc.y -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a4, a6

    NEXT_TEST "yw=1/yd=0 allows an untagged sc.y"
    LR_Y t1, a4
    SC_Y t1, a4, x0 /* reserved untagged sc.y -> succeeds */
    EXPECT_NO_TRAP
    EXPECT_ZERO t1

    NEXT_TEST "yw=1/yd=0 allows a tagged sy when authorizing capability lacks PERM_C"
    YMODESWY
    YADDRW t3, s2, a4
    li   t0, PERM_C
    YPERMC t3, t3, t0            /* t3 lacks PERM_C so will_store_tag is false */
    SY   s2, 0(t3)
    EXPECT_NO_TRAP
    YMODESWI
    LY   t1, 0(a4)
    EXPECT_TAG t1, 0             /* stored without tag */

    /*
     * A page whose rvy field refuses both directions: yrg=0 no longer
     * matches sstatus.SYRG, so capability loads mismatch, and yw=0 refuses
     * tagged capability stores. Put a tagged capability in the buffer
     * through the alias that still permits it, then approach it through
     * this one.
     */
    NEXT_TEST "the alias that still permits it stores a tagged capability"
    SY   s2, 0(a2)               /* index 4 still allows tagged stores */
    EXPECT_NO_TRAP

    NEXT_TEST "yr only: the capability ly mismatches the generation"
    POISON_REG t1
    LY   t1, 0(a5)
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr only: the capability lr.y mismatches the generation"
    POISON_REG t1
    LR_Y t1, a5
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "yr only: the tagged capability store is refused"
    SY   s1, 0(a5)
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF a4, a2

    /*
     * An AMO with a tagged source trips both (yw=0 and yr=1/yrg=0), and the
     * store/AMO page fault (36) wins; with an untagged source (x0), only the
     * load capability fault (35) fires, and neither case modifies cd or memory.
     */
    NEXT_TEST "an AMO with a tagged source trips both and the store page fault wins without modifying cd or memory"
    POISON_REG t1
    AMOSWAP_Y t1, a5, s1
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a4, a2

    NEXT_TEST "control: an AMO with x0 skips the store page fault and takes cause 35 without modifying cd or memory"
    POISON_REG t1
    AMOSWAP_Y t1, a5, x0
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    CHECK_BUF a4, a2

    lla   m_continue, m_done
    ecall
m_done:
    /*
     * In M-mode with mstatus.MPRV=1 and MPP=S, data accesses use S-mode
     * translation and Svyrg generation/tag checks apply. Taking a trap from
     * M-mode overwrites MPP with M and mret then resets MPP to U, so set
     * MPRV=1, MPP=S before each access and clear MPRV before any check that
     * could branch to fail.
     */
    NEXT_TEST "M-mode with MPRV=1 and MPP=S enforces Svyrg ly checks"
    POISON_REG t1
    RUN_MPRV_S LY t1, 0(a5)
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "M-mode with MPRV=1 and MPP=S enforces Svyrg lr.y checks"
    POISON_REG t1
    RUN_MPRV_S LR_Y t1, a5
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1

    NEXT_TEST "M-mode with MPRV=1 and MPP=S enforces Svyrg sy checks"
    RUN_MPRV_S SY s1, 0(a5)
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF a0

    NEXT_TEST "M-mode with MPRV=1 and MPP=S enforces Svyrg tagged amoswap.y checks"
    POISON_REG t1
    RUN_MPRV_S AMOSWAP_Y t1, a5, s1
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF a0

    NEXT_TEST "M-mode with MPRV=1 and MPP=S enforces Svyrg untagged amoswap.y checks"
    POISON_REG t1
    RUN_MPRV_S AMOSWAP_Y t1, a5, x0
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    CHECK_BUF a0

    TEST_PASS
fail:
    /*
     * Everything above runs in S-mode with paging on, where the finisher
     * device is not mapped, so get back to M-mode before reporting.
     */
    li   t0, MSTATUS_MPRV
    lla   m_continue, m_fail
    ecall
m_fail:
    csrc CSR_MSTATUS, t0
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
pagetable:
    .space 4096
.balign 16
buf:
    .space 64

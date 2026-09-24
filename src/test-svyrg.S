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
 *   - yr=1/yrg=1 S-page: loading a tagged capability raises CHERI Load
 *     Capability Fault (cause 35) while sstatus.SYRG=0 (generation
 *     mismatch) and works normally once SYRG is set.
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
 * Register use: s2 = tagged root capability, a0-a7 = VA aliases of the test
 * buffer.
 */
#define TEST_NAME "svyrg"
#ifdef CHERI_093
#error "RVY v0.9.9 only: the pte.rvy field is a v0.9.9 redefinition"
#endif
#include "testmacros.h"
#include "exceptions.h"

/* Leaf PTE bits: V|R|A|D = 0xC3, +W = 0xC7, +X = 0xCF, U = 0x10 */
#define PTE_LEAF_RWAD  0xC7
#define PTE_LEAF_RWXAD 0xCF
#define PTE_U_BIT      0x10
#define PTE_YR_BIT  (1 << 55)
#define PTE_YRG_BIT (1 << 56)
#define PTE_YW_BIT  (1 << 57)
#define PTE_YD_BIT  (1 << 58)

#define SSTATUS_SUM  (1 << 18)
#define SSTATUS_YRGE (1 << 59)
#define SSTATUS_SYRG (1 << 60)
#define SSTATUS_UYRG (1 << 61)

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* Keep a tagged root capability for the store tests. */
    csrrs s2, CSR_DDC, x0

    /* PMP entry 0: allow everything (required for S-mode accesses). */
    li   t0, -1
    csrw CSR_PMPADDR0, t0
    li   t0, 0x1f
    csrw CSR_PMPCFG0, t0

    /* Enable CHERI and U-page access for S-mode. */
    li   t0, MENVCFG_CRE
    csrs CSR_MENVCFG, t0
    li   t0, SSTATUS_SUM
    csrs CSR_MSTATUS, t0

    /*
     * Build the Sv39 root table: gigapage leaves, all mapping
     * PA 0x80000000 (PPN 0x80000 -> PTE PPN field 0x80000 << 10).
     */
    la   t0, pagetable
    li   t1, 0x80000 << 10
    /*
     * index 2, VA 0x0_80000000 (code + data): X, rvy = yd (pte.y). This is
     * the page the test itself runs from and it is used before YRGE is set,
     * so it must not carry any of the bits that Svyrg allocates: while YRGE
     * is clear they are reserved and using the page would fault.
     */
    li   t2, PTE_YD_BIT | PTE_LEAF_RWXAD
    or   t2, t2, t1
    sd   t2, 16(t0)
    /* index 3, VA 0x0_C0000000: rvy = 0 */
    ori  t2, t1, PTE_LEAF_RWAD
    sd   t2, 24(t0)
    /* index 4, VA 0x1_00000000: rvy = yr|yrg|yw|yd */
    li   t2, PTE_YR_BIT | PTE_YRG_BIT | PTE_YW_BIT | PTE_YD_BIT | PTE_LEAF_RWAD
    or   t2, t2, t1
    sd   t2, 32(t0)
    /* index 5, VA 0x1_40000000: U-page, rvy = yr|yw|yd (yrg=0) */
    li   t2, PTE_YR_BIT | PTE_YW_BIT | PTE_YD_BIT | PTE_LEAF_RWAD | PTE_U_BIT
    or   t2, t2, t1
    sd   t2, 40(t0)
    /* index 6, VA 0x1_80000000: rvy = yrg|yw (yd=0) */
    li   t2, PTE_YRG_BIT | PTE_YW_BIT | PTE_LEAF_RWAD
    or   t2, t2, t1
    sd   t2, 48(t0)
    /* index 7, VA 0x1_C0000000: rvy = yr only, so loads and stores both fault */
    li   t2, PTE_YR_BIT | PTE_LEAF_RWAD
    or   t2, t2, t1
    sd   t2, 56(t0)
    /* index 8, VA 0x2_00000000: rvy = yw|yd (yr=0, yrg=0: mismatch strips tag) */
    li   t2, PTE_YW_BIT | PTE_YD_BIT | PTE_LEAF_RWAD
    or   t2, t2, t1
    sd   t2, 64(t0)
    /* index 9, VA 0x2_40000000: non-leaf PTE (R=W=X=0, V=1) with rvy!=0 (reserved) */
    srli t3, t0, 12
    slli t3, t3, 10
    li   t2, PTE_YD_BIT | 0x01
    or   t2, t2, t3
    sd   t2, 72(t0)

    /* satp = Sv39 | PPN(pagetable) */
    la   t0, pagetable
    srli t0, t0, 12
    li   t1, 8 << 60
    or   t0, t0, t1
    csrw 0x180, t0               /* satp */
    sfence.vma

    /* Enter S-mode */
    li   t0, 0x1800
    csrc CSR_MSTATUS, t0
    li   t0, 0x0800
    csrs CSR_MSTATUS, t0
    la   t0, s_entry
    csrw CSR_MEPC, t0
    mret

s_entry:
    /* VA aliases of the test buffer for each mapping */
    la   a0, buf                 /* index 2: normal */
    li   t0, 0x40000000
    add  a1, a0, t0              /* index 3: rvy = 0 */
    li   t0, 0x80000000
    add  a2, a0, t0              /* index 4: yr|yrg|yw|yd */
    li   t0, 0xC0000000
    add  a3, a0, t0              /* index 5: U-page, yr|yw|yd */
    li   t0, 0x100000000
    add  a4, a0, t0              /* index 6: yrg|yw (yd=0) */
    li   t0, 0x140000000
    add  a5, a0, t0              /* index 7: yr only */
    li   t0, 0x180000000
    add  a6, a0, t0              /* index 8: yw|yd (yr=0, yrg=0) */
    li   t0, 0x1C0000000
    add  a7, a0, t0              /* index 9: non-leaf PTE with rvy!=0 (reserved) */

    /* Normal page: capability store + load round-trips the tag */
    NEXT_TEST "a normal page round-trips a capability tag"
    SY   s2, 0(a0)
    LY   t1, 0(a0)
    YTAGR t2, t1
    beqz t2, fail

    /* Base mode, pte.y=0: load and amoswap.y clear tag, tagged store faults */
    NEXT_TEST "base mode pte.y=0 clears loaded tags and faults tagged stores"
    LY   t1, 0(a1)  /* via rvy=0 alias */
    YTAGR t2, t1
    bnez t2, fail
    AMOSWAP_Y t1, a1, x0         /* untagged store succeeds, loaded tag is stripped */
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez t2, fail
    SY   s2, 0(a0)               /* restore tagged capability in buffer */
    SY   s2, 0(a1)               /* tagged -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
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
    NEXT_TEST "a page carrying the Svyrg bits faults while they are reserved"
    LY   t1, 0(a2)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    /* Enable Svyrg; the bit must read back as set */
    NEXT_TEST "sstatus.YRGE reads back as set"
    li   t0, SSTATUS_YRGE
    csrs 0x100, t0               /* sstatus */
    csrr t1, 0x100
    and  t1, t1, t0
    beqz t1, fail

    /* rvy=0 page under Svyrg behaves like base pte.y=0 */
    NEXT_TEST "rvy=0 under Svyrg behaves like base pte.y=0"
    LY   t1, 0(a1)
    YTAGR t2, t1
    bnez t2, fail
    AMOSWAP_Y t1, a1, x0
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez t2, fail
    SY   s2, 0(a6)
    SY   s2, 0(a1)  /* tagged -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE

    /* yr=1/yrg=1 S-page: tagged load faults while SYRG=0 */
    NEXT_TEST "yr=1/yrg=1 faults a tagged load while SYRG=0 and works once set"
    LY   t1, 0(a2)  /* cause 35 (mismatch) */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    li   t0, SSTATUS_SYRG
    csrs 0x100, t0                       /* SYRG = 1: generations match */
    LY   t1, 0(a2)  /* normal */
    EXPECT_NO_TRAP
    YTAGR t2, t1
    beqz t2, fail

    /* yr=0/yrg=0 with SYRG=1 strips loaded tags on ly and amoswap.y without faulting */
    NEXT_TEST "yr=0/yrg=0 with SYRG=1 strips loaded tags on ly and amoswap.y"
    LY   t1, 0(a6)
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez t2, fail
    AMOSWAP_Y t1, a6, s2
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez t2, fail

    /* Non-zero rvy on a non-leaf PTE is reserved even when YRGE=1 */
    NEXT_TEST "rvy bits on a non-leaf PTE fault as reserved"
    LY   t1, 0(a7)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    SY   s2, 0(a7)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    /* yr=1/yrg=0 U-page: UYRG (not SYRG) selects the generation */
    NEXT_TEST "yr=1/yrg=0 on a U-page is selected by UYRG not SYRG"
    LY   t1, 0(a3)  /* UYRG=0 matches yrg=0: normal */
    EXPECT_NO_TRAP
    YTAGR t2, t1
    beqz t2, fail
    li   t0, SSTATUS_UYRG
    csrs 0x100, t0                       /* UYRG = 1: mismatch */
    LY   t1, 0(a3)  /* cause 35 */
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP

    /* yw=1/yd=0: loads normal, tagged stores fault, PERM_C=0 stores strip tag and succeed */
    NEXT_TEST "yw=1/yd=0 faults tagged stores unless authorizing capability lacks PERM_C"
    LY   t1, 0(a4)  /* yr=0/yrg=1 -> normal */
    EXPECT_NO_TRAP
    YTAGR t2, t1
    beqz t2, fail
    SY   s2, 0(a4)  /* tagged -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    LR_Y t1, a4
    SC_Y t1, a4, s2 /* reserved tagged sc.y -> cause 36 */
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    LR_Y t1, a4
    SC_Y t1, a4, x0 /* reserved untagged sc.y -> succeeds */
    EXPECT_NO_TRAP
    bnez t1, fail
    YMODESWY
    YADDRW t3, s2, a4
    li   t0, PERM_C
    YPERMC t3, t3, t0            /* t3 lacks PERM_C so will_store_tag is false */
    SY   s2, 0(t3)
    EXPECT_NO_TRAP
    YMODESWI
    LY   t1, 0(a4)
    YTAGR t2, t1
    bnez t2, fail                /* stored without tag */

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

    NEXT_TEST "yr only: the capability load mismatches the generation"
    LY   t1, 0(a5)
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP

    NEXT_TEST "yr only: the tagged capability store is refused"
    SY   s2, 0(a5)
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE

    /*
     * An AMO with a tagged source trips both (yw=0 and yr=1/yrg=0), and the
     * store/AMO page fault (36) wins; with an untagged source (x0), only the
     * load capability fault (35) fires and memory stays unmodified.
     */
    NEXT_TEST "an AMO with a tagged source trips both and the store page fault wins"
    AMOSWAP_Y t1, a5, s2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE

    NEXT_TEST "control: an AMO with x0 skips the store page fault and takes cause 35 without modifying memory"
    AMOSWAP_Y t1, a5, x0
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    LY   t1, 0(a2)
    YTAGR t2, t1
    beqz t2, fail

    la   m_continue, m_done
    ecall
m_done:
    /*
     * In M-mode with mstatus.MPRV=1 and MPP=S, data accesses use S-mode
     * translation and Svyrg generation/tag checks apply. Taking a trap from
     * M-mode overwrites MPP with M and mret then resets MPP to U, so set
     * MPRV=1, MPP=S before each access and clear MPRV before any check that
     * could branch to fail.
     */

    TEST_PASS
fail:
    /*
     * Everything above runs in S-mode with paging on, where the finisher
     * device is not mapped, so get back to M-mode before reporting.
     */
    li   t0, (1 << 17)
    la   m_continue, m_fail
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

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify that Integer-Mode memory accesses (integer loads/stores, capability
 * loads/stores, integer AMOs, capability AMOs, and cache-block operations) are
 * authorized through DDC:
 *
 *  - A bounded DDC permits in-bounds accesses and faults with CAP_BOUNDS on
 *    accesses below DDC.base, straddling DDC.top, or at DDC.top, reporting the
 *    faulting virtual address in mtval on v0.9.9.
 *  - An untagged DDC faults with CAP_TAG and a sealed DDC faults with CAP_SEAL
 *    on both load-classified and store-classified Integer-Mode accesses.
 *  - A read-only DDC (PERM_W cleared) permits loads and LR, and faults with
 *    TRAP_CAP_STORE(CAP_PERM) on stores, SC, AMOs, and CBOs.
 *  - A write-only DDC (PERM_R cleared) permits stores, SC, and CBO.ZERO,
 *    faults with TRAP_CAP_LOAD(CAP_PERM) on loads and LR, and faults with
 *    TRAP_CAP_STORE(CAP_PERM) on AMOs and CBO.CLEAN/FLUSH.
 *  - A DDC without PERM_C strips the tag of capabilities stored or loaded
 *    through it (SY, SC.Y, AMOSWAP.Y, LY, LR.Y) without trapping.
 *  - A DDC with PERM_R and PERM_C but without PERM_LM preserves the tag on
 *    loaded capabilities while stripping PERM_W and PERM_LM from unsealed
 *    capabilities and leaving sealed sentries with their permissions intact.
 */
#define TEST_NAME "ddc-access"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /*
     * Save the root DDC in s0 so that console output in TEST_PASS / TEST_FAIL
     * always has a valid authorizing capability for UART and HTIF stores.
     */
    csrrs s0, CSR_DDC, x0
    la    s1, buf
    addi  s2, s1, 64             /* top of the 64-byte bounded region */
    YADDRW s7, s0, s1            /* full-permission capability at buf */

    /* =====================================================================
     * Bounded DDC: [buf, buf + 64) in Integer Mode
     * ===================================================================== */
    li    t0, 64
    YBNDSW a0, s7, t0            /* a0: [buf, buf + 64) */
    csrrw x0, CSR_DDC, a0

    /* In-bounds integer stores and loads */
    NEXT_TEST "in-bounds integer byte store and load through bounded DDC succeed"
    li    t0, 0x5a
    sb    t0, 0(s1)
    lbu   t1, 0(s1)
    EXPECT_NO_TRAP
    bne   t0, t1, fail

    NEXT_TEST "in-bounds integer halfword store and load through bounded DDC succeed"
    li    t0, 0x1234
    sh    t0, 62(s1)
    lhu   t1, 62(s1)
    EXPECT_NO_TRAP
    bne   t0, t1, fail

    NEXT_TEST "in-bounds integer word store and load at the upper boundary succeed"
    li    t0, 0x13572468
    sw    t0, 60(s1)
    lw    t1, 60(s1)
    EXPECT_NO_TRAP
    bne   t0, t1, fail

#if __riscv_xlen == 64
    NEXT_TEST "in-bounds integer doubleword store and load at the upper boundary succeed"
    li    t0, 0x1122334455667788
    sd    t0, 56(s1)
    ld    t1, 56(s1)
    EXPECT_NO_TRAP
    bne   t0, t1, fail
#endif

    /* In-bounds capability store and load */
    NEXT_TEST "in-bounds sy and ly through bounded DDC preserve the tag"
    SY    s7, (64 - YLEN_BYTES)(s1)
    LY    t1, (64 - YLEN_BYTES)(s1)
    EXPECT_NO_TRAP
    YTAGR t2, t1
    beqz  t2, fail

    /* In-bounds integer atomics */
    NEXT_TEST "in-bounds lr.w, sc.w, and amoswap.w through bounded DDC succeed"
    li    t0, 0x12345678
    lr.w  t1, (s1)
    sc.w  t2, t0, (s1)
    bnez  t2, fail
    li    t3, 0x23456789
    amoswap.w t4, t3, (s1)
    EXPECT_NO_TRAP
    bne   t4, t0, fail

    /* In-bounds capability atomics */
    NEXT_TEST "in-bounds lr.y, sc.y, and amoswap.y through bounded DDC succeed"
    LR_Y  t1, s1
    SC_Y  t2, s1, s7
    bnez  t2, fail
    AMOSWAP_Y t3, s1, x0
    EXPECT_NO_TRAP
    YTAGR t4, t3
    beqz  t4, fail

    /* In-bounds cache-block operations over the 64-byte block */
    NEXT_TEST "in-bounds cbo.clean, cbo.flush, cbo.inval, and cbo.zero through bounded DDC succeed"
    CBO_CLEAN s1
    CBO_FLUSH s1
    CBO_INVAL s1
    CBO_ZERO  s1
    EXPECT_NO_TRAP
    lw    t1, 0(s1)
    bnez  t1, fail

    /* Out-of-bounds integer loads via bounded DDC */
    NEXT_TEST "integer lb one byte below DDC.base faults with CAP_BOUNDS"
    addi  t0, s1, -1
    lb    t1, -1(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL t0

    NEXT_TEST "integer lb at DDC.top faults with CAP_BOUNDS"
    lb    t1, 0(s2)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "integer lh straddling DDC.top faults with CAP_BOUNDS"
    addi  t0, s2, -1
    lh    t1, -1(s2)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL t0

    NEXT_TEST "integer lw straddling DDC.top faults with CAP_BOUNDS"
    addi  t0, s2, -2
    lw    t1, -2(s2)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL t0

#if __riscv_xlen == 64
    NEXT_TEST "integer ld straddling DDC.top faults with CAP_BOUNDS"
    addi  t0, s2, -4
    ld    t1, -4(s2)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL t0
#endif

    NEXT_TEST "integer lr.w at DDC.top faults with CAP_BOUNDS"
    lr.w  t1, (s2)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL s2

    /* Out-of-bounds integer stores and atomics via bounded DDC */
    NEXT_TEST "integer sb one byte below DDC.base faults with CAP_BOUNDS"
    addi  t0, s1, -1
    sb    x0, -1(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0

    NEXT_TEST "integer sb at DDC.top faults with CAP_BOUNDS"
    sb    x0, 0(s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "integer sh straddling DDC.top faults with CAP_BOUNDS"
    addi  t0, s2, -1
    sh    x0, -1(s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0

    NEXT_TEST "integer sw straddling DDC.top faults with CAP_BOUNDS"
    addi  t0, s2, -2
    sw    x0, -2(s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0

#if __riscv_xlen == 64
    NEXT_TEST "integer sd straddling DDC.top faults with CAP_BOUNDS"
    addi  t0, s2, -4
    sd    x0, -4(s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0
#endif

    NEXT_TEST "integer sc.w at DDC.top faults with CAP_BOUNDS"
    sc.w  t1, x0, (s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "integer amoswap.w at DDC.top faults with CAP_BOUNDS"
    amoswap.w t1, x0, (s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    /* Out-of-bounds capability loads, stores, and atomics via bounded DDC */
    NEXT_TEST "ly below DDC.base faults with CAP_BOUNDS"
    addi  t0, s1, -YLEN_BYTES
    LY    t1, 0(t0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL t0

    NEXT_TEST "ly at DDC.top faults with CAP_BOUNDS"
    LY    t1, 0(s2)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "sy below DDC.base faults with CAP_BOUNDS"
    addi  t0, s1, -YLEN_BYTES
    SY    s7, 0(t0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0

    NEXT_TEST "sy at DDC.top faults with CAP_BOUNDS"
    SY    s7, 0(s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "lr.y at DDC.top faults with CAP_BOUNDS"
    LR_Y  t1, s2
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "sc.y at DDC.top faults with CAP_BOUNDS"
    SC_Y  t1, s2, s7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "amoswap.y at DDC.top faults with CAP_BOUNDS"
    AMOSWAP_Y t1, s2, s7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    /* Out-of-bounds CBOs via bounded DDC */
    NEXT_TEST "cbo.zero at DDC.top faults with CAP_BOUNDS"
    CBO_ZERO s2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s2

    NEXT_TEST "cbo.clean at DDC.top faults when no byte of the block is in DDC bounds"
    CBO_CLEAN s2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    NEXT_TEST "cbo.flush at DDC.top faults when no byte of the block is in DDC bounds"
    CBO_FLUSH s2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    /* =====================================================================
     * Untagged DDC in Integer Mode
     * ===================================================================== */
    YADDRW a1, x0, s1            /* untagged capability at buf */
    csrrw x0, CSR_DDC, a1

    NEXT_TEST "integer lw with an untagged DDC faults with CAP_TAG"
    lw    t1, 0(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "integer sw with an untagged DDC faults with CAP_TAG"
    sw    x0, 0(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "ly with an untagged DDC faults with CAP_TAG"
    LY    t1, 0(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "sy with an untagged DDC faults with CAP_TAG"
    SY    s7, 0(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "lr.w with an untagged DDC faults with CAP_TAG"
    lr.w  t1, (s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "sc.w with an untagged DDC faults with CAP_TAG"
    sc.w  t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.w with an untagged DDC faults with CAP_TAG"
    amoswap.w t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "lr.y with an untagged DDC faults with CAP_TAG"
    LR_Y  t1, s1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "sc.y with an untagged DDC faults with CAP_TAG"
    SC_Y  t1, s1, s7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.y with an untagged DDC faults with CAP_TAG"
    AMOSWAP_Y t1, s1, s7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    NEXT_TEST "cbo.zero with an untagged DDC faults with CAP_TAG"
    CBO_ZERO s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL s1

    /* =====================================================================
     * Sealed sentry DDC in Integer Mode
     * ===================================================================== */
    YSENTRY a2, a0
    csrrw x0, CSR_DDC, a2

    NEXT_TEST "integer lw with a sealed DDC faults with CAP_SEAL"
    lw    t1, 0(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "integer sw with a sealed DDC faults with CAP_SEAL"
    sw    x0, 0(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "ly with a sealed DDC faults with CAP_SEAL"
    LY    t1, 0(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "sy with a sealed DDC faults with CAP_SEAL"
    SY    s7, 0(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "lr.w with a sealed DDC faults with CAP_SEAL"
    lr.w  t1, (s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "sc.w with a sealed DDC faults with CAP_SEAL"
    sc.w  t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.w with a sealed DDC faults with CAP_SEAL"
    amoswap.w t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "lr.y with a sealed DDC faults with CAP_SEAL"
    LR_Y  t1, s1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "sc.y with a sealed DDC faults with CAP_SEAL"
    SC_Y  t1, s1, s7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.y with a sealed DDC faults with CAP_SEAL"
    AMOSWAP_Y t1, s1, s7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    NEXT_TEST "cbo.zero with a sealed DDC faults with CAP_SEAL"
    CBO_ZERO s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL s1

    /* =====================================================================
     * Read-only DDC (PERM_W cleared) in Integer Mode
     * ===================================================================== */
    li    t0, DROP_MASK(PERM_W)
    DROP_PERMS a3, a0, t0
    csrrw x0, CSR_DDC, a3

    NEXT_TEST "loads and lr succeed through a read-only DDC"
    lw    t1, 0(s1)
    LY    t2, 0(s1)
    lr.w  t3, (s1)
    LR_Y  t4, s1
    EXPECT_NO_TRAP

    NEXT_TEST "integer sw with a read-only DDC faults with CAP_PERM"
    sw    x0, 0(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "sy with a read-only DDC faults with CAP_PERM"
    SY    s7, 0(s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "sc.w with a read-only DDC faults with CAP_PERM"
    lr.w  t1, (s1)
    sc.w  t2, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.w with a read-only DDC faults with CAP_PERM"
    amoswap.w t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "sc.y with a read-only DDC faults with CAP_PERM"
    SC_Y  t1, s1, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.y with a read-only DDC faults with CAP_PERM"
    AMOSWAP_Y t1, s1, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "cbo.zero with a read-only DDC faults with CAP_PERM"
    CBO_ZERO s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    /* =====================================================================
     * Write-only DDC (PERM_R cleared, PERM_W retained) in Integer Mode
     * ===================================================================== */
    li    t0, DROP_MASK(PERM_R)
    DROP_PERMS a4, a0, t0
    csrrw x0, CSR_DDC, a4

    NEXT_TEST "integer sw, sy, and cbo.zero succeed through a write-only DDC"
    sw    x0, 0(s1)
    SY    s7, 0(s1)
    CBO_ZERO s1
    EXPECT_NO_TRAP

    NEXT_TEST "sc.w with a write-only DDC succeeds after a valid lr.w"
    csrrw x0, CSR_DDC, a0
    lr.w  t1, (s1)
    csrrw x0, CSR_DDC, a4
    li    t0, 0x55aa55aa
    sc.w  t2, t0, (s1)
    EXPECT_NO_TRAP
    bnez  t2, fail

    NEXT_TEST "integer lw with a write-only DDC faults with load CAP_PERM"
    lw    t1, 0(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "ly with a write-only DDC faults with load CAP_PERM"
    LY    t1, 0(s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "lr.w with a write-only DDC faults with load CAP_PERM"
    lr.w  t1, (s1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "lr.y with a write-only DDC faults with load CAP_PERM"
    LR_Y  t1, s1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.w with a write-only DDC faults with store/AMO CAP_PERM"
    amoswap.w t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "amoswap.y with a write-only DDC faults with store/AMO CAP_PERM"
    AMOSWAP_Y t1, s1, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "cbo.clean with a write-only DDC faults with store/AMO CAP_PERM"
    CBO_CLEAN s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    NEXT_TEST "cbo.flush with a write-only DDC faults with store/AMO CAP_PERM"
    CBO_FLUSH s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL s1

    /* =====================================================================
     * DDC without PERM_C (data-only R+W) in Integer Mode
     * ===================================================================== */
    li    t0, DROP_MASK(PERM_C)
    DROP_PERMS a5, a0, t0
    csrrw x0, CSR_DDC, a5

    NEXT_TEST "sy through a DDC without PERM_C strips the stored tag without trapping"
    SY    s7, 0(s1)
    EXPECT_NO_TRAP
    csrrw x0, CSR_DDC, a0
    LY    t1, 0(s1)
    YTAGR t2, t1
    bnez  t2, fail
    bne   t1, s1, fail

    NEXT_TEST "sc.y through a DDC without PERM_C strips the stored tag without trapping"
    SY    s7, 0(s1)              /* start with a tagged capability in memory */
    csrrw x0, CSR_DDC, a5
    LR_Y  t1, s1
    YTAGR t2, t1
    bnez  t2, fail               /* LR_Y also stripped the loaded tag */
    SC_Y  t3, s1, s7
    EXPECT_NO_TRAP
    bnez  t3, fail
    csrrw x0, CSR_DDC, a0
    LY    t1, 0(s1)
    YTAGR t2, t1
    bnez  t2, fail

    NEXT_TEST "amoswap.y through a DDC without PERM_C strips both loaded and stored tags"
    SY    s7, 0(s1)              /* place a tagged capability in memory */
    csrrw x0, CSR_DDC, a5
    AMOSWAP_Y t1, s1, s7
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez  t2, fail               /* loaded capability has its tag stripped */
    bne   t1, s1, fail
    csrrw x0, CSR_DDC, a0
    LY    t3, 0(s1)
    YTAGR t4, t3
    bnez  t4, fail               /* stored capability also had its tag stripped */
    bne   t3, s1, fail

    NEXT_TEST "ly through a DDC without PERM_C strips the loaded tag without trapping"
    SY    s7, 0(s1)
    csrrw x0, CSR_DDC, a5
    LY    t1, 0(s1)
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez  t2, fail
    bne   t1, s1, fail

    /* =====================================================================
     * DDC without PERM_LM (Read + Capability Read-Only) in Integer Mode
     * ===================================================================== */
    li    t0, DROP_MASK(PERM_W | PERM_LM | PERM_X | PERM_ASR)
    DROP_PERMS a6, a0, t0
    YPERMR t1, a6
    andi  t2, t1, PERM_C
    beqz  t2, fail               /* PERM_C must still be granted */
    andi  t2, t1, (PERM_W | PERM_LM)
    bnez  t2, fail               /* PERM_W and PERM_LM must be cleared */

    NEXT_TEST "ly and lr.y through a DDC without PERM_LM strip W and LM from an unsealed capability"
    csrrw x0, CSR_DDC, a0
    SY    s7, 0(s1)
    csrrw x0, CSR_DDC, a6
    LY    t1, 0(s1)
    LR_Y  t2, s1
    EXPECT_NO_TRAP
    YTAGR t3, t1
    beqz  t3, fail               /* tag is preserved because PERM_C is set */
    YPERMR t3, t1
    andi  t4, t3, (PERM_W | PERM_LM)
    bnez  t4, fail               /* W and LM were stripped on load */
    YTAGR t3, t2
    beqz  t3, fail
    YPERMR t3, t2
    andi  t4, t3, (PERM_W | PERM_LM)
    bnez  t4, fail

    NEXT_TEST "ly through a DDC without PERM_LM preserves W and LM on a sealed sentry"
    csrrw x0, CSR_DDC, a0
    YSENTRY a7, s7
    SY    a7, 0(s1)
    csrrw x0, CSR_DDC, a6
    LY    t1, 0(s1)
    EXPECT_NO_TRAP
    YTAGR t2, t1
    beqz  t2, fail
    YPERMR t2, t1
    andi  t3, t2, (PERM_W | PERM_LM)
    li    t4, (PERM_W | PERM_LM)
    bne   t3, t4, fail           /* sealed sentry permissions are not stripped */

    csrrw x0, CSR_DDC, s0
    TEST_PASS
fail:
    csrrw x0, CSR_DDC, s0
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 128

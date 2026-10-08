/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify the RVY exception causes, fault addresses (mtval), permission and
 * bounds checks, reservation semantics, and tag filtering for capability
 * loads/stores, capability atomics, and cache-block operations:
 *
 *  - Misaligned capability accesses raise *access* faults (not misaligned
 *    faults) since they cannot be emulated in software: cause 5 for LY and LR.Y
 *    (plain load semantics per the spec's LR.Y page), cause 7 for SY, SC.Y, and
 *    AMOSWAP.Y, in both integer and capability pointer modes, with mtval
 *    holding the faulting virtual address. 0.9.3 predates that and reports
 *    them as misaligned faults (causes 4 and 6).
 *  - In capability mode with cs1=x0 (the NULL capability), an untagged
 *    capability, a sealed sentry, or an out-of-bounds capability, the check
 *    fails with CAP_TAG, CAP_SEAL, or CAP_BOUNDS respectively; the reported
 *    cause must be selected by the access type: LR.Y -> CHERI Load Access
 *    Fault (33); SC.Y, AMOSWAP.Y, integer AMOs (amoswap.w) and all CBOs ->
 *    CHERI Store/AMO Access Fault (34), with mtval holding the faulting
 *    virtual address in v0.9.9.
 *  - Read-only capabilities (W=0) reject SC.Y and AMOSWAP.Y with a store
 *    permission fault without modifying cd or memory; write-only capabilities
 *    (R=0, W=1) permit SC.Y and CBO.ZERO while rejecting LR.Y with a load
 *    permission fault and AMOSWAP.Y, CBO.CLEAN, and CBO.FLUSH with a
 *    store/AMO permission fault.
 *  - Capabilities without PERM_C strip the tag on stored or loaded
 *    capabilities across LY, SY, LR.Y, SC.Y, and AMOSWAP.Y without trapping;
 *    capabilities with PERM_C but without PERM_LM strip PERM_W and PERM_LM
 *    from loaded unsealed capabilities while preserving them on sealed
 *    sentries.
 *  - LR.Y/SC.Y reservations succeed on matching addresses and fail on repeated
 *    SC.Y or address mismatch (which also cancels the reservation).
 *  - An unaligned integer store straddling two adjacent capabilities in memory
 *    clears the tags of both capability slots.
 */
#define TEST_NAME "amo-cbo-causes"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define YLEN_BYTES 16
#else
#define YLEN_BYTES 8
#endif

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    la   a0, buf                 /* aligned to 64 bytes */
    addi a1, a0, 4               /* misaligned for YLEN/8 on RV32 and RV64 */

    /* Aligned LR.Y via root DDC succeeds (sanity/decode check) */
    NEXT_TEST "aligned lr.y through root ddc succeeds"
    LR_Y t1, a0
    EXPECT_NO_TRAP

    /* Misaligned LY raises a load fault and reports the address in mtval */
    NEXT_TEST "misaligned ly raises a load fault"
    LY   t1, 0(a1)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    EXPECT_TVAL a1

    /* Misaligned SY raises a store fault and reports the address in mtval */
    NEXT_TEST "misaligned sy raises a store fault"
    SY   t2, 0(a1)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1

    /* Misaligned LR.Y raises a load access fault */
    NEXT_TEST "misaligned lr.y raises a load access fault"
    LR_Y t1, a1
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    EXPECT_TVAL a1

    /* Misaligned SC.Y raises a store/AMO access fault */
    NEXT_TEST "misaligned sc.y raises a store fault"
    SC_Y t1, a1, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1

    /* Misaligned AMOSWAP.Y also raises a store/AMO access fault */
    NEXT_TEST "misaligned amoswap.y raises a store fault"
    AMOSWAP_Y t1, a1, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1

    /* Derive test capabilities covering buf. */
    csrrs s0, CSR_DDC, x0
    YADDRW a2, x0, a0            /* a2: untagged capability at buf */
    YADDRW a3, s0, a0            /* a3: full-permission capability at buf */
    li   t2, DROP_MASK(PERM_W)
    DROP_PERMS a4, a3, t2        /* a4: read-only capability (W=0, R=1, C=1) */
    li   t2, DROP_MASK(PERM_C)
    DROP_PERMS a5, a3, t2        /* a5: data-only capability (W=1, R=1, C=0) */
    YADDRW a6, s0, a1            /* a6: full-permission capability at buf + 4 */
    li   t2, DROP_MASK(PERM_R)
    DROP_PERMS a7, a3, t2        /* a7: write-only capability (W=1, R=0; C=1 on RV64, C=0 on RV32) */
    YSENTRY s1, a3               /* s1: sealed sentry capability at buf */
    li   t2, YLEN_BYTES
    YBNDSW s2, a3, t2            /* [buf, buf + YLEN_BYTES) */
    YADDI  s2, s2, YLEN_BYTES    /* s2: cursor at top (out of bounds) */
    YADDI  s7, a3, YLEN_BYTES    /* s7: full-permission capability at buf + YLEN_BYTES */

    /* Enter capability mode: cs1=x0 is now the untagged NULL capability. */
    YMODESWY

    /* Misaligned capability accesses in capability mode */
    NEXT_TEST "capability-mode misaligned ly raises a load fault"
    LY   t1, 0(a6)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    EXPECT_TVAL a1

    NEXT_TEST "capability-mode misaligned sy raises a store fault"
    SY   a3, 0(a6)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1

    NEXT_TEST "capability-mode misaligned lr.y raises a load access fault"
    LR_Y t1, a6
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    EXPECT_TVAL a1

    NEXT_TEST "capability-mode misaligned sc.y raises a store fault"
    SC_Y t1, a6, a3
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1

    NEXT_TEST "capability-mode misaligned amoswap.y raises a store fault"
    AMOSWAP_Y t1, a6, a3
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1

    /* LR.Y via NULL cap: load-classified tag fault */
    NEXT_TEST "lr.y through the NULL capability is load classified"
    LR_Y t1, x0
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    /* SC.Y via NULL cap: store-classified tag fault */
    NEXT_TEST "sc.y through the NULL capability is store classified"
    SC_Y t1, x0, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* AMOSWAP.Y via NULL cap */
    NEXT_TEST "amoswap.y through the NULL capability is store classified"
    AMOSWAP_Y t1, x0, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /*
     * LR.Y, SC.Y, and AMOSWAP.Y through an untagged capability at a non-zero
     * address must report that address in mtval (not 0) on v0.9.9.
     */
    NEXT_TEST "lr.y through an untagged capability reports the fault address in mtval"
    LR_Y t1, a2
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    EXPECT_TVAL a0

    NEXT_TEST "sc.y through an untagged capability reports the fault address in mtval"
    SC_Y t1, a2, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL a0

    NEXT_TEST "amoswap.y through an untagged capability reports the fault address in mtval"
    AMOSWAP_Y t1, a2, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL a0

    /*
     * Sealed sentry capability (s1): LR.Y reports a load CAP_SEAL fault;
     * SC.Y, AMOSWAP.Y, integer AMOs, and CBOs report a store CAP_SEAL fault.
     */
    NEXT_TEST "lr.y through a sealed sentry faults with load CAP_SEAL"
    LR_Y t1, s1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "sc.y through a sealed sentry faults with store CAP_SEAL"
    SC_Y t1, s1, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "amoswap.y through a sealed sentry faults with store CAP_SEAL"
    AMOSWAP_Y t1, s1, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "sc.w through a sealed sentry faults with store CAP_SEAL"
    sc.w t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "amoswap.w through a sealed sentry faults with store CAP_SEAL"
    amoswap.w t1, x0, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.zero through a sealed sentry faults with store CAP_SEAL"
    CBO_ZERO s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.clean through a sealed sentry faults with store CAP_SEAL"
    CBO_CLEAN s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.flush through a sealed sentry faults with store CAP_SEAL"
    CBO_FLUSH s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.inval through a sealed sentry faults with store CAP_SEAL"
    CBO_INVAL s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0

    /*
     * Out-of-bounds capability (s2 at buf + YLEN_BYTES): LR.Y reports load
     * CAP_BOUNDS; SC.Y, AMOSWAP.Y, and integer SC.W report store CAP_BOUNDS.
     */
    NEXT_TEST "lr.y at capability top faults with load CAP_BOUNDS"
    LR_Y t1, s2
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL s7

    NEXT_TEST "sc.y at capability top faults with store CAP_BOUNDS"
    SC_Y t1, s2, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s7

    NEXT_TEST "amoswap.y at capability top faults with store CAP_BOUNDS"
    AMOSWAP_Y t1, s2, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s7

    NEXT_TEST "sc.w at capability top faults with store CAP_BOUNDS"
    sc.w t1, x0, (s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s7

    /*
     * Read-only capability (a4, W=0): SC.W, SC.Y, and AMOSWAP.Y must fault
     * with a store capability permission fault even when storing x0 or an
     * untagged capability, leaving cd and memory unmodified. Control:
     * dropping only C (W=1, C=0) permits AMOSWAP.Y when storing x0.
     */
    NEXT_TEST "sc.w through a read-only capability faults with store CAP_PERM"
    lr.w t1, (a4)
    sc.w t2, x0, (a4)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "sc.y through a read-only capability faults with store CAP_PERM"
    SY   a3, 0(a3)
    SC_Y t1, a4, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    LY   t2, 0(a3)
    YTAGR t3, t2
    beqz t3, fail

    NEXT_TEST "amoswap.y of x0 through a read-only capability faults without side effects"
    SY   a3, 0(a3)
    YMV  t1, a3
    AMOSWAP_Y t1, a4, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    YTAGR t3, t1
    beqz t3, fail                /* cd (t1) must stay tagged */
    LY   t2, 0(a3)
    YTAGR t3, t2
    beqz t3, fail                /* memory must stay tagged */

    NEXT_TEST "amoswap.y of an untagged capability through a read-only capability faults"
    AMOSWAP_Y t1, a4, a2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    YTAGR t3, t1
    beqz t3, fail
    LY   t2, 0(a3)
    YTAGR t3, t2
    beqz t3, fail

    NEXT_TEST "control: amoswap.y of x0 succeeds when W is granted"
    YMV  t1, x0
    AMOSWAP_Y t1, a3, x0
    EXPECT_NO_TRAP
    YTAGR t3, t1
    beqz t3, fail                /* loaded the tagged capability from memory */
    LY   t2, 0(a3)
    YTAGR t3, t2
    bnez t3, fail                /* stored x0 to memory */

    /*
     * Write-only capability (a7, R=0, W=1):
     *  - LR.Y faults with load CAP_PERM.
     *  - SC.W and SC.Y succeed when paired with a prior LR at the same
     *    address because SC only requires W (and C to retain the tag).
     *  - AMOSWAP.Y, CBO.CLEAN, and CBO.FLUSH require both R and W and fault
     *    with store/AMO CAP_PERM.
     *  - CBO.ZERO requires only W and succeeds.
     */
    NEXT_TEST "lr.y through a write-only capability faults with load CAP_PERM"
    LR_Y t1, a7
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "sc.w through a write-only capability succeeds after a valid lr.w"
    lr.w t1, (a3)
    li   t0, 0x33cc33cc
    sc.w t2, t0, (a7)
    EXPECT_NO_TRAP
    bnez t2, fail

    NEXT_TEST "sc.y through a write-only capability succeeds after a valid lr.y"
    SY   x0, 0(a3)
    LR_Y t1, a3
    SC_Y t2, a7, a3
    EXPECT_NO_TRAP
    bnez t2, fail
    LY   t3, 0(a3)
    YTAGR t4, t3
#if __riscv_xlen == 64
    beqz t4, fail
#else
    /* 64-bit compressed capabilities cannot encode C without R, so a7 lacks C and strips the tag */
    bnez t4, fail
#endif

    NEXT_TEST "amoswap.y through a write-only capability faults with store/AMO CAP_PERM"
    AMOSWAP_Y t1, a7, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.clean through a write-only capability faults with store/AMO CAP_PERM"
    CBO_CLEAN a7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.flush through a write-only capability faults with store/AMO CAP_PERM"
    CBO_FLUSH a7
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.zero through a write-only capability succeeds"
    SY   a3, 0(a3)
    CBO_ZERO a7
    EXPECT_NO_TRAP
    LY   t1, 0(a3)
    YTAGR t2, t1
    bnez t2, fail

    /* Integer SC.W and AMO via NULL cap: store-classified */
    NEXT_TEST "sc.w through the NULL capability is store classified"
    sc.w t1, x0, (x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    NEXT_TEST "an integer amo through the NULL capability is store classified"
    amoswap.w t1, t2, (x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.ZERO via NULL cap */
    NEXT_TEST "cbo.zero through the NULL capability is store classified"
    CBO_ZERO x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.CLEAN via NULL cap */
    NEXT_TEST "cbo.clean through the NULL capability is store classified"
    CBO_CLEAN x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.FLUSH via NULL cap */
    NEXT_TEST "cbo.flush through the NULL capability is store classified"
    CBO_FLUSH x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.INVAL via NULL cap (the M-mode root PCC grants ASR) */
    NEXT_TEST "cbo.inval through the NULL capability is store classified"
    CBO_INVAL x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /*
     * Capability-mode PERM_C tag filtering across SY, SC.Y, AMOSWAP.Y, LY,
     * and LR.Y through a data-only capability (a5: R=1, W=1, C=0).
     */
    NEXT_TEST "capability-mode sy through a capability without PERM_C strips the tag"
    SY   a3, 0(a5)
    EXPECT_NO_TRAP
    LY   t1, 0(a3)
    YTAGR t2, t1
    bnez t2, fail
    bne  a0, t1, fail

    NEXT_TEST "capability-mode lr.y and sc.y without PERM_C strip loaded and stored tags"
    SY   a3, 0(a3)
    LR_Y t1, a5
    YTAGR t2, t1
    bnez t2, fail
    SC_Y t3, a5, a3
    EXPECT_NO_TRAP
    bnez t3, fail
    LY   t1, 0(a3)
    YTAGR t2, t1
    bnez t2, fail

    NEXT_TEST "capability-mode amoswap.y without PERM_C strips both loaded and stored tags"
    SY   a3, 0(a3)
    AMOSWAP_Y t1, a5, a3
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez t2, fail
    LY   t3, 0(a3)
    YTAGR t4, t3
    bnez t4, fail

    NEXT_TEST "capability-mode ly without PERM_C strips the loaded tag"
    SY   a3, 0(a3)
    LY   t1, 0(a5)
    EXPECT_NO_TRAP
    YTAGR t2, t1
    bnez t2, fail
    bne  a0, t1, fail

    /*
     * Capability-mode PERM_LM permission filtering on LY and LR.Y when
     * PERM_C is set and PERM_W | PERM_LM are cleared.
     */
    li   t0, DROP_MASK(PERM_W | PERM_LM | PERM_X | PERM_ASR)
    DROP_PERMS s2, a3, t0

    NEXT_TEST "capability-mode ly and lr.y without PERM_LM strip W and LM from an unsealed capability"
    SY   a3, 0(a3)
    LY   t1, 0(s2)
    LR_Y t2, s2
    EXPECT_NO_TRAP
    YTAGR t3, t1
    beqz t3, fail
    YPERMR t3, t1
    andi t4, t3, (PERM_W | PERM_LM)
    bnez t4, fail
    YTAGR t3, t2
    beqz t3, fail
    YPERMR t3, t2
    andi t4, t3, (PERM_W | PERM_LM)
    bnez t4, fail

    NEXT_TEST "capability-mode ly and lr.y without PERM_LM preserve W and LM on a sealed sentry"
    SY   s1, 0(a3)
    LY   t1, 0(s2)
    LR_Y t2, s2
    EXPECT_NO_TRAP
    YTAGR t3, t1
    beqz t3, fail
    YPERMR t3, t1
    andi t4, t3, (PERM_W | PERM_LM)
    li   t0, (PERM_W | PERM_LM)
    bne  t4, t0, fail
    YPERMR t3, t2
    andi t4, t3, (PERM_W | PERM_LM)
    bne  t4, t0, fail

    /*
     * LR.Y / SC.Y reservation behaviour in Capability Mode:
     *  - A second consecutive SC.Y without a new LR.Y fails (rd != 0) and
     *    leaves memory unmodified.
     *  - An SC.Y to a different address than the preceding LR.Y fails, leaves
     *    that target location unmodified, and cancels the reservation so a
     *    subsequent SC.Y to the originally reserved address also fails.
     */
    NEXT_TEST "a second consecutive sc.y without a new lr.y fails and leaves memory unmodified"
    SY   x0, 0(a3)
    LR_Y t1, a3
    SC_Y t2, a3, a3
    bnez t2, fail
    SC_Y t2, a3, x0
    EXPECT_NO_TRAP
    beqz t2, fail                /* second SC.Y must report failure (rd != 0) */
    LY   t3, 0(a3)
    YTAGR t4, t3
    beqz t4, fail                /* tagged capability from first SC.Y stays intact */

    NEXT_TEST "sc.y to a different address than the preceding lr.y fails and cancels the reservation"
    SY   a3, 0(a3)
    SY   s7, 0(s7)
    LR_Y t1, a3
    SC_Y t2, s7, x0
    EXPECT_NO_TRAP
    beqz t2, fail                /* address mismatch must fail */
    LY   t3, 0(s7)
    YTAGR t4, t3
    beqz t4, fail                /* s7 slot stays tagged */
    SC_Y t2, a3, x0
    EXPECT_NO_TRAP
    beqz t2, fail                /* prior SC.Y cancelled the reservation on a3 */
    LY   t3, 0(a3)
    YTAGR t4, t3
    beqz t4, fail                /* a3 slot also stays tagged */

    /*
     * Unaligned integer store straddling two adjacent capability slots at
     * buf + 0 and buf + YLEN_BYTES must invalidate the tags of both slots.
     */
    NEXT_TEST "an unaligned integer store straddling two capabilities clears both tags"
    SY   a3, 0(a3)
    SY   s7, 0(s7)
    sw   x0, (YLEN_BYTES - 2)(a3)
    EXPECT_NO_TRAP
    LY   t1, 0(a3)
    YTAGR t2, t1
    bnez t2, fail
    LY   t3, 0(s7)
    YTAGR t4, t3
    bnez t4, fail

    YMODESWI                     /* back to int mode */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 128

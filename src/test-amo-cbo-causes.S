/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify the RVY exception causes, fault addresses (mtval), and permission
 * checks for capability atomics and cache-block operations:
 *
 *  - Misaligned capability accesses raise *access* faults (not misaligned
 *    faults) since they cannot be emulated in software: cause 5 for LR.Y
 *    (plain load semantics per the spec's LR.Y page), cause 7 for SC.Y and
 *    AMOSWAP.Y. 0.9.3 predates that and reports them as misaligned.
 *  - In capability mode with cs1=x0 (the NULL capability) or an untagged
 *    capability at a non-zero address, the tag check fails; the reported
 *    cause must be selected by the access type: LR.Y -> CHERI Load Access
 *    Fault (33); SC.Y, AMOSWAP.Y, integer AMOs (amoswap.w) and all CBOs ->
 *    CHERI Store/AMO Access Fault (34), with mtval holding the faulting
 *    virtual address in v0.9.9.
 *  - AMOSWAP.Y requires the authorizing capability cs1 to grant both R and W
 *    permissions even when storing x0 or an untagged capability (while C is
 *    only required when storing a tagged capability); a W-permission fault
 *    must report a store fault without modifying cd or memory.
 */
#define TEST_NAME "amo-cbo-causes"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    la   a0, buf                 /* aligned to YLEN/8 */
    addi a1, a0, 4               /* misaligned for YLEN/8 on RV32 and RV64 */

    /* Aligned LR.Y via root DDC succeeds (sanity/decode check) */
    NEXT_TEST "aligned lr.y through root ddc succeeds"
    LR_Y t1, a0
    EXPECT_NO_TRAP

    /* Misaligned LR.Y raises a load access fault */
    NEXT_TEST "misaligned lr.y raises a load access fault"
    LR_Y t1, a1
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD

    /* Misaligned SC.Y raises a store/AMO access fault */
    NEXT_TEST "misaligned sc.y raises a store fault"
    SC_Y t1, a1, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE

    /* ... and so does misaligned AMOSWAP.Y */
    NEXT_TEST "misaligned amoswap.y raises a store fault"
    AMOSWAP_Y t1, a1, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE

    /* Derive untagged, read-only, and non-C capabilities for buf. */
    csrrs t0, CSR_DDC, x0
    YADDRW a2, x0, a0            /* a2: untagged capability at buf */
    YADDRW a3, t0, a0            /* a3: full-permission capability at buf */
    li   t2, DROP_MASK(PERM_W)
    DROP_PERMS a4, a3, t2        /* a4: read-only capability (W=0, R=1, C=1) */
    li   t2, DROP_MASK(PERM_C)
    DROP_PERMS a5, a3, t2        /* a5: data-only capability (W=1, R=1, C=0) */

    /* Enter capability mode: cs1=x0 is now the untagged NULL capability. */
    YMODESWY

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
     * AMOSWAP.Y through a read-only capability (W=0) must fault with a store
     * capability permission fault even when storing x0 or an untagged
     * capability, leaving cd and memory unchanged. Control: dropping only C
     * (W=1, C=0) permits AMOSWAP.Y when storing x0.
     */
    NEXT_TEST "amoswap.y of x0 through a read-only capability faults without side effects"
    SY   a3, 0(a3)
    YMV  t1, a3
    AMOSWAP_Y t1, a4, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    YTAGR t3, t1
    beqz t3, fail                /* cd (t1) must remain tagged */
    LY   t2, 0(a3)
    YTAGR t3, t2
    beqz t3, fail                /* memory must remain tagged */

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

    /* Integer AMO via NULL cap: also store-classified (R+W required) */
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

    YMODESWI                     /* back to int mode */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 16
buf:
    .space 64

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify the RVY exception causes for capability atomics and cache-block
 * operations:
 *
 *  - Misaligned capability accesses raise *access* faults (not misaligned
 *    faults) since they cannot be emulated in software: cause 5 for LR.Y
 *    (plain load semantics per the spec's LR.Y page), cause 7 for SC.Y and
 *    AMOSWAP.Y. 0.9.3 predates that and reports them as misaligned.
 *  - In capability mode with cs1=x0 (the NULL capability) the tag check
 *    fails; the reported cause must be selected by the access type:
 *    LR.Y -> CHERI Load Access Fault (33); SC.Y, AMOSWAP.Y, integer AMOs
 *    (amoswap.w) and all CBOs -> CHERI Store/AMO Access Fault (34).
 *    (CBO.INVAL additionally requires ASR, which the M-mode root PCC
 *    grants, so it reports 34 like the others here.)
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
    NEXT_TEST
    LR_Y t1, a0
    EXPECT_NO_TRAP

    /* Misaligned LR.Y raises a load access fault */
    NEXT_TEST
    LR_Y t1, a1
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD

    /* Misaligned SC.Y raises a store/AMO access fault */
    NEXT_TEST
    SC_Y t1, a1, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE

    /* ... and so does misaligned AMOSWAP.Y */
    NEXT_TEST
    AMOSWAP_Y t1, a1, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE

    /* Enter capability mode: cs1=x0 is now the untagged NULL capability. */
    YMODESWY

    /* LR.Y via NULL cap: load-classified tag fault */
    NEXT_TEST
    LR_Y t1, x0
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    /* SC.Y via NULL cap: store-classified tag fault */
    NEXT_TEST
    SC_Y t1, x0, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* AMOSWAP.Y via NULL cap */
    NEXT_TEST
    AMOSWAP_Y t1, x0, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* Integer AMO via NULL cap: also store-classified (R+W required) */
    NEXT_TEST
    amoswap.w t1, t2, (x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.ZERO via NULL cap */
    NEXT_TEST
    CBO_ZERO x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.CLEAN via NULL cap */
    NEXT_TEST
    CBO_CLEAN x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.INVAL via NULL cap (the M-mode root PCC grants ASR) */
    NEXT_TEST
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

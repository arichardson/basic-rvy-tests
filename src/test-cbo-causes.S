/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Cache-block operation (cbo.zero, cbo.clean, cbo.flush, cbo.inval) capability
 * tag, seal, and permission checks in capability mode:
 *
 *  - All four CBOs are classified as store/AMO operations: executing any of
 *    them through the NULL capability or a sealed sentry raises a store
 *    capability fault (CAP_TAG or CAP_SEAL), reporting the faulting address in
 *    mtval on RVY and leaving memory unmodified.
 *  - All four CBOs require W (store) permission on the authorizing capability,
 *    faulting with store CAP_PERM on a read-only capability (W=0, R=1) even
 *    when the entire cache block is in bounds.
 *  - On a write-only capability (R=0, W=1), cbo.zero succeeds because it only
 *    requires W, whereas cbo.clean and cbo.flush require both R and W and
 *    fault with store CAP_PERM.
 */
#define TEST_NAME "cbo-causes"
#include "testmacros.h"
#include "exceptions.h"

#define CBOM_LEN 64

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    lla   a0, buf
    csrrs s0, CSR_DDC, x0
    YADDRW a3, s0, a0
    li   t0, CBOM_LEN
    YBNDSW a3, a3, t0            /* a3: [buf, buf + CBOM_LEN), full RW permissions */
    li   t0, DROP_MASK(PERM_W)
    DROP_PERMS a4, a3, t0        /* a4: read-only capability (W=0, R=1) */
    li   t0, DROP_MASK(PERM_R)
    DROP_PERMS a7, a3, t0        /* a7: write-only capability (R=0, W=1) */
    YSEALE s1, a3                /* s1: sealed sentry at buf */
    SY   a3, 0(a0)

    YMODESWY

    /* CBO.ZERO via NULL cap */
    NEXT_TEST "cbo.zero through the NULL capability is store classified"
    mv   t0, x0
    CBO_ZERO t0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.CLEAN via NULL cap */
    NEXT_TEST "cbo.clean through the NULL capability is store classified"
    mv   t0, x0
    CBO_CLEAN t0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.FLUSH via NULL cap */
    NEXT_TEST "cbo.flush through the NULL capability is store classified"
    mv   t0, x0
    CBO_FLUSH t0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    /* CBO.INVAL via NULL cap (the M-mode root PCC grants ASR) */
    NEXT_TEST "cbo.inval through the NULL capability is store classified"
    mv   t0, x0
    CBO_INVAL t0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    NEXT_TEST "cbo.zero through a sealed sentry faults with store CAP_SEAL"
    CBO_ZERO s1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0
    LY   t0, 0(a3)
    EXPECT_CAP_EQ t0, a3

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
     * Dropping W (store permission) while keeping R and full-block bounds
     * causes all four CBOs to fault with a store permission violation.
     */
    NEXT_TEST "cbo.zero faults on a read-only capability covering the whole block"
    CBO_ZERO a4
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.clean faults on a read-only capability covering the whole block"
    CBO_CLEAN a4
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.flush faults on a read-only capability covering the whole block"
    CBO_FLUSH a4
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0

    NEXT_TEST "cbo.inval faults on a read-only capability covering the whole block"
    CBO_INVAL a4
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
    EXPECT_TAG t1, 0

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space CBOM_LEN

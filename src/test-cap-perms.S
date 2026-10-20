/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability execution-mode and permission manipulation instructions:
 *
 *  - YMODEW sets the execution mode of an unsealed executable capability to
 *    CHERI_MODE_INT (1) or CHERI_MODE_CAP (0) when cd != x0.
 *  - Dropping PERM_X via YPERMC / ACPERM on an integer-mode capability forces
 *    its execution mode back to CHERI_MODE_CAP (0), because non-executable
 *    capabilities cannot encode integer execution mode.
 */
#define TEST_NAME "cap-perms"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs t0, CSR_DDC, x0

    /* YMODEW sets the execution mode of an unsealed executable capability when cd != x0. */
    NEXT_TEST "ymodew updates the execution mode in integer and capability mode"
    li   t2, 1
    YMODEW t1, t0, t2
    EXPECT_TAG t1, 1
    YMODER t3, t1
    EXPECT_EQ t3, t2
    YMODESWY
    YMODEW t1, t1, x0
    YMODESWI
    EXPECT_TAG t1, 1
    YMODER t3, t1
    EXPECT_ZERO t3
    EXPECT_NO_TRAP

    YMODESWY

    /*
     * Dropping PERM_X on an executable capability whose mode bit is
     * CHERI_MODE_INT (1) forces the mode bit to CHERI_MODE_CAP (0), because
     * non-executable capabilities cannot encode integer execution mode.
     */
    NEXT_TEST "dropping PERM_X on an integer-mode capability forces capability mode"
    auipc a2, 0
    li   t1, CHERI_MODE_INT
    YMODEW a2, a2, t1
    EXPECT_TAG a2, 1
    YMODER t3, a2
    EXPECT_EQ t3, t1
    li   t2, DROP_MASK(PERM_X)
    DROP_PERMS a2, a2, t2
    EXPECT_TAG a2, 1
    YMODER t3, a2
    EXPECT_ZERO t3               /* forced back to CHERI_MODE_CAP (0) */
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

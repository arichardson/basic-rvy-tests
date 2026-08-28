/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY reserves the BEQ/BNE encodings whose operands are in rs1 <= rs2
 * register number order, but only in capability mode: the reservation exists
 * so the encodings can be reused for capability-specific branches later, which
 * only makes sense when the operands are capabilities.
 *
 * QEMU does not enforce the reservation unless x-rvy-strict-branches is set,
 * because compilers do not swap the operands yet and existing binaries use
 * the reserved forms. This test covers that default configuration: nothing
 * here may trap. test-reserved-branches covers the enforcing one.
 *
 * The reserved-order branches are arranged never to be taken, so the flow is
 * the same whichever way they are treated.
 */
#define TEST_NAME "branches"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    li   t0, 1
    li   t1, 1
    li   t2, 2

    /* Integer pointer mode: the reservation never applies here. */
    NEXT_TEST
    RESERVED_ORDER_BRANCHES
    EXPECT_NO_TRAP

    /* Capability mode: not enforced in this configuration either. */
    NEXT_TEST
    YMODESWY
    RESERVED_ORDER_BRANCHES
    YMODESWI
    EXPECT_NO_TRAP

    /* Legal operand orders must of course still work. */
    NEXT_TEST
    LEGAL_ORDER_BRANCHES
    EXPECT_NO_TRAP

    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

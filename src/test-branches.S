/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY v0.9.6 through v0.9.9 reserved the BEQ/BNE encodings whose operands
 * are in rs1 <= rs2 register number order, but only in capability mode: the
 * reservation existed so the encodings could be reused for capability-specific
 * branches later, which only makes sense when the operands are capabilities.
 * 0.9.3 predates the reservation and v0.9.10 removed it, so on both of those
 * versions reserved-order BEQ/BNE execute in capability mode without trapping
 * (test-reserved-branches covers v0.9.9, where capability-mode rs1 <= rs2
 * raises an illegal-instruction exception).
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
    NEXT_TEST "reserved operand order is never reserved in integer mode"
    RESERVED_ORDER_BRANCHES
    EXPECT_NO_TRAP

#ifndef CHERI_099
    /* Capability mode: not reserved in 0.9.3 or v0.9.10. */
    NEXT_TEST "reserved operand order is not reserved in capability mode on 0.9.3 and v0.9.10"
    YMODESWY
    RESERVED_ORDER_BRANCHES
    YMODESWI
    EXPECT_NO_TRAP
#endif

    /* Legal operand orders must of course still work. */
    NEXT_TEST "the canonical operand orders still work"
    YMODESWY
    LEGAL_ORDER_BRANCHES
    YMODESWI
    EXPECT_NO_TRAP

    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

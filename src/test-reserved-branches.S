/* SPDX-License-Identifier: BSD-2-Clause
 *
 * The enforcing half of test-branches: run with x-rvy-strict-branches=on,
 * where QEMU implements the architectural reservation, each reserved-order
 * BEQ/BNE in capability mode must raise an illegal instruction.
 *
 * The reservation is capability-mode only, so the identical sequence in
 * integer pointer mode must still execute -- that is what lets hybrid
 * binaries keep using these encodings for their integer code.
 */
#define TEST_NAME "reserved-branches"
#ifdef CHERI_093
#error "RVY v0.9.9 only: the reserved BEQ/BNE encodings are a v0.9.9 addition"
#endif
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

    /* Integer pointer mode: still not reserved, even when enforcing. */
    NEXT_TEST "reserved operand order still runs in integer pointer mode"
    RESERVED_ORDER_BRANCHES
    EXPECT_NO_TRAP

    /* Capability mode: each of the three is now an illegal instruction. */
    YMODESWY
    NEXT_TEST "beq x5 x7 in capability mode is illegal when enforcing"
    .insn b 0x63, 0, t0, t2, fail        /* beq x5, x7 */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    NEXT_TEST "bne x5 x6 in capability mode is illegal when enforcing"
    .insn b 0x63, 1, t0, t1, fail        /* bne x5, x6 */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    NEXT_TEST "bne x5 x5 in capability mode is illegal when enforcing"
    .insn b 0x63, 1, t0, t0, fail        /* bne x5, x5 (rs1 == rs2) */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    /* Legal operand orders keep working in capability mode. */
    NEXT_TEST "the canonical operand orders keep working"
    LEGAL_ORDER_BRANCHES
    EXPECT_NO_TRAP
    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

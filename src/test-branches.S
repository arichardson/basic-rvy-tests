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
 * here may trap. test-reserved-branches covers the enforcing one. 0.9.3 has
 * no such reservation at all, so the same expectations hold there.
 *
 * The reserved-order branches are arranged never to be taken, so the flow is
 * the same whichever way they are treated.
 *
 * When misa.C is cleared (IALIGN=32), taken conditional branches, JAL, and
 * JALR to a 2-byte-aligned target raise an instruction address misaligned
 * exception at the branch or jump instruction without writing rd, whereas
 * untaken conditional branches to a 2-byte-aligned target do not fault.
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

    /* Capability mode: not enforced in this configuration either. */
    NEXT_TEST "and is not enforced in capability mode either by default"
    YMODESWY
    RESERVED_ORDER_BRANCHES
    YMODESWI
    EXPECT_NO_TRAP

    /* Legal operand orders must of course still work. */
    NEXT_TEST "the canonical operand orders still work"
    LEGAL_ORDER_BRANCHES
    EXPECT_NO_TRAP

    /*
     * IALIGN=32 branch and jump alignment checks in both integer and
     * capability mode. Skipped on targets where misa.C is hard-wired to 1.
     */
    SKIPPABLE_BLOCK_BEGIN
    TRY_CLEAR_MISA_C skip_ialign32

    NEXT_TEST "untaken branch to a 2-byte-aligned target does not fault under IALIGN=32"
    bne  x0, x0, ialign_target + 2
    EXPECT_NO_TRAP

    NEXT_TEST "taken branch to a 2-byte-aligned target faults at the branch under IALIGN=32"
    la   s2, 1f
1:  beq  x0, x0, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2

    NEXT_TEST "integer-mode jal to a 2-byte-aligned target faults without writing ra"
    mv   ra, x0
    la   s2, 1f
1:  jal  ra, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    NEXT_TEST "integer-mode jalr to a 2-byte-aligned target faults without writing ra"
    la   a0, ialign_target + 2
    mv   ra, x0
    la   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    NEXT_TEST "integer-mode jalr masks bit 0 before checking bit 1 under IALIGN=32"
    la   a0, ialign_target + 3
    mv   ra, x0
    la   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    YMODESWY

    NEXT_TEST "capability-mode untaken branch to a 2-byte-aligned target does not fault"
    bne  x0, x0, ialign_target + 2
    EXPECT_NO_TRAP

    NEXT_TEST "capability-mode taken branch to a 2-byte-aligned target faults at the branch"
    la   s2, 1f
1:  beq  x0, x0, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2

    NEXT_TEST "capability-mode jal to a 2-byte-aligned target faults without writing ra"
    mv   ra, x0
    la   s2, 1f
1:  jal  ra, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    NEXT_TEST "capability-mode jalr to a 2-byte-aligned target faults without writing ra"
    auipc a0, 0
    la   t0, ialign_target + 2
    YADDRW a0, a0, t0
    mv   ra, x0
    la   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    NEXT_TEST "capability-mode jalr masks bit 0 before checking bit 1 under IALIGN=32"
    auipc a0, 0
    la   t0, ialign_target + 3
    YADDRW a0, a0, t0
    mv   ra, x0
    la   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    NEXT_TEST "capability-mode jalr to a 2-byte-aligned sentry faults under IALIGN=32"
    auipc a0, 0
    la   t0, ialign_target + 2
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    mv   ra, x0
    la   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    bnez ra, fail

    NEXT_TEST "4-byte-aligned jal and jalr succeed under IALIGN=32"
    jal  ra, ialign_good_target
    auipc a0, 0
    la   t0, ialign_good_target
    YADDRW a0, a0, t0
    jalr ra, a0, 0
    EXPECT_NO_TRAP

    li   t0, MISA_C
    csrs CSR_MISA, t0

    YMODESWI
    j    ialign32_done
skip_ialign32:
    SKIPPABLE_BLOCK_SKIPPED "misa.C is hard-wired here so IALIGN=32 is unreachable"
ialign32_done:

    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

.balign 8
ialign_target:
    j    fail
    j    fail

.balign 8
ialign_good_target:
    ret

TRAP_HANDLER

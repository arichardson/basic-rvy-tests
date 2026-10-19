/* SPDX-License-Identifier: BSD-2-Clause
 *
 * When misa.C is cleared (IALIGN=32), taken conditional branches, JAL, and
 * JALR to a 2-byte-aligned target raise an instruction address misaligned
 * exception at the branch or jump instruction without writing rd, whereas
 * untaken conditional branches to a 2-byte-aligned target and 4-byte-aligned
 * JAL and JALR succeed.
 */
#define TEST_NAME "branch-misaligned"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

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
    lla   s2, 1f
1:  beq  x0, x0, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2

    NEXT_TEST "integer-mode jal to a 2-byte-aligned target faults without writing ra"
    mv   ra, x0
    lla   s2, 1f
1:  jal  ra, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    NEXT_TEST "integer-mode jalr to a 2-byte-aligned target faults without writing ra"
    lla   a0, ialign_target + 2
    mv   ra, x0
    lla   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    NEXT_TEST "integer-mode jalr masks bit 0 before checking bit 1 under IALIGN=32"
    lla   a0, ialign_target + 3
    mv   ra, x0
    lla   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    YMODESWY

    li   t0, 1
    li   t1, 1
    NEXT_TEST "capability-mode untaken branch to a 2-byte-aligned target does not fault"
    bne  t1, t0, ialign_target + 2
    EXPECT_NO_TRAP

    NEXT_TEST "capability-mode taken branch to a 2-byte-aligned target faults at the branch"
    lla   s2, 1f
1:  beq  t1, t0, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2

    NEXT_TEST "capability-mode jal to a 2-byte-aligned target faults without writing ra"
    mv   ra, x0
    lla   s2, 1f
1:  jal  ra, ialign_target + 2
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    NEXT_TEST "capability-mode jalr to a 2-byte-aligned target faults without writing ra"
    auipc a0, 0
    lla   t0, ialign_target + 2
    YADDRW a0, a0, t0
    mv   ra, x0
    lla   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    NEXT_TEST "capability-mode jalr masks bit 0 before checking bit 1 under IALIGN=32"
    auipc a0, 0
    lla   t0, ialign_target + 3
    YADDRW a0, a0, t0
    mv   ra, x0
    lla   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    NEXT_TEST "capability-mode jalr to a 2-byte-aligned sentry faults under IALIGN=32"
    auipc a0, 0
    lla   t0, ialign_target + 2
    YADDRW a0, a0, t0
    YSEALE a0, a0
    mv   ra, x0
    lla   s2, 1f
1:  jalr ra, a0, 0
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC s2
    EXPECT_ZERO ra

    NEXT_TEST "4-byte-aligned jal and jalr succeed under IALIGN=32"
    jal  ra, ialign_good_target
    auipc a0, 0
    lla   t0, ialign_good_target
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

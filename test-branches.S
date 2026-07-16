/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY reserves BEQ/BNE encodings whose operands are in rs1 <= rs2 register
 * number order, but only in capability mode (the reservation is for
 * possible future extensions like branching on capability tag values,
 * which only make sense when the operands are capabilities). QEMU only
 * traps on them with x-rvy-strict-branches=on, so this test reports the
 * observed illegal-instruction count as its exit code:
 *   default run:  exit 0 (reserved encodings execute as normal branches)
 *   strict run:   exit 3 (each of the three reserved encodings traps, but
 *                 only in the capmode section below -- the identical
 *                 sequence in integer pointer mode must never trap, since
 *                 legacy/hybrid binaries running with CHERI enabled but in
 *                 integer mode rely on these encodings)
 * The reserved-order branches are arranged to never be taken so the flow is
 * identical whether they execute or are skipped by the trap handler.
 */
#include "testmacros.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAP_HANDLER

    li   s10, 1
    li   t0, 1
    li   t1, 1
    li   t2, 2

    /*
     * Integer pointer mode (the reset default): reserved-order encodings
     * must never trap here, strict-branches or not.
     */
    .insn b 0x63, 0, t0, t2, fail        /* beq x5, x7 (1 != 2) */
    .insn b 0x63, 1, t0, t1, fail        /* bne x5, x6 (1 == 1) */
    .insn b 0x63, 1, t0, t0, fail        /* bne x5, x5 (rs1 == rs2) */
    bnez s11, fail                       /* must still be 0 */

    /*
     * Capability mode: the same reserved-order encodings must trap when
     * x-rvy-strict-branches=on, and behave as normal branches otherwise.
     */
    li   s10, 2
    .insn r 0x7b, 0, 0x2b, x0, x0, x0    /* ymodesw.y (enter cap mode) */
    .insn b 0x63, 0, t0, t2, fail        /* beq x5, x7 (1 != 2) */
    .insn b 0x63, 1, t0, t1, fail        /* bne x5, x6 (1 == 1) */
    .insn b 0x63, 1, t0, t0, fail        /* bne x5, x5 (rs1 == rs2) */
    .insn r 0x7b, 0, 0x2b, x0, x0, x1    /* ymodesw.i (back to int mode) */

    /* Legal operand orders must still work (in integer mode). */
    li   s10, 3
    .insn b 0x63, 0, t1, t0, 1f          /* beq x6, x5: taken */
    j    fail
1:
    .insn b 0x63, 1, t2, t0, 2f          /* bne x7, x5: taken */
    j    fail
2:
    beqz s11, 3f
    /* Traps occurred: report the count as the exit code */
    mv   s10, s11
    TEST_FAIL_S10
3:
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    .insn r 0x7b, 0, 0x2b, x0, x0, x1    /* ymodesw.i */
    TEST_FAIL_S10

TRAP_HANDLER

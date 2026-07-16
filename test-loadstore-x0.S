/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify that for every load/store (lw, sw, fld, fsd, ly, sy), an encoding
 * with base register x0 behaves according to the current CHERI execution
 * mode:
 *  - Integer pointer mode: rs1=x0 contributes 0, so the effective address
 *    is simply the immediate; the DDC-relative bounds check passes (DDC is
 *    root) and the access proceeds to the underlying memory system. No
 *    CHERI-specific exception (cause 32/33/34) may occur.
 *  - Capability mode: cs1=x0 selects capability register c0, which is the
 *    NULL capability (untagged); this must be rejected with a CHERI tag
 *    violation (cause 33 or 34) before any memory access is attempted.
 *
 * The test target address (0x400) is deliberately unmapped on the virt
 * machine: nothing needs to be readable/writable there, since the
 * assertions only care about *which class* of exception (if any) occurs,
 * not about round-tripping a value through real memory. In integer mode
 * the unmapped address still faults, but with a generic RISC-V access
 * fault rather than a CHERI exception -- exactly the distinction this
 * test checks for. All instructions use a 16-byte-aligned offset so
 * alignment requirements (up to CHERI_CAP_SIZE on RV64) are satisfied.
 */
#include "testmacros.h"

#define TEST_ADDR 0x400

.option norvc
.section .text
.globl _start
_start:
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   s10, 99                 /* id for traps outside any test */
    li   s11, 0                  /* illegal-instruction count (unexpected) */
    li   s6, 0                   /* generic (non-CHERI) fault count */
    li   s7, 0                   /* CHERI exception count */

    /* Enable the FPU (mstatus.FS = Initial) so fld/fsd do not trap. */
    li   t0, 1 << 13
    csrs CSR_MSTATUS, t0

    /*
     * Integer pointer mode (the default at reset): none of these may raise
     * a CHERI exception.
     */
    li   s10, 1
    mv   t3, s7
    lw   t1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 2
    mv   t3, s7
    sw   t1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 3
    mv   t3, s7
    fld  ft1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 4
    mv   t3, s7
    fsd  ft1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 5
    mv   t3, s7
    .insn i 0x7b, 1, t1, x0, TEST_ADDR    /* ly */
    bne  t3, s7, fail

    li   s10, 6
    mv   t3, s7
    .insn s 0x7b, 2, t2, TEST_ADDR(x0)    /* sy */
    bne  t3, s7, fail

    /* Capability mode: cs1=x0 is the NULL capability, so every access must
     * raise a CHERI exception. */
    li   s10, 7
    .insn r 0x7b, 0, 0x2b, x0, x0, x0    /* ymodesw.y (enter cap mode) */

    li   s10, 8
    mv   t3, s7
    lw   t1, TEST_ADDR(x0)
    beq  t3, s7, fail

    li   s10, 9
    mv   t3, s7
    sw   t1, TEST_ADDR(x0)
    beq  t3, s7, fail

    li   s10, 10
    mv   t3, s7
    fld  ft1, TEST_ADDR(x0)
    beq  t3, s7, fail

    li   s10, 11
    mv   t3, s7
    fsd  ft1, TEST_ADDR(x0)
    beq  t3, s7, fail

    li   s10, 12
    mv   t3, s7
    .insn i 0x7b, 1, t1, x0, TEST_ADDR    /* ly */
    beq  t3, s7, fail

    li   s10, 13
    mv   t3, s7
    .insn s 0x7b, 2, t2, TEST_ADDR(x0)    /* sy */
    beq  t3, s7, fail

    li   s10, 14
    .insn r 0x7b, 0, 0x2b, x0, x0, x1    /* ymodesw.i (back to int mode) */

    bnez s11, fail                /* no illegal-instruction traps expected */
    TEST_PASS
fail:
    TEST_FAIL_S10

/*
 * Trap handler: any illegal instruction (cause 2) is an unexpected failure
 * (none of the encodings above should ever be illegal); a CHERI exception
 * (cause 32-34) or any other fault is expected exactly once per access
 * above, bucketed into s7/s6 respectively. Every trap skips the faulting
 * (4-byte) instruction and resumes.
 */
.balign 4
trap_handler:
    csrr t6, CSR_MCAUSE
    li   t5, 2
    bne  t6, t5, 1f
    addi s11, s11, 1
    j    2f
1:
    li   t5, 32
    blt  t6, t5, 3f
    li   t4, 35
    bge  t6, t4, 3f
    addi s7, s7, 1
    j    2f
3:
    addi s6, s6, 1
2:
    csrr t6, CSR_MEPC
    addi t6, t6, 4
    csrw CSR_MEPC, t6
    mret

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
 *    violation before any memory access is attempted. Loads must report
 *    CHERI Load Access Fault (cause 33) and stores CHERI Store/AMO Access
 *    Fault (cause 34): the cause is selected by the access type, not by
 *    the failing check (a tag violation is not a load-only fault).
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
    li   s7, 0                   /* CHERI load fault (cause 33) count */
    li   s8, 0                   /* CHERI store/AMO fault (cause 34) count */

    /* Enable the FPU (mstatus.FS = Initial) so fld/fsd do not trap. */
    li   t0, 1 << 13
    csrs CSR_MSTATUS, t0

    /*
     * Integer pointer mode (the default at reset): none of these may raise
     * a CHERI exception (neither cause 33 nor 34).
     */
    li   s10, 1
    add  t3, s7, s8
    lw   t1, TEST_ADDR(x0)
    add  t4, s7, s8
    bne  t3, t4, fail

    li   s10, 2
    add  t3, s7, s8
    sw   t1, TEST_ADDR(x0)
    add  t4, s7, s8
    bne  t3, t4, fail

    li   s10, 3
    add  t3, s7, s8
    fld  ft1, TEST_ADDR(x0)
    add  t4, s7, s8
    bne  t3, t4, fail

    li   s10, 4
    add  t3, s7, s8
    fsd  ft1, TEST_ADDR(x0)
    add  t4, s7, s8
    bne  t3, t4, fail

    li   s10, 5
    add  t3, s7, s8
    LY   t1, TEST_ADDR(x0)
    add  t4, s7, s8
    bne  t3, t4, fail

    li   s10, 6
    add  t3, s7, s8
    SY   t2, TEST_ADDR(x0)
    add  t4, s7, s8
    bne  t3, t4, fail

    /* Capability mode: cs1=x0 is the NULL capability, so every access must
     * raise a CHERI exception: cause 33 for loads, cause 34 for stores. */
    li   s10, 7
    YMODESWY                             /* enter cap mode */

    li   s10, 8
    addi t3, s7, 1
    lw   t1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 9
    addi t3, s8, 1
    sw   t1, TEST_ADDR(x0)
    bne  t3, s8, fail

    li   s10, 10
    addi t3, s7, 1
    fld  ft1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 11
    addi t3, s8, 1
    fsd  ft1, TEST_ADDR(x0)
    bne  t3, s8, fail

    li   s10, 12
    addi t3, s7, 1
    LY   t1, TEST_ADDR(x0)
    bne  t3, s7, fail

    li   s10, 13
    addi t3, s8, 1
    SY   t2, TEST_ADDR(x0)
    bne  t3, s8, fail

    li   s10, 14
    YMODESWI                             /* back to int mode */

    bnez s11, fail                /* no illegal-instruction traps expected */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL_S10

/*
 * Trap handler: any illegal instruction (cause 2) is an unexpected failure
 * (none of the encodings above should ever be illegal); CHERI load faults
 * (cause 33) are counted in s7, CHERI store/AMO faults (cause 34) in s8,
 * and any other fault in s6. Every trap skips the faulting (4-byte)
 * instruction and resumes.
 */
.balign 4
trap_handler:
    csrr t6, CSR_MCAUSE
    li   t5, 2
    bne  t6, t5, 1f
    addi s11, s11, 1
    j    2f
1:
    li   t5, 33
    bne  t6, t5, 3f
    addi s7, s7, 1
    j    2f
3:
    li   t5, 34
    bne  t6, t5, 4f
    addi s8, s8, 1
    j    2f
4:
    addi s6, s6, 1
2:
    csrr t6, CSR_MEPC
    addi t6, t6, 4
    csrw CSR_MEPC, t6
    mret

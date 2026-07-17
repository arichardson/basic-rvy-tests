/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify the RVY exception causes for capability atomics and cache-block
 * operations:
 *
 *  - Misaligned capability accesses raise *access* faults (not misaligned
 *    faults) since they cannot be emulated in software: cause 5 for LR.Y
 *    (plain load semantics per the spec's LR.Y page), cause 7 for SC.Y and
 *    AMOSWAP.Y.
 *  - In capability mode with cs1=x0 (the NULL capability) the tag check
 *    fails; the reported cause must be selected by the access type:
 *    LR.Y -> CHERI Load Access Fault (33); SC.Y, AMOSWAP.Y, integer AMOs
 *    (amoswap.w) and all CBOs -> CHERI Store/AMO Access Fault (34).
 *    (CBO.INVAL additionally requires ASR, which the M-mode root PCC
 *    grants, so it reports 34 like the others here.)
 *
 * Register use: s2/s3 = cause 5/7 counters, s7/s8 = cause 33/34 counters,
 * s11 = illegal-instruction counter (must stay 0), s6 = any other cause.
 */
#include "testmacros.h"

.option norvc
.section .text
.globl _start
_start:
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   s10, 99                 /* id for traps outside any test */
    li   s2, 0                   /* load access fault (cause 5) count */
    li   s3, 0                   /* store/AMO access fault (cause 7) count */
    li   s6, 0                   /* unexpected cause count */
    li   s7, 0                   /* CHERI load fault (cause 33) count */
    li   s8, 0                   /* CHERI store/AMO fault (cause 34) count */
    li   s11, 0                  /* illegal-instruction count (unexpected) */

    la   a0, buf                 /* aligned to YLEN/8 */
    addi a1, a0, 4               /* misaligned for YLEN/8 on RV32 and RV64 */

    /* Test 1: aligned LR.Y via root DDC succeeds (sanity/decode check) */
    li   s10, 1
    add  t3, s2, s3
    .insn r 0x7b, 3, 0x08, t1, a0, x0     /* lr.y t1, (a0) */
    add  t4, s2, s3
    bne  t3, t4, fail

    /* Test 2: misaligned LR.Y raises a load access fault (cause 5) */
    li   s10, 2
    addi t3, s2, 1
    .insn r 0x7b, 3, 0x08, t1, a1, x0     /* lr.y t1, (a1) */
    bne  t3, s2, fail

    /* Test 3: misaligned SC.Y raises a store/AMO access fault (cause 7) */
    li   s10, 3
    addi t3, s3, 1
    .insn r 0x7b, 3, 0x0C, t1, a1, t2     /* sc.y t1, t2, (a1) */
    bne  t3, s3, fail

    /* Test 4: misaligned AMOSWAP.Y raises cause 7 as well */
    li   s10, 4
    addi t3, s3, 1
    .insn r 0x7b, 3, 0x04, t1, a1, t2     /* amoswap.y t1, t2, (a1) */
    bne  t3, s3, fail

    /* Enter capability mode: cs1=x0 is now the untagged NULL capability. */
    li   s10, 5
    .insn r 0x7b, 0, 0x2b, x0, x0, x0     /* ymodesw.y */

    /* Test 6: LR.Y via NULL cap: load-classified tag fault (cause 33) */
    li   s10, 6
    addi t3, s7, 1
    .insn r 0x7b, 3, 0x08, t1, x0, x0     /* lr.y t1, (x0) */
    bne  t3, s7, fail

    /* Test 7: SC.Y via NULL cap: store-classified tag fault (cause 34) */
    li   s10, 7
    addi t3, s8, 1
    .insn r 0x7b, 3, 0x0C, t1, x0, t2     /* sc.y t1, t2, (x0) */
    bne  t3, s8, fail

    /* Test 8: AMOSWAP.Y via NULL cap: cause 34 */
    li   s10, 8
    addi t3, s8, 1
    .insn r 0x7b, 3, 0x04, t1, x0, t2     /* amoswap.y t1, t2, (x0) */
    bne  t3, s8, fail

    /* Test 9: integer AMO via NULL cap: also cause 34 (R+W required) */
    li   s10, 9
    addi t3, s8, 1
    amoswap.w t1, t2, (x0)
    bne  t3, s8, fail

    /* Test 10: CBO.ZERO via NULL cap: cause 34 */
    li   s10, 10
    addi t3, s8, 1
    .insn i 0xf, 2, x0, x0, 4             /* cbo.zero 0(x0) */
    bne  t3, s8, fail

    /* Test 11: CBO.CLEAN via NULL cap: cause 34 */
    li   s10, 11
    addi t3, s8, 1
    .insn i 0xf, 2, x0, x0, 1             /* cbo.clean 0(x0) */
    bne  t3, s8, fail

    /* Test 12: CBO.INVAL via NULL cap (PCC grants ASR): cause 34 */
    li   s10, 12
    addi t3, s8, 1
    .insn i 0xf, 2, x0, x0, 0             /* cbo.inval 0(x0) */
    bne  t3, s8, fail

    li   s10, 13
    .insn r 0x7b, 0, 0x2b, x0, x0, x1     /* ymodesw.i (back to int mode) */

    bnez s11, fail                /* no illegal-instruction traps expected */
    bnez s6, fail                 /* no unexpected causes */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    .insn r 0x7b, 0, 0x2b, x0, x0, x1     /* ymodesw.i */
    TEST_FAIL_S10

/*
 * Trap handler: counts causes 5/7/33/34 in s2/s3/s7/s8, illegal
 * instructions (cause 2) in s11 and anything else in s6, then skips the
 * faulting (4-byte) instruction.
 */
.balign 4
trap_handler:
    csrr t6, CSR_MCAUSE
    li   t5, 5
    bne  t6, t5, 1f
    addi s2, s2, 1
    j    9f
1:
    li   t5, 7
    bne  t6, t5, 2f
    addi s3, s3, 1
    j    9f
2:
    li   t5, 33
    bne  t6, t5, 3f
    addi s7, s7, 1
    j    9f
3:
    li   t5, 34
    bne  t6, t5, 4f
    addi s8, s8, 1
    j    9f
4:
    li   t5, 2
    bne  t6, t5, 5f
    addi s11, s11, 1
    j    9f
5:
    addi s6, s6, 1
9:
    csrr t6, CSR_MEPC
    addi t6, t6, 4
    csrw CSR_MEPC, t6
    mret

.section .bss
.balign 16
buf:
    .space 64

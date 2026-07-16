/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY v0.9.9 instruction encoding and semantics tests. All RVY instructions
 * are emitted with .insn since assemblers do not know the new encodings yet.
 *
 * Custom-3 opcode = 0x7b. R-type funct7 values used below:
 *   0x17 YSENTRY (cs1 must be 0)   0x78 YAMASK (funct5 in rs2 = 0)
 *   0x7a two-operand get group (funct5 in rs2: 3=YLENR 4=YTAGR 5=YTYPER)
 *   0x7b pre-0.9.9 YSENTRY slot (now illegal)
 * funct3=5 immediates: SRLIY (imm[11:5]=0, shamt=XLEN) and
 * YBNDSWI (imm[11:9]=0b111, 9-bit length immediate).
 */
#include "testmacros.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAP_HANDLER

    /* Test 1: YAMASK of length 0 -> all-ones mask */
    li   s10, 1
    li   t0, 0
    .insn r 0x7b, 0, 0x78, t1, t0, x0
    li   t2, -1
    bne  t2, t1, fail

    /* Test 2: YAMASK of an inexactly representable length -> the mask is
     * still contiguous ones in the high bits, but not all-ones */
    li   s10, 2
    li   t0, 0x10000001
    .insn r 0x7b, 0, 0x78, t1, t0, x0
    not  t2, t1
    beqz t2, fail                /* must require some rounding */
    addi t3, t2, 1
    and  t3, t3, t2
    bnez t3, fail                /* ~mask + 1 must be a power of two */

    /* Test 3: YBNDSWI immediate decoding, one value per region.
     * The root capability (from ddc) keeps its tag for exact bounds. */
    li   s10, 3
    csrrs t0, CSR_DDC, x0        /* ct0 = root capability */

.macro CHECK_YBNDSWI imm9, length
    .insn i 0x7b, 5, t1, t0, \imm9 - 512
    .insn r 0x7b, 0, 0x7a, t2, t1, x4    /* ytagr */
    beqz t2, fail
    .insn r 0x7b, 0, 0x7a, t2, t1, x3    /* ylenr */
    li   t3, \length
    bne  t3, t2, fail
.endm

    CHECK_YBNDSWI 0x000, 4096    /* page-sized */
    CHECK_YBNDSWI 0x001, 1       /* byte granular */
    CHECK_YBNDSWI 0x010, 16
    CHECK_YBNDSWI 0x0ff, 255
    CHECK_YBNDSWI 0x100, 256     /* 8-byte granular */
    CHECK_YBNDSWI 0x11f, 504
    CHECK_YBNDSWI 0x120, 512     /* 16-byte granular */
#if __riscv_xlen == 64
    CHECK_YBNDSWI 0x1ff, 4080
#else
    /* 4080 is not exactly representable in the RV32 capability format, so
     * the exact bounds request must clear the tag */
    .insn i 0x7b, 5, t1, t0, 0x1ff - 512
    .insn r 0x7b, 0, 0x7a, t2, t1, x4    /* ytagr = 0 */
    bnez t2, fail
#endif

    /* Test 4: YSENTRY (v0.9.9 encoding: source in cs2, cs1 = 0) */
    li   s10, 4
    .insn r 0x7b, 0, 0x17, t1, x0, t0
    .insn r 0x7b, 0, 0x7a, t2, t1, x4    /* ytagr = 1 */
    beqz t2, fail
    .insn r 0x7b, 0, 0x7a, t2, t1, x5    /* ytyper = 1 (sentry) */
    li   t3, 1
    bne  t3, t2, fail
    /* sealing an already sealed capability clears the tag */
    .insn r 0x7b, 0, 0x17, t4, x0, t1
    .insn r 0x7b, 0, 0x7a, t2, t4, x4    /* ytagr = 0 */
    bnez t2, fail

    /* Test 5: the pre-0.9.9 YSENTRY encoding (2OP space) must be illegal */
    li   s10, 5
    mv   s0, s11
    addi s0, s0, 1
    .insn r 0x7b, 0, 0x7b, t1, t0, x0
    bne  s11, s0, fail

    /* Test 6: SRLIY only accepts shamt == XLEN */
    li   s10, 6
    .insn i 0x7b, 5, t1, t0, __riscv_xlen
    beqz t1, fail                /* pesbt of the root cap is non-zero */
    mv   s0, s11
    addi s0, s0, 1
    .insn i 0x7b, 5, t1, t0, __riscv_xlen - 1    /* reserved shamt */
    bne  s11, s0, fail
    /* funct3=5 immediates in neither the SRLIY nor YBNDSWI range */
    mv   s0, s11
    addi s0, s0, 1
    .insn i 0x7b, 5, t1, t0, 0x100
    bne  s11, s0, fail

    TEST_PASS
fail:
    TEST_FAIL_S10

TRAP_HANDLER

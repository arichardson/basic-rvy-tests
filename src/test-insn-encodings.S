/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY v0.9.9 instruction encoding and semantics tests, including YAMASK,
 * YBNDSWI, YSENTRY (and its pre-0.9.9 opcode), SRLIY by XLEN vs reserved
 * shift amounts, and YMODEW (both valid cd != x0 updates and the v0.9.9
 * reservation of cd = x0 outside YMODESWY/YMODESWI). RVY instructions are
 * emitted via the macros in testmacros.h since assemblers do not know the
 * new encodings yet.
 */
#define TEST_NAME "insn-encodings"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* YAMASK of length 0 -> all-ones mask */
    NEXT_TEST "yamask of length 0 gives an all-ones mask"
    li   t0, 0
    YAMASK t1, t0
    li   t2, -1
    bne  t2, t1, fail

    /* YAMASK of an inexactly representable length -> the mask is
     * still contiguous ones in the high bits, but not all-ones */
    NEXT_TEST "yamask of an inexact length rounds to contiguous high bits"
    li   t0, 0x10000001
    YAMASK t1, t0
    not  t2, t1
    beqz t2, fail                /* must require some rounding */
    addi t3, t2, 1
    and  t3, t3, t2
    bnez t3, fail                /* ~mask + 1 must be a power of two */

    /* ddc is the root capability the cases below derive from. */
    csrrs t0, CSR_DDC, x0

#ifndef CHERI_093
    /*
     * YBNDSWI, one length per representable region. The root
     * capability keeps its tag for exact bounds. 0.9.3 spells the same
     * operation scbndsi with a scale and a 5-bit immediate, so these regions
     * are specific to the v0.9.9 encoding.
     */
    NEXT_TEST "ybndswi encodes one length from each representable region"

.macro CHECK_YBNDSWI length
    YBNDSWI t1, t0, \length
    YTAGR t2, t1
    beqz t2, fail
    YLENR t2, t1
    li   t3, \length
    bne  t3, t2, fail
.endm

    CHECK_YBNDSWI 4096           /* page-sized */
    CHECK_YBNDSWI 1              /* byte granular */
    CHECK_YBNDSWI 16
    CHECK_YBNDSWI 255
    CHECK_YBNDSWI 256            /* 8-byte granular */
    CHECK_YBNDSWI 504
    CHECK_YBNDSWI 512            /* 16-byte granular */
#if __riscv_xlen == 64
    CHECK_YBNDSWI 4080
#else
    /* 4080 is not exactly representable in the RV32 capability format, so
     * the exact bounds request must clear the tag */
    YBNDSWI t1, t0, 4080
    YTAGR t2, t1                 /* ytagr = 0 */
    bnez t2, fail
#endif
#endif /* !CHERI_093 */

    /* YSENTRY (the macro picks each version's encoding) */
    NEXT_TEST "ysentry seals as a sentry and sealing again detags"
    YSENTRY t1, t0
    YTAGR t2, t1                 /* ytagr = 1 */
    beqz t2, fail
    YTYPER t2, t1                /* ytyper = 1 (sentry) */
    li   t3, 1
    bne  t3, t2, fail
    /* sealing an already sealed capability clears the tag */
    YSENTRY t4, t1
    YTAGR t2, t4                 /* ytagr = 0 */
    bnez t2, fail

#ifndef CHERI_093
    /* The pre-0.9.9 YSENTRY encoding (2OP space) must be illegal */
    NEXT_TEST "the pre-0.9.9 ysentry encoding is illegal"
    .insn r 0x7b, 0, 0x7b, t1, t0, x0    /* pre-0.9.9 YSENTRY: now illegal */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

#ifndef CHERI_093
    /* SRLIY only accepts shamt == XLEN (0.9.3 has no such form) */
    NEXT_TEST "srliy by XLEN reads the metadata"
    SRLIY t1, t0, __riscv_xlen
    beqz t1, fail                /* pesbt of the root cap is non-zero */
    EXPECT_NO_TRAP

    NEXT_TEST "srliy by XLEN-1 is a reserved shift amount"
    SRLIY t1, t0, __riscv_xlen - 1    /* reserved shamt */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    /* funct3=5 immediates in neither the SRLIY nor YBNDSWI range */
    NEXT_TEST "a funct3=5 immediate outside both ranges is illegal"
    SRLIY t1, t0, 0x100
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

    /*
     * YMODEW sets the execution mode of an unsealed executable capability
     * when cd != x0. In v0.9.9, encodings with funct7=0x2b and cd=x0 outside
     * YMODESWY (cs1=x0, rs2=x0) and YMODESWI (cs1=x0, rs2=x1) are reserved;
     * in 0.9.3 (scmode), cd=x0 simply discards the result.
     */
    NEXT_TEST "ymodew updates the execution mode in integer and capability mode"
    li   t2, 1
    YMODEW t1, t0, t2
    YTAGR t3, t1
    beqz t3, fail
    YMODER t3, t1
    bne  t3, t2, fail
    YMODESWY
    YMODEW t1, t1, x0
    YMODESWI
    YTAGR t3, t1
    beqz t3, fail
    YMODER t3, t1
    bnez t3, fail
    EXPECT_NO_TRAP

    NEXT_TEST "ymodew with cd=x0 and cs1!=x0 is reserved in v0.9.9"
    YMODEW x0, t0, x0
#ifdef CHERI_093
    EXPECT_NO_TRAP
#else
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

    NEXT_TEST "ymodew with cd=x0, cs1=x0, and rs2>1 is reserved in v0.9.9"
    li   t2, 2
    YMODEW x0, x0, t2
#ifdef CHERI_093
    EXPECT_NO_TRAP
#else
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

    TEST_PASS
fail:
    TEST_FAIL

TRAP_HANDLER

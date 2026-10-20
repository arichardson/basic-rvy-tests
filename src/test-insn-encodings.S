/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY instruction encoding and reserved-encoding tests across v0.9.10, v0.9.9,
 * and 0.9.3:
 *
 *  - The pre-0.9.9 YSEALE encoding in the 2-operand space (funct7=0x7b) raises
 *    an illegal-instruction exception on RVY.
 *  - Reading the metadata half via YHIR (v0.9.10) or SRLIY by XLEN (v0.9.9).
 *  - In v0.9.9, SRLIY with any shift amount other than XLEN (such as 8 or
 *    XLEN-1) raises an illegal-instruction exception.
 *  - Immediate encodings with funct3=5 outside the YBNDSWI (and v0.9.9 SRLIY)
 *    range raise an illegal-instruction exception on RVY.
 *  - On RV32, the RV64-only YSH4ADD and YSH*ADD.UW encodings raise an
 *    illegal-instruction exception.
 *  - On RVY, YMODEW encodings with cd=x0 outside YMODESWY (cs1=x0, rs2=x0) and
 *    YMODESWI (cs1=x0, rs2=x1) are reserved and raise an illegal-instruction
 *    exception; in 0.9.3 (scmode), cd=x0 discards the result without trapping.
 */
#define TEST_NAME "insn-encodings"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs t0, CSR_DDC, x0

#ifndef CHERI_093
    /* The pre-0.9.9 YSEALE encoding (2OP space) must be illegal */
    NEXT_TEST "the pre-0.9.9 yseale encoding is illegal"
    .insn r 0x7b, 0, 0x7b, t1, t0, x0    /* pre-0.9.9 YSEALE: now illegal */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    /*
     * Reading the metadata half: v0.9.10 uses YHIR (2OP rs2=7), whereas
     * v0.9.9 uses SRLIY by XLEN.
     */
    NEXT_TEST "yhir (or v0.9.9 srliy by XLEN) reads the metadata"
    YHIR t1, t0
    EXPECT_NONZERO t1            /* pesbt of the root cap is non-zero */
    EXPECT_NO_TRAP

#ifdef CHERI_099
    /* Any SRLIY shift amount other than XLEN is a reserved encoding in v0.9.9. */
    NEXT_TEST "srliy by 8 is a reserved shift amount"
    SRLIY t1, t0, 8
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "srliy by XLEN-1 is a reserved shift amount"
    SRLIY t1, t0, __riscv_xlen - 1    /* reserved shamt */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "srliy by XLEN-1 is a reserved shift amount"
    SRLIY t1, t0, XLEN - 1
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

    /* funct3=5 immediates outside the YBNDSWI (and v0.9.9 SRLIY) range */
    NEXT_TEST "a funct3=5 immediate outside the ybndswi range is illegal"
    .insn i RVY_OPC, 5, t1, t0, 0x100
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

#if __riscv_xlen == 32
    /* YSH4ADD and the .UW shifted-add forms are RV64-only. */
    NEXT_TEST "ysh4add and unsigned-word shifted adds are illegal on RV32"
    YSH4ADD t1, t2, t0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH1ADD_UW t1, t2, t0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH2ADD_UW t1, t2, t0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH3ADD_UW t1, t2, t0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH4ADD_UW t1, t2, t0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif
#endif

    /*
     * In v0.9.9, YMODEW encodings with funct7=0x2b and cd=x0 outside
     * YMODESWY (cs1=x0, rs2=x0) and YMODESWI (cs1=x0, rs2=x1) are reserved;
     * in 0.9.3 (scmode), cd=x0 simply discards the result.
     */
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

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Zca 16-bit and base-ISA 32-bit HINT encodings in integer and capability
 * pointer modes:
 *
 *  - Zca HINTs with rd = x0 (c.nop, c.li x0, c.lui x0, c.mv x0, c.add x0
 *    including Zihintntl c.ntl.*, and c.slli x0 / c.slli64 x0) are no-ops in
 *    both integer and capability mode and leave source capabilities and x0
 *    untouched (riscv-unpriv-integration.adoc "Zca HINT Encodings").
 *  - On RVY in integer mode, Zca zero-immediate/shift HINTs with rd != x0
 *    (c.addi rd, 0; c.slli64 rd; c.srli64 rd'; c.srai64 rd') write the XLEN
 *    integer value of rd back as an untagged integer, clearing rd's
 *    capability tag.
 *  - 32-bit integer ALU and Zihintntl HINTs with rd = x0, as well as pause
 *    and fence / fence.tso / fence.i encodings with non-zero rd or rs1,
 *    execute without trapping or modifying capability registers in both modes.
 */
#define TEST_NAME "hints"
#include "testmacros.h"
#include "exceptions.h"

#define root  s0                 /* ddc */
#define cap   s1                 /* tagged capability for test operands */

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    csrrs root, CSR_DDC, x0
    lla   t0, _start
    YADDRW cap, root, t0

    NEXT_TEST "c.nop with zero and non-zero immediates is a no-op in both modes"
    YMODESWI
    INSN16 0x0001                /* c.nop */
    INSN16 0x0005                /* c.nop 1 */
    INSN16 0x107d                /* c.nop -1 */
    YMODESWY
    INSN16 0x0001                /* c.nop */
    INSN16 0x0005                /* c.nop 1 */
    INSN16 0x107d                /* c.nop -1 */
    EXPECT_NO_TRAP
    YTAGR t1, x0
    EXPECT_ZERO t1
    mv   t1, x0
    EXPECT_ZERO t1

    NEXT_TEST "c.li x0 and c.lui x0 HINT encodings are no-ops in both modes"
    YMODESWI
    INSN16 0x4001                /* c.li x0, 0 */
    INSN16 0x4005                /* c.li x0, 1 */
    INSN16 0x507d                /* c.li x0, -1 */
    INSN16 0x6005                /* c.lui x0, 1 */
    INSN16 0x607d                /* c.lui x0, 31 */
    YMODESWY
    INSN16 0x4001                /* c.li x0, 0 */
    INSN16 0x4005                /* c.li x0, 1 */
    INSN16 0x507d                /* c.li x0, -1 */
    INSN16 0x6005                /* c.lui x0, 1 */
    INSN16 0x607d                /* c.lui x0, 31 */
    EXPECT_NO_TRAP
    YTAGR t1, x0
    EXPECT_ZERO t1
    mv   t1, x0
    EXPECT_ZERO t1

    NEXT_TEST "c.mv x0, rs2 and c.add x0, rs2 (including c.ntl.*) are no-ops in both modes"
    YMV  a0, cap
    YMV  sp, cap
    YMODESWI
    C_YMV x0, a0                 /* c.mv x0, a0 */
    C_ADD x0, a0                 /* c.add x0, a0 */
    C_ADD x0, x2                 /* c.ntl.p1 */
    C_ADD x0, x3                 /* c.ntl.pall */
    C_ADD x0, x4                 /* c.ntl.s1 */
    C_ADD x0, x5                 /* c.ntl.all */
    YMODESWY
    C_YMV x0, a0                 /* c.mv x0, a0 */
    C_ADD x0, a0                 /* c.add x0, a0 */
    C_ADD x0, x2                 /* c.ntl.p1 */
    C_ADD x0, x3                 /* c.ntl.pall */
    C_ADD x0, x4                 /* c.ntl.s1 */
    C_ADD x0, x5                 /* c.ntl.all */
    EXPECT_NO_TRAP
    EXPECT_TAG a0, 1
    EXPECT_TAG sp, 1
    YTAGR t1, x0
    EXPECT_ZERO t1
    mv   t1, x0
    EXPECT_ZERO t1

    NEXT_TEST "c.slli x0 with zero and non-zero shift amounts is a no-op in both modes"
    YMODESWI
    INSN16 0x0002                /* c.slli64 x0 (shamt = 0) */
    INSN16 0x0006                /* c.slli x0, 1 */
    INSN16 0x007e                /* c.slli x0, 31 */
    YMODESWY
    INSN16 0x0002                /* c.slli64 x0 (shamt = 0) */
    INSN16 0x0006                /* c.slli x0, 1 */
    INSN16 0x007e                /* c.slli x0, 31 */
    EXPECT_NO_TRAP
    YTAGR t1, x0
    EXPECT_ZERO t1
    mv   t1, x0
    EXPECT_ZERO t1

#ifndef CHERI_093
    NEXT_TEST "integer mode: c.addi rd, 0 and c.slli64/c.srli64/c.srai64 clear rd's capability tag"
    YMODESWI
    YMV  a0, cap
    INSN16 0x0501                /* c.addi a0, 0 */
    EXPECT_TAG a0, 0
    EXPECT_EQ a0, cap
    YMV  a0, cap
    INSN16 0x0502                /* c.slli64 a0 */
    EXPECT_TAG a0, 0
    EXPECT_EQ a0, cap
    YMV  a0, cap
    INSN16 0x8101                /* c.srli64 a0 */
    EXPECT_TAG a0, 0
    EXPECT_EQ a0, cap
    YMV  a0, cap
    INSN16 0x8501                /* c.srai64 a0 */
    EXPECT_TAG a0, 0
    EXPECT_EQ a0, cap
    EXPECT_NO_TRAP
#endif

    NEXT_TEST "32-bit integer ALU and Zihintntl HINTs with rd = x0 are no-ops in both modes"
    YMV  a0, cap
    YMV  a1, cap
    YMV  sp, cap
    YMODESWI
    addi  x0, a0, 0
    addi  x0, x0, 123
    andi  x0, a0, -1
    ori   x0, a0, 1
    xori  x0, a0, 1
    slli  x0, a0, 1
    srli  x0, a0, 1
    srai  x0, a0, 1
    slti  x0, a0, 1
    sltiu x0, a0, 1
    lui   x0, 0x12345
    auipc x0, 0x12345
    add   x0, a0, a1
    sub   x0, a0, a1
    and   x0, a0, a1
    or    x0, a0, a1
    xor   x0, a0, a1
    sll   x0, a0, a1
    srl   x0, a0, a1
    sra   x0, a0, a1
    slt   x0, a0, a1
    sltu  x0, a0, a1
    add   x0, x0, x2             /* ntl.p1 */
    add   x0, x0, x3             /* ntl.pall */
    add   x0, x0, x4             /* ntl.s1 */
    add   x0, x0, x5             /* ntl.all */
    YMODESWY
    addi  x0, a0, 0
    addi  x0, x0, 123
    andi  x0, a0, -1
    ori   x0, a0, 1
    xori  x0, a0, 1
    slli  x0, a0, 1
    srli  x0, a0, 1
    srai  x0, a0, 1
    slti  x0, a0, 1
    sltiu x0, a0, 1
    lui   x0, 0x12345
    auipc x0, 0x12345
    add   x0, a0, a1
    sub   x0, a0, a1
    and   x0, a0, a1
    or    x0, a0, a1
    xor   x0, a0, a1
    sll   x0, a0, a1
    srl   x0, a0, a1
    sra   x0, a0, a1
    slt   x0, a0, a1
    sltu  x0, a0, a1
    add   x0, x0, x2             /* ntl.p1 */
    add   x0, x0, x3             /* ntl.pall */
    add   x0, x0, x4             /* ntl.s1 */
    add   x0, x0, x5             /* ntl.all */
    EXPECT_NO_TRAP
    EXPECT_TAG a0, 1
    EXPECT_TAG a1, 1
    EXPECT_TAG sp, 1
    YTAGR t1, x0
    EXPECT_ZERO t1
    mv   t1, x0
    EXPECT_ZERO t1

    NEXT_TEST "32-bit pause, fence, fence.tso, and fence.i HINTs are no-ops in both modes"
    YMV  a0, cap
    YMODESWI
    .insn i 0x0f, 0, x0, x0, 0x010       /* pause */
    .insn i 0x0f, 0, a0, a0, 0x0ff       /* fence iorw, iorw with rd = rs1 = a0 */
    .insn i 0x0f, 0, a0, a0, -0x7cd      /* fence.tso with rd = rs1 = a0 (imm = 0x833) */
    .insn i 0x0f, 1, a0, a0, -1          /* fence.i with imm = 0xfff, rd = rs1 = a0 */
    YMODESWY
    .insn i 0x0f, 0, x0, x0, 0x010       /* pause */
    .insn i 0x0f, 0, a0, a0, 0x0ff       /* fence iorw, iorw with rd = rs1 = a0 */
    .insn i 0x0f, 0, a0, a0, -0x7cd      /* fence.tso with rd = rs1 = a0 (imm = 0x833) */
    .insn i 0x0f, 1, a0, a0, -1          /* fence.i with imm = 0xfff, rd = rs1 = a0 */
    EXPECT_NO_TRAP
    EXPECT_TAG a0, 1
    YEQ  t1, a0, cap
    EXPECT_NONZERO t1

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability cursor addition and shifted-addition instructions:
 *
 *  - YADD increments a capability's cursor by a signed XLEN register offset,
 *    preserving the tag when the result is representable and producing an
 *    untagged capability at rs2 when cs1 = x0.
 *  - On RVY, YSH1ADD, YSH2ADD, and YSH3ADD (plus YSH4ADD and YSH1ADD.UW
 *    through YSH4ADD.UW on RV64) shift rs1 left by 1..4 bits (zero-extending
 *    the low 32 bits for the .UW forms) and add it to cs2.
 */
#define TEST_NAME "cap-add"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs s0, CSR_DDC, x0
    lla   t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */

    YMODESWY

    /* YADD increments the cursor by rs2 and preserves the tag in bounds. */
    NEXT_TEST "yadd increments the cursor by a positive register offset"
    li   t1, 24
    YADD a2, a0, t1
    EXPECT_TAG a2, 1
    lla   t2, buf + 24
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    NEXT_TEST "yadd decrements the cursor by a negative register offset"
    li   t1, -8
    YADD a2, a2, t1
    EXPECT_TAG a2, 1
    lla   t2, buf + 16
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    NEXT_TEST "yadd with cs1 = x0 produces an untagged capability at rs2"
    lla   t2, buf + 16
    YADD a3, x0, t2              /* cs1 = x0 produces an untagged capability at rs2 */
    EXPECT_TAG a3, 0
    EXPECT_EQ a3, t2
    EXPECT_NO_TRAP

#ifndef CHERI_093
    /* YSH1ADD through YSH3ADD (and YSH4ADD / .UW on RV64) shift rs1 and add to cs2. */
    li   t1, 5

    NEXT_TEST "ysh1add shifts rs1 by 1 before adding to cs2"
    YSH1ADD a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 10
    EXPECT_EQ a2, t2
    YSH1ADD x0, t1, a0           /* cd = x0 discards the result */
    EXPECT_NO_TRAP

    NEXT_TEST "ysh2add shifts rs1 by 2 before adding to cs2"
    YSH2ADD a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 20
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    NEXT_TEST "ysh3add shifts rs1 by 3 before adding to cs2"
    YSH3ADD a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 40
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

#if __riscv_xlen == 64
    NEXT_TEST "ysh4add shifts rs1 by 4 before adding to cs2 on RV64"
    YSH4ADD a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 80
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    /* Set bits [63:32] all-ones and low 32 bits = 6 so .uw strips the upper half. */
    li   t1, -0x100000000 + 6

    NEXT_TEST "ysh1add.uw zero-extends 32-bit rs1 and shifts by 1 on RV64"
    YSH1ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 12
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    NEXT_TEST "ysh2add.uw zero-extends 32-bit rs1 and shifts by 2 on RV64"
    YSH2ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 24
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    NEXT_TEST "ysh3add.uw zero-extends 32-bit rs1 and shifts by 3 on RV64"
    YSH3ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 48
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP

    NEXT_TEST "ysh4add.uw zero-extends 32-bit rs1 and shifts by 4 on RV64"
    YSH4ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    lla   t2, buf + 96
    EXPECT_EQ a2, t2
    EXPECT_NO_TRAP
#endif
#endif /* !CHERI_093 */

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
buf:
    .space 4096

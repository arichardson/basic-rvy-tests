/* SPDX-License-Identifier: BSD-2-Clause
 *
 * CHERI Zba address-generation instructions and rounding bounds (golden Sail
 * src/cheri_insts_zba.sail:10-103, src/cheri_insts.sail:405-445):
 *
 *  - ysh1add..ysh4add (ZBA_Y_RTYPE, :59-103) increment cs2's address by
 *    rs1 << (1..4) via incCapAddrChecked, keeping the tag and bounds when cs2
 *    is tagged, unsealed, and well-formed and the new address is within its
 *    representable range.
 *  - ysh1add.uw..ysh4add.uw (ZBA_Y_RTYPEUW, :10-56, RV64 only) zero-extend
 *    rs1[31:0] before shifting by 1..4.
 *  - Sealed capabilities, unrepresentable target addresses, and untagged or
 *    malformed capabilities produce an untagged result at the shifted address.
 *  - ysh1add with cs2 = x0 computes 0 + (rs1 << 1) (not an alternate ytopr).
 *  - ybndsrw rounds an inexact length up and preserves the tag, whereas
 *    ybndsw clears the tag on the same length.
 */
#define TEST_NAME "zba-cap"
#ifdef CHERI_093
#error "RVY v0.9.9 only"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define root  s0                 /* ddc */
#define bufp  s1                 /* address of buf */

.macro EXPECT_TAG reg, tag
    YTAGR t3, \reg
    li   t4, \tag
    bne  t4, t3, fail
.endm

.macro EXPECT_CAP reg, tag, base_reg, addr_off, len
    EXPECT_TAG \reg, \tag
    addi t4, \base_reg, \addr_off
    bne  t4, \reg, fail
    YBASER t3, \reg
    bne  \base_reg, t3, fail
    YLENR t3, \reg
    li   t4, \len
    bne  t4, t3, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    csrrs root, CSR_DDC, x0
    la   bufp, buf
    YMODESWY

    /* a0 = [buf, buf + 256), cursor at buf. */
    li   t0, 256
    YADDRW a0, root, bufp
    YBNDSW a0, a0, t0

    NEXT_TEST "ysh1add..ysh4add shift rs1 by 1..4 and preserve bounds and tag"
    li   a1, 3
    YSH1ADD a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 6, 256
    YSH2ADD a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 12, 256
    YSH3ADD a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 24, 256
    YSH4ADD a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 48, 256

    NEXT_TEST "ysh1add..ysh4add use the full 64-bit signed rs1 offset"
    li   a1, -2
    YADDI a3, a0, 64             /* cursor at buf + 64 */
    YSH1ADD a2, a1, a3
    EXPECT_CAP a2, 1, bufp, 60, 256
    YSH2ADD a2, a1, a3
    EXPECT_CAP a2, 1, bufp, 56, 256
    YSH3ADD a2, a1, a3
    EXPECT_CAP a2, 1, bufp, 48, 256
    YSH4ADD a2, a1, a3
    EXPECT_CAP a2, 1, bufp, 32, 256

    NEXT_TEST "ysh1add.uw..ysh4add.uw zero-extend rs1[31:0] before shifting"
    li   a1, 1
    slli a1, a1, 32
    ori  a1, a1, 3               /* a1 = 0x1_0000_0003: low word is 3 */
    YSH1ADD_UW a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 6, 256
    YSH2ADD_UW a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 12, 256
    YSH3ADD_UW a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 24, 256
    YSH4ADD_UW a2, a1, a0
    EXPECT_CAP a2, 1, bufp, 48, 256

    NEXT_TEST "ysh1add.uw..ysh4add.uw treat bit 31 of rs1 as unsigned"
    YADDRW a3, root, bufp        /* root capability at buf */
    li   a1, -1
    slli a1, a1, 31              /* a1 = 0xffffffff_80000000: low word 2^31 */
    li   t0, 1
    slli t0, t0, 31              /* t0 = 0x00000000_80000000 */
    YSH1ADD_UW a2, a1, a3
    EXPECT_TAG a2, 1
    slli t1, t0, 1
    add  t1, bufp, t1
    bne  t1, a2, fail
    YSH2ADD_UW a2, a1, a3
    EXPECT_TAG a2, 1
    slli t1, t0, 2
    add  t1, bufp, t1
    bne  t1, a2, fail
    YSH3ADD_UW a2, a1, a3
    EXPECT_TAG a2, 1
    slli t1, t0, 3
    add  t1, bufp, t1
    bne  t1, a2, fail
    YSH4ADD_UW a2, a1, a3
    EXPECT_TAG a2, 1
    slli t1, t0, 4
    add  t1, bufp, t1
    bne  t1, a2, fail

    NEXT_TEST "ysh1add with cs2 = x0 computes rs1 << 1, not ytopr"
    li   a1, 0x200
    YSH1ADD a2, a1, x0
    EXPECT_TAG a2, 0
    li   t1, 0x400
    bne  t1, a2, fail
    YSH1ADD a2, x0, x0
    EXPECT_TAG a2, 0
    bnez a2, fail

    NEXT_TEST "ysh1add..ysh4add and .uw clear the tag of a sealed capability"
    YSENTRY a3, a0
    li   a1, 3
    YSH1ADD a2, a1, a3
    EXPECT_TAG a2, 0
    addi t1, bufp, 6
    bne  t1, a2, fail
    YSH2ADD a2, a1, a3
    EXPECT_TAG a2, 0
    addi t1, bufp, 12
    bne  t1, a2, fail
    YSH3ADD_UW a2, a1, a3
    EXPECT_TAG a2, 0
    addi t1, bufp, 24
    bne  t1, a2, fail
    YSH4ADD_UW a2, a1, a3
    EXPECT_TAG a2, 0
    addi t1, bufp, 48
    bne  t1, a2, fail
    /* Even a zero displacement on a sealed capability clears its tag. */
    YSH1ADD a2, x0, a3
    EXPECT_TAG a2, 0
    bne  bufp, a2, fail

    NEXT_TEST "ysh1add and ysh1add.uw detag when shifting outside rep range"
    li   a1, 0x2000              /* +0x4000: outside E=0 representable range */
    YSH1ADD a2, a1, a0
    EXPECT_TAG a2, 0
    li   t1, 0x4000
    add  t1, bufp, t1
    bne  t1, a2, fail
    YSH1ADD_UW a2, a1, a0
    EXPECT_TAG a2, 0
    bne  t1, a2, fail

    NEXT_TEST "ysh1add..ysh4add and .uw leave malformed capabilities untagged"
    SRLIY t0, a0, 64
    li   t1, (1 << 28)           /* non-zero reserved_0 bit -> malformed */
    or   t0, t0, t1
    PACKY a3, bufp, t0
    li   a1, 3
    YSH1ADD a2, a1, a3
    EXPECT_TAG a2, 0
    addi t1, bufp, 6
    bne  t1, a2, fail
    YSH4ADD_UW a2, a1, a3
    EXPECT_TAG a2, 0
    addi t1, bufp, 48
    bne  t1, a2, fail

    NEXT_TEST "ybndsrw rounds inexact lengths up and keeps exact lengths exact"
    YADDRW a3, root, bufp
    li   t0, 0x80
    YBNDSRW a2, a3, t0
    EXPECT_CAP a2, 1, bufp, 0, 0x80
    li   t0, 0x1001              /* requires E > 0 rounding */
    YBNDSRW a2, a3, t0
    EXPECT_TAG a2, 1
    YLENR t1, a2
    bltu t1, t0, fail
    YBNDSW a2, a3, t0
    EXPECT_TAG a2, 0

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER_PCC

.section .bss
.balign 256
buf:
    .space 256

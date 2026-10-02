/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Out-of-representable-range and sentry cursor-update tests across both RV64
 * (128-bit format, MW = 14) and RV32 (64-bit format, MW = 10):
 *
 *  For a capability with exponent E and base B_full (aligned to 2^E), the
 *  representable region is [rep_base, rep_top) where:
 *    rep_base = B_full - 2^(E + MW - 2)
 *    rep_top  = B_full + 3 * 2^(E + MW - 2)
 *    span     = 2^(E + MW)
 *
 *  On RV64 (MW = 14):
 *    E = 0 (length 64):     rep_base = base - 0x1000, rep_top = base + 0x3000
 *    E = 1 (length 0x2000): rep_base = base - 0x2000, rep_top = base + 0x6000
 *  On RV32 (MW = 10):
 *    E = 0 (length 64):     rep_base = base - 0x100,  rep_top = base + 0x300
 *    E = 1 (length 0x200):  rep_base = base - 0x200,  rep_top = base + 0x600
 *
 *  - YADDRW, YADD, YADDI, and (on RVY) YSH1ADD through YSH4ADD and their .UW
 *    variants preserve the tag and decoded bounds throughout [rep_base, rep_top)
 *    and clear the tag as soon as the new cursor reaches rep_base - 1 or
 *    rep_top.
 *  - Moving an already-detagged cursor back into [base, top) updates the
 *    cursor and restores the decoded bounds to [base, top), without restoring
 *    the tag.
 *  - The root capability [0, 2^XLEN) is representable at every address.
 *  - Any cursor update on a sealed sentry (YADDRW, YADD, YADDI even with a 0
 *    immediate, or YSH1ADD) clears its tag, whereas YMV preserves it.
 *  - Capability-mode AUIPC from a bounded PCC keeps the tag inside the
 *    representable range and clears the tag when pc + (imm20 << 12) leaves
 *    [rep_base, rep_top).
 */
#define TEST_NAME "representable-range"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define REP_E0_LEN   64
#define REP_E0_BELOW 0x1000
#define REP_E0_ABOVE 0x3000
#define REP_E0_SPAN  0x4000
#define REP_E1_LEN   0x2000
#define REP_E1_BELOW 0x2000
#define REP_E1_ABOVE 0x6000
#define REP_E1_SPAN  0x8000
#else
#define REP_E0_LEN   64
#define REP_E0_BELOW 0x100
#define REP_E0_ABOVE 0x300
#define REP_E0_SPAN  0x400
#define REP_E1_LEN   0x200
#define REP_E1_BELOW 0x200
#define REP_E1_ABOVE 0x600
#define REP_E1_SPAN  0x800
#endif

.macro EXPECT_BOUNDS reg, base_reg, len
    YBASER t3, \reg
    bne  t3, \base_reg, fail
    YLENR t3, \reg
    li   t4, \len
    bne  t4, t3, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs s0, CSR_DDC, x0
    la    s1, buf_mid            /* s1 = base address with headroom on both sides */
    YADDRW a0, s0, s1
    li    t0, REP_E0_LEN
    YBNDSW a0, a0, t0            /* a0: E = 0 capability [s1, s1 + 64) */

    YADDRW a1, s0, s1
    li    t0, REP_E1_LEN
    YBNDSW a1, a1, t0            /* a1: E = 1 capability [s1, s1 + REP_E1_LEN) */

    YMODESWY                     /* capability mode */

    /* Root capability [0, 2^XLEN) is representable across the entire address space. */
    NEXT_TEST "root capability keeps its tag at any cursor address"
    YADDRW a2, s0, x0
    EXPECT_TAG a2, 1
    li   t0, -1
    YADDRW a2, s0, t0
    EXPECT_TAG a2, 1
    bne  a2, t0, fail
    li   t1, 1
    YADD a2, a2, t1              /* wraps from ~0 to 0 */
    EXPECT_TAG a2, 1
    bnez a2, fail
    EXPECT_NO_TRAP

    /* E = 0 lower boundary via YADDRW: rep_base is representable, rep_base - 1 detags. */
    NEXT_TEST "yaddrw at E=0 rep_base keeps the tag and bounds"
    li   t0, REP_E0_BELOW
    sub  t1, s1, t0              /* t1 = rep_base */
    YADDRW a2, a0, t1
    EXPECT_TAG a2, 1
    bne  a2, t1, fail
    EXPECT_BOUNDS a2, s1, REP_E0_LEN
    EXPECT_NO_TRAP

    NEXT_TEST "yaddrw at E=0 rep_base - 1 clears the tag and shifts decoded base"
    addi t1, t1, -1              /* t1 = rep_base - 1 */
    YADDRW a2, a0, t1
    EXPECT_TAG a2, 0
    bne  a2, t1, fail
    li   t0, REP_E0_SPAN
    sub  t2, s1, t0              /* decoded base shifts down by 2^(E+MW) */
    EXPECT_BOUNDS a2, t2, REP_E0_LEN
    /* Returning cursor to s1 restores decoded bounds without restoring tag. */
    YADDRW a2, a2, s1
    EXPECT_TAG a2, 0
    EXPECT_BOUNDS a2, s1, REP_E0_LEN
    EXPECT_NO_TRAP

    /* E = 0 upper boundary via YADDRW: rep_top - 1 is representable, rep_top detags. */
    NEXT_TEST "yaddrw at E=0 rep_top - 1 keeps the tag and bounds"
    li   t0, REP_E0_ABOVE - 1
    add  t1, s1, t0              /* t1 = rep_top - 1 */
    YADDRW a2, a0, t1
    EXPECT_TAG a2, 1
    bne  a2, t1, fail
    EXPECT_BOUNDS a2, s1, REP_E0_LEN
    EXPECT_NO_TRAP

    NEXT_TEST "yaddrw at E=0 rep_top clears the tag and shifts decoded base"
    addi t1, t1, 1               /* t1 = rep_top */
    YADDRW a2, a0, t1
    EXPECT_TAG a2, 0
    bne  a2, t1, fail
    li   t0, REP_E0_SPAN
    add  t2, s1, t0              /* decoded base shifts up by 2^(E+MW) */
    EXPECT_BOUNDS a2, t2, REP_E0_LEN
    EXPECT_NO_TRAP

    /* E = 0 lower and upper boundaries via YADD and YADDI. */
    NEXT_TEST "yadd and yaddi at E=0 rep_base and rep_base - 1"
    li   t0, -REP_E0_BELOW
    YADD a2, a0, t0              /* lands at rep_base */
    EXPECT_TAG a2, 1
    EXPECT_BOUNDS a2, s1, REP_E0_LEN
    YADDI a3, a2, 1              /* rep_base + 1 stays tagged */
    EXPECT_TAG a3, 1
    YADDI a3, a2, -1             /* rep_base - 1 detags */
    EXPECT_TAG a3, 0
    li   t0, -(REP_E0_BELOW + 1)
    YADD a3, a0, t0              /* direct YADD to rep_base - 1 detags */
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP

    NEXT_TEST "yadd and yaddi at E=0 rep_top - 1 and rep_top"
    li   t0, REP_E0_ABOVE - 1
    YADD a2, a0, t0              /* lands at rep_top - 1 */
    EXPECT_TAG a2, 1
    EXPECT_BOUNDS a2, s1, REP_E0_LEN
    YADDI a3, a2, -1             /* rep_top - 2 stays tagged */
    EXPECT_TAG a3, 1
    YADDI a3, a2, 1              /* rep_top detags */
    EXPECT_TAG a3, 0
    li   t0, REP_E0_ABOVE
    YADD a3, a0, t0              /* direct YADD to rep_top detags */
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP

    /* E = 1 (internal exponent) lower and upper boundaries via YADDRW, YADD, and YADDI. */
    NEXT_TEST "yaddrw, yadd, and yaddi at E=1 rep_base and rep_base - 1"
    li   t0, -REP_E1_BELOW
    YADD a2, a1, t0              /* lands at E=1 rep_base */
    EXPECT_TAG a2, 1
    EXPECT_BOUNDS a2, s1, REP_E1_LEN
    YADDI a3, a2, -1             /* E=1 rep_base - 1 detags */
    EXPECT_TAG a3, 0
    li   t0, REP_E1_SPAN
    sub  t2, s1, t0
    EXPECT_BOUNDS a3, t2, REP_E1_LEN
    li   t0, REP_E1_BELOW + 1
    sub  t1, s1, t0              /* t1 = E=1 rep_base - 1 */
    YADDRW a3, a1, t1
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP

    NEXT_TEST "yaddrw, yadd, and yaddi at E=1 rep_top - 1 and rep_top"
    li   t0, REP_E1_ABOVE - 1
    YADD a2, a1, t0              /* lands at E=1 rep_top - 1 */
    EXPECT_TAG a2, 1
    EXPECT_BOUNDS a2, s1, REP_E1_LEN
    YADDI a3, a2, 1              /* E=1 rep_top detags */
    EXPECT_TAG a3, 0
    li   t0, REP_E1_SPAN
    add  t2, s1, t0
    EXPECT_BOUNDS a3, t2, REP_E1_LEN
    li   t0, REP_E1_ABOVE
    add  t1, s1, t0              /* t1 = E=1 rep_top */
    YADDRW a3, a1, t1
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP

#ifndef CHERI_093
    /* Shifted-add instructions across the representable boundaries on RVY. */
    NEXT_TEST "ysh1add, ysh2add, and ysh3add detag when crossing representable limits"
    li   t0, -(REP_E0_BELOW / 2)
    YSH1ADD a2, t0, a0           /* lands at rep_base */
    EXPECT_TAG a2, 1
    addi t0, t0, -1
    YSH1ADD a2, t0, a0           /* lands at rep_base - 2 -> detags */
    EXPECT_TAG a2, 0
    li   t0, (REP_E0_ABOVE / 4) - 1
    YSH2ADD a2, t0, a0           /* lands at rep_top - 4 */
    EXPECT_TAG a2, 1
    addi t0, t0, 1
    YSH2ADD a2, t0, a0           /* lands at rep_top -> detags */
    EXPECT_TAG a2, 0
    li   t0, (REP_E0_ABOVE / 8) - 1
    YSH3ADD a2, t0, a0           /* lands at rep_top - 8 */
    EXPECT_TAG a2, 1
    addi t0, t0, 1
    YSH3ADD a2, t0, a0           /* lands at rep_top -> detags */
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP

#if __riscv_xlen == 64
    NEXT_TEST "ysh4add and unsigned-word shifted adds detag when crossing representable limits"
    li   t0, (REP_E0_ABOVE / 16) - 1
    YSH4ADD a2, t0, a0           /* lands at rep_top - 16 */
    EXPECT_TAG a2, 1
    addi t0, t0, 1
    YSH4ADD a2, t0, a0           /* lands at rep_top -> detags */
    EXPECT_TAG a2, 0
    li   t0, -0x100000000 + (REP_E0_ABOVE / 2)
    YSH1ADD_UW a2, t0, a0        /* lands at rep_top -> detags */
    EXPECT_TAG a2, 0
    addi t0, t0, -1
    YSH1ADD_UW a2, t0, a0        /* lands at rep_top - 2 -> keeps tag */
    EXPECT_TAG a2, 1
    EXPECT_NO_TRAP
#endif
#endif /* !CHERI_093 */

    /*
     * Sealed sentry cursor updates: YMV preserves the tag, while YADDRW,
     * YADD, YADDI (even with imm == 0), and YSH1ADD clear the tag.
     */
    NEXT_TEST "cursor updates on a sealed sentry clear the tag while ymv preserves it"
    YSENTRY a2, a0
    YMV  a3, a2
    EXPECT_TAG a3, 1
    YADDRW a3, a2, s1            /* same address, still detags */
    EXPECT_TAG a3, 0
    li   t0, 4
    YADD a3, a2, t0
    EXPECT_TAG a3, 0
    YADDI a3, a2, 0              /* imm == 0 still goes through cursor update and detags */
    EXPECT_TAG a3, 0
    YADDI a3, a2, 4
    EXPECT_TAG a3, 0
#ifndef CHERI_093
    YSH1ADD a3, x0, a2
    EXPECT_TAG a3, 0
#endif
    EXPECT_NO_TRAP

    /*
     * Capability-mode AUIPC from a bounded PCC: offset 0 stays in bounds and
     * keeps the tag, whereas +0x10000 and -0x10000 exceed [rep_base, rep_top)
     * and clear the tag on the destination register without faulting.
     */
    NEXT_TEST "capability-mode auipc from bounded pcc detags outside representable range"
    auipc a2, 0
    la    t0, bounded_auipc_fn
    YADDRW a2, a2, t0
    li    t1, 64
    YBNDSW a2, a2, t1
    jalr  a3, a2, 0
    EXPECT_TAG a4, 1             /* auipc 0 inside [rep_base, rep_top) */
    EXPECT_TAG a5, 0             /* auipc +0x10000 >= rep_top */
    EXPECT_TAG a6, 0             /* auipc -0x10000 < rep_base */
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

.balign 64
bounded_auipc_fn:
    auipc a4, 0
    auipc a5, 0x10               /* pc + 0x10000 */
    auipc a6, 0xffff0            /* pc - 0x10000 */
    jalr  x0, a3, 0

TRAP_HANDLER

.section .bss
.balign 65536
buf:
    .space 65536
buf_mid:
    .space 65536

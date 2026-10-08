/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Happy-path tests for the capability manipulation and inspection
 * instructions (negative, malformed-metadata, and reserved-encoding cases
 * live in test-cap-ops-failures.S):
 *
 *  - YBNDSWI encodes lengths across four regions (page-sized, byte granular,
 *    8-byte granular, and 16-byte granular).
 *  - YBNDSRW rounds inexact lengths up to a representable superset while
 *    keeping the tag, including lengths that overflow the internal-exponent
 *    mantissa and increment E.
 *  - YBASER, YLENR, and (on RVY) YTOPR report the decoded bounds, clamping
 *    2^XLEN to ~0.
 *  - YADD and (on RVY) the YSH1ADD through YSH4ADD and YSH1ADD.UW through
 *    YSH4ADD.UW instructions increment capability cursors by register or
 *    shifted-register offsets.
 *  - YEQ compares full capability state (tag, cursor, and metadata).
 *  - SRLIY by XLEN reads the capability metadata half.
 *  - YSENTRY, YSUNSEAL, YBLD, YSS, and YTYPER seal, unseal, rebuild, compare
 *    subsets, and inspect capability types.
 *  - YPERMC / ACPERM restricts permissions, and clearing PERM_X on an
 *    integer-mode capability forces its execution mode to capability mode.
 */
#define TEST_NAME "cap-ops"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define XLEN 64
#define XBYTES 8
#define LX ld
#define SX sd
#define PESBT_RESERVED0_BIT (1 << 28)
#else
#define XLEN 32
#define XBYTES 4
#define LX lw
#define SX sw
#define PESBT_RESERVED0_BIT (1 << 21)
#endif

.macro EXPECT_TAG reg, tag
    YTAGR t3, \reg
    li   t4, \tag
    bne  t4, t3, fail
.endm

.macro EXPECT_LEN reg, len
    YLENR t3, \reg
    li   t4, \len
    bne  t4, t3, fail
.endm

/* Bound a copy of the authorizing capability and check the decoded length. */
.macro EXPECT_YBNDSWI_LEN len
    NEXT_TEST "ybndswi encodes a length of \len exactly"
    YMV  a2, a0
    YBNDSWI a2, a2, \len
    EXPECT_TAG a2, 1             /* the length must be exactly encodable */
    EXPECT_LEN a2, \len
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /*
     * ddc is the only root data capability a bare-metal test has. Save it in
     * s0 and bound a copy in a0 to the (page-aligned) buffer so that every
     * length below is a valid subset.
     */
    csrrs s0, CSR_DDC, x0
    la    t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */

    YMODESWY                     /* capability mode */

#ifndef CHERI_093
    /*
     * YBNDSWI: one length from each region, plus both ends of each. 0.9.3
     * spells the same operation scbndsi but encodes the immediate as a scale
     * and a 5-bit value, so the regions below do not exist there.
     */
    EXPECT_YBNDSWI_LEN 4096      /* imm9 == 0 is the page-sized encoding */
    EXPECT_YBNDSWI_LEN 1         /* byte granular lower bound */
    EXPECT_YBNDSWI_LEN 7
    EXPECT_YBNDSWI_LEN 255       /* byte granular upper bound */
    EXPECT_YBNDSWI_LEN 256       /* 8-byte granular lower bound */
    EXPECT_YBNDSWI_LEN 264
    EXPECT_YBNDSWI_LEN 504       /* 8-byte granular upper bound */
    EXPECT_YBNDSWI_LEN 512       /* 16-byte granular lower bound */
    EXPECT_YBNDSWI_LEN 1024
#if __riscv_xlen == 64
    EXPECT_YBNDSWI_LEN 4080      /* 16-byte granular upper bound */
#endif
    EXPECT_NO_TRAP
#endif

    /*
     * YBNDSRW rounds an exact length without expanding it, and rounds an
     * inexact length up to a representable superset while keeping the tag.
     * Requesting 0xfff9 (just below 0x10000 with low bits set) also exercises
     * the internal-exponent mantissa overflow path (incE = true) in both
     * YBNDSRW and YAMASK.
     */
    NEXT_TEST "ybndsrw preserves exact bounds"
    li   t2, 64
    YBNDSRW a2, a0, t2
    EXPECT_TAG a2, 1
    EXPECT_LEN a2, 64
    YBASER t3, a2
    la   t4, buf
    bne  t4, t3, fail
    EXPECT_NO_TRAP

    NEXT_TEST "ybndsrw rounds inexact bounds outward and keeps the tag"
    la   t1, buf
    addi t1, t1, 1
    YADDRW a2, s0, t1
    li   t2, 0xfff9
    YBNDSRW a2, a2, t2
    EXPECT_TAG a2, 1
    YBASER t3, a2
    bgtu t3, t1, fail            /* rounded base <= requested base */
    YLENR t4, a2
    bltu t4, t2, fail            /* rounded length >= requested length */
    YAMASK t3, t2
    beqz t3, fail
    EXPECT_NO_TRAP

    /* YBASER, YLENR, and (on RVY) YTOPR report bounds and clamp 2^XLEN to ~0. */
    NEXT_TEST "ybaser, ylenr, and ytopr report bounded and root bounds"
    YBASER t1, s0
    bnez t1, fail
    YLENR t1, s0
    li   t2, -1
    bne  t2, t1, fail
#ifndef CHERI_093
    YTOPR t1, s0
    bne  t2, t1, fail
    YTOPR t1, x0
    bne  t2, t1, fail
    YTOPR t1, a0
    la   t2, buf + 4096
    bne  t2, t1, fail
#endif
    EXPECT_NO_TRAP

    /* YADD increments the cursor by rs2 and preserves the tag in bounds. */
    NEXT_TEST "yadd increments the cursor by a register offset"
    li   t1, 24
    YADD a2, a0, t1
    EXPECT_TAG a2, 1
    la   t2, buf
    addi t2, t2, 24
    bne  a2, t2, fail
    li   t1, -8
    YADD a2, a2, t1
    EXPECT_TAG a2, 1
    addi t2, t2, -8
    bne  a2, t2, fail
    YADD a3, x0, t2              /* cs1 = x0 produces an untagged capability at rs2 */
    EXPECT_TAG a3, 0
    bne  a3, t2, fail
    EXPECT_NO_TRAP

#ifndef CHERI_093
    /* YSH1ADD through YSH3ADD (and YSH4ADD / .UW on RV64) shift rs1 and add to cs2. */
    NEXT_TEST "ysh1add, ysh2add, and ysh3add shift rs1 before adding to cs2"
    li   t1, 5
    YSH1ADD a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 10
    bne  a2, t2, fail
    YSH2ADD a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 20
    bne  a2, t2, fail
    YSH3ADD a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 40
    bne  a2, t2, fail
    YSH1ADD x0, t1, a0           /* cd = x0 discards the result */
    EXPECT_NO_TRAP

#if __riscv_xlen == 64
    NEXT_TEST "ysh4add and unsigned-word shifted adds zero-extend 32-bit offsets on RV64"
    li   t1, 5
    YSH4ADD a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 80
    bne  a2, t2, fail
    /* Set bits [63:32] all-ones and low 32 bits = 6 so .uw strips the upper half. */
    li   t1, -0x100000000 + 6
    YSH1ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 12
    bne  a2, t2, fail
    YSH2ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 24
    bne  a2, t2, fail
    YSH3ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 48
    bne  a2, t2, fail
    YSH4ADD_UW a2, t1, a0
    EXPECT_TAG a2, 1
    la   t2, buf + 96
    bne  a2, t2, fail
    EXPECT_NO_TRAP
#endif
#endif /* !CHERI_093 */

    /* YEQ tests exact equality across tag, cursor, and metadata. */
    NEXT_TEST "yeq compares tag, cursor, bounds, permissions, and seal state"
    YMV  a2, a0
    YEQ  t1, a0, a2
    beqz t1, fail
    YEQ  t1, x0, x0
    beqz t1, fail
    YADDI a2, a0, 4
    YEQ  t1, a0, a2              /* different cursor */
    bnez t1, fail
    li   t2, 2048
    YBNDSW a2, a0, t2
    YEQ  t1, a0, a2              /* different bounds */
    bnez t1, fail
    li   t2, DROP_MASK(PERM_W)
    DROP_PERMS a2, a0, t2
    YEQ  t1, a0, a2              /* different permissions */
    bnez t1, fail
    YSENTRY a2, a0
    YEQ  t1, a0, a2              /* different otype */
    bnez t1, fail
    la   t2, buf
    YADDRW a2, x0, t2            /* untagged with same address */
    YEQ  t1, a0, a2              /* different tag */
    bnez t1, fail
    EXPECT_NO_TRAP

#ifndef CHERI_093
    /* SRLIY by XLEN reads the metadata, which 0.9.3 has no encoding for */
    NEXT_TEST "srliy by XLEN reads the capability metadata"
    SRLIY t1, a0, XLEN
    beqz t1, fail
    EXPECT_NO_TRAP
#endif

    /* a1 is a subset of a0, which the tag reconstruction below builds on. */
    NEXT_TEST "a bounded subset of the authorizing capability keeps its tag"
    YMV  a1, a0
    li   t2, 16
    YBNDSW a1, a1, t2            /* a1 = [buf, buf + 16), a subset of a0 */
    EXPECT_TAG a1, 1

#ifndef CHERI_093
    /*
     * YSUNSEAL, which 0.9.3 does not have: sealing a1 as a sentry and then
     * unsealing it under a0 is allowed, and the result comes back unsealed
     * and tagged. cs1 = x0 copies, untags, and unseals.
     */
    NEXT_TEST "ysunseal of a sentry under a superset returns it unsealed"
    YSENTRY a2, a1               /* a2 = a1 sealed as a sentry */
    EXPECT_TAG a2, 1
    YTYPER t3, a2
    beqz t3, fail                /* it really is sealed */
    YSUNSEAL a3, a0, a2
    EXPECT_TAG a3, 1
    YTYPER t3, a3
    bnez t3, fail                /* comes back unsealed */
    EXPECT_NO_TRAP

    NEXT_TEST "ysunseal with cs1=x0 copies untags and unseals"
    YSUNSEAL a3, x0, a2
    EXPECT_TAG a3, 0
    YTYPER t3, a3
    bnez t3, fail
    EXPECT_NO_TRAP
#endif /* !CHERI_093 */

    /* YBLD restores a tag from an authorizing capability, and YSS confirms subset. */
    NEXT_TEST "ybld restores a tag from an authorizing capability and yss confirms subset"
    YMV  a3, a1
    li   t2, 8
    YBNDSW a3, a3, t2            /* a3 = [buf, buf + 8), a subset of a0 */
    SY   a3, 0(a0)
    LX   t1, 0(a0)
    SX   t1, 0(a0)               /* clear tag in memory */
    LY   a3, 0(a0)
    EXPECT_TAG a3, 0             /* YBLD does not need a tagged input */
    YBLD a4, a0, a3
    EXPECT_TAG a4, 1
    EXPECT_LEN a4, 8
    YSS  t3, a0, a4              /* a4 is a tagged subset of a0 */
    beqz t3, fail
    YSENTRY a2, a4
    YSS  t3, a0, a2              /* YSS ignores otype when bounds and perms are a subset */
    beqz t3, fail
    YSS  t3, a3, a3              /* untagged capability is a subset of itself */
    beqz t3, fail
    YSS  t3, x0, x0
    beqz t3, fail
    EXPECT_NO_TRAP

    /*
     * YTYPER returns 0 for unsealed capabilities (including c0) and 1 for
     * sentries, even if the sentry is untagged and has corrupted reserved
     * metadata bits.
     */
    NEXT_TEST "ytyper returns 0 for unsealed capabilities and 1 for sentries"
    YTYPER t3, x0
    bnez t3, fail
    YTYPER t3, a0
    bnez t3, fail
    YSENTRY a2, a1
    YTYPER t3, a2
    li   t4, 1
    bne  t4, t3, fail
    SY   a2, 0(a0)
    LX   t1, XBYTES(a0)
    li   t2, PESBT_RESERVED0_BIT
    or   t1, t1, t2
    SX   t1, XBYTES(a0)
    LY   a3, 0(a0)
    EXPECT_TAG a3, 0
    YTYPER t3, a3
    li   t4, 1
    bne  t4, t3, fail
    EXPECT_NO_TRAP

    /*
     * Dropping PERM_X on an executable capability whose mode bit is
     * CHERI_MODE_INT (1) forces the mode bit to CHERI_MODE_CAP (0), because
     * non-executable capabilities cannot encode integer execution mode.
     */
    NEXT_TEST "dropping PERM_X on an integer-mode capability forces capability mode"
    auipc a2, 0
    li   t1, CHERI_MODE_INT
    YMODEW a2, a2, t1
    EXPECT_TAG a2, 1
    YMODER t3, a2
    bne  t3, t1, fail
    li   t2, DROP_MASK(PERM_X)
    DROP_PERMS a2, a2, t2
    EXPECT_TAG a2, 1
    YMODER t3, a2
    bnez t3, fail                /* forced back to CHERI_MODE_CAP (0) */
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
buf:
    .space 8192

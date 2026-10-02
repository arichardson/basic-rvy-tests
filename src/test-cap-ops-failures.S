/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Negative, malformed-metadata, and reserved-encoding tests for the capability
 * manipulation and inspection instructions (happy-path cases live in
 * test-cap-ops.S):
 *
 *  - YBNDSW (and YBNDSWI 4080 on RV32) clears the tag when the requested
 *    bounds cannot be encoded exactly, and both YBNDSW and YBNDSRW clear the
 *    tag when the requested bounds exceed the parent capability or the input
 *    capability is sealed.
 *  - YTOPR returns 0 on capabilities with malformed EBT bounds (matching
 *    YBASER and YLENR).
 *  - SRLIY with any shift amount other than XLEN is a reserved encoding, as
 *    are YSH4ADD and the unsigned-word shifted-add instructions on RV32.
 *  - YSUNSEAL, YBLD, and YSS reject untagged, sealed, malformed, or
 *    non-superset operands.
 *  - YMODEW and YPERMC / ACPERM clear the tag on sealed inputs, and YMODEW
 *    leaves the mode bit unmodified when PERM_X is absent.
 *  - YPERMR, YBLD, and YSS enforce metadata integrity on non-zero RESERVED0/1
 *    bits and (on RV32) reserved AP Quadrant 0 encodings.
 */
#define TEST_NAME "cap-ops-failures"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define XLEN 64
#define XBYTES 8
#define LX ld
#define SX sd
#define PESBT_RESERVED0_BIT    (1 << 28)
#define EBT_MALFORMED_E_GT_MAX 0x000000000001c007
#else
#define XLEN 32
#define XBYTES 4
#define LX lw
#define SX sw
#define PESBT_RESERVED0_BIT    (1 << 21)
#define EBT_MALFORMED_E_GT_MAX 0x00040c03
#endif

.macro EXPECT_TAG reg, tag
    YTAGR t3, \reg
    li   t4, \tag
    bne  t4, t3, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs s0, CSR_DDC, x0
    la    t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */
    li    t2, 16
    YBNDSW a1, a0, t2            /* a1 = [buf, buf + 16), a subset of a0 */

    YMODESWY                     /* capability mode */

#if !defined(CHERI_093) && __riscv_xlen == 32
    /*
     * The 64-bit capability format used on RV32 has a smaller mantissa, so
     * the top of the 16-byte-granular region (4080) is not exactly
     * representable and YBNDSWI, being the exact form, clears the tag.
     */
    NEXT_TEST "ybndswi cannot represent 4080 in the RV32 format so it detags"
    YMV  a2, a0
    YBNDSWI a2, a2, 4080
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP
#endif

    /*
     * YBNDSW is exact: an unaligned base with a large length cannot be
     * encoded, so the result is untagged rather than rounded out.
     */
    NEXT_TEST "ybndsw is exact so bounds it cannot encode detag instead of rounding"
    la   t1, buf
    addi t1, t1, 1
    YADDRW a2, s0, t1
    li   t2, 0x100000
    YBNDSW a2, a2, t2
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP

    /* YBNDSW and YBNDSRW detag when the requested bounds exceed the parent or cs1 is sealed. */
    NEXT_TEST "ybndsw and ybndsrw detag when exceeding parent bounds or on a sentry"
    li   t2, 32
    YBNDSW a2, a1, t2            /* 32 > 16 */
    EXPECT_TAG a2, 0
    YBNDSRW a2, a1, t2
    EXPECT_TAG a2, 0
    YSENTRY a3, a1
    li   t2, 8
    YBNDSW a2, a3, t2
    EXPECT_TAG a2, 0
    YBNDSRW a2, a3, t2
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP

#ifndef CHERI_093
    /* YTOPR, YBASER, and YLENR all return 0 when EBT bounds are malformed. */
    NEXT_TEST "ytopr, ybaser, and ylenr return 0 on malformed bounds"
    li   t1, EBT_MALFORMED_E_GT_MAX
    PACKY a2, x0, t1
    YBASER t2, a2
    bnez t2, fail
    YLENR t2, a2
    bnez t2, fail
    YTOPR t2, a2
    bnez t2, fail
    EXPECT_NO_TRAP

    /* Any SRLIY shift amount other than XLEN is a reserved encoding. */
    NEXT_TEST "srliy by 8 is a reserved shift amount"
    SRLIY t1, a0, 8
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "srliy by XLEN-1 is a reserved shift amount"
    SRLIY t1, a0, XLEN - 1
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

#if __riscv_xlen == 32
    /* YSH4ADD and the .UW shifted-add forms are RV64-only. */
    NEXT_TEST "ysh4add and unsigned-word shifted adds are illegal on RV32"
    YSH4ADD a2, t1, a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH1ADD_UW a2, t1, a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH2ADD_UW a2, t1, a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH3ADD_UW a2, t1, a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YSH4ADD_UW a2, t1, a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

    /*
     * YSUNSEAL refusal cases: non-superset authority, unsealed input,
     * untagged input, untagged authority (non-x0), and sealed authority.
     */
    NEXT_TEST "ysunseal under an authority that is not a superset is refused"
    YSENTRY a2, a0
    YSUNSEAL a3, a1, a2          /* a0 is not a subset of a1 */
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP

    NEXT_TEST "ysunseal of something that was never sealed is refused"
    YSUNSEAL a3, a0, a1
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP

    NEXT_TEST "ysunseal of an untagged sentry or under an untagged or sealed authority is refused"
    YSENTRY a2, a1               /* tagged sentry subset of a0 */
    YSUNSEAL a4, x0, a1          /* a4 = untagged copy of a1 */
    YSENTRY a5, a4               /* a5 = untagged sentry */
    YSUNSEAL a3, a0, a5          /* untagged input */
    EXPECT_TAG a3, 0
    YSUNSEAL a4, x0, a0          /* a4 = untagged copy of a0 */
    YSUNSEAL a3, a4, a2          /* untagged authority */
    EXPECT_TAG a3, 0
    YSENTRY a4, a0               /* a4 = sealed copy of a0 */
    YSUNSEAL a3, a4, a2          /* sealed authority */
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP
#endif /* !CHERI_093 */

    /*
     * YBLD refusal cases: non-superset authority, untagged authority (x0 or
     * detagged capability), and sealed authority.
     */
    NEXT_TEST "ybld from an authority that is not a superset is refused"
    YBLD a4, a1, a0              /* a0 is not a subset of a1 */
    EXPECT_TAG a4, 0
    EXPECT_NO_TRAP

    NEXT_TEST "ybld from an untagged or sealed authority is refused"
    YBLD a4, x0, a1              /* x0 is untagged */
    EXPECT_TAG a4, 0
    SY   a0, 0(a0)
    LX   t1, 0(a0)
    SX   t1, 0(a0)               /* clear tag of stored a0 */
    LY   a2, 0(a0)
    EXPECT_TAG a2, 0
    YBLD a4, a2, a1              /* untagged authority */
    EXPECT_TAG a4, 0
    YSENTRY a2, a0
    YBLD a4, a2, a1              /* sealed authority */
    EXPECT_TAG a4, 0
    EXPECT_NO_TRAP

    /*
     * YSS refusal cases: mismatched tags, wider bounds, or extra permissions.
     */
    NEXT_TEST "yss returns 0 on mismatched tags, wider bounds, or extra permissions"
    SY   a1, 0(a0)
    LX   t1, 0(a0)
    SX   t1, 0(a0)               /* clear tag in memory */
    LY   a2, 0(a0)               /* a2 = untagged copy of a1 */
    YSS  t3, a0, a2              /* cs1 tagged, cs2 untagged */
    bnez t3, fail
    YSS  t3, a2, a1              /* cs1 untagged, cs2 tagged */
    bnez t3, fail
    YSS  t3, a1, a0              /* cs2 has wider bounds than cs1 */
    bnez t3, fail
    li   t2, DROP_MASK(PERM_W)
    DROP_PERMS a2, a0, t2        /* a2 lacks PERM_W, which a1 still has */
    YSS  t3, a2, a1
    bnez t3, fail
    EXPECT_NO_TRAP

    /*
     * YMODEW and DROP_PERMS (YPERMC / ACPERM) on a sealed sentry clear the
     * tag when modifying AP or mode state, and YMODEW on a non-executable
     * capability leaves the mode bit unmodified.
     */
    NEXT_TEST "ymodew and permission changes detag a sentry, and ymodew without PERM_X is a no-op"
    auipc a2, 0
    YSENTRY a3, a2
    li   t1, CHERI_MODE_INT
    YMODEW a4, a3, t1
    EXPECT_TAG a4, 0
    li   t2, DROP_MASK(PERM_R)
    DROP_PERMS a4, a3, t2
    EXPECT_TAG a4, 0
#ifndef CHERI_093
    /* RVY YPERMC on a sentry preserves the tag when AP and SDP are not changed. */
    YPERMC a4, a3, x0
    EXPECT_TAG a4, 1
#endif
    li   t2, DROP_MASK(PERM_X)
    DROP_PERMS a2, a1, t2        /* a2 lacks PERM_X */
    YMODEW a4, a2, t1
    EXPECT_TAG a4, 1
    YMODER t3, a4
    bnez t3, fail                /* mode stays CHERI_MODE_CAP (0) */
    EXPECT_NO_TRAP

    /*
     * Non-zero RESERVED0 metadata bits cause YBLD to detag and YSS to return
     * 0 in both versions, and cause YPERMR to zero all allocated AP and SDP
     * bits (matching YPERMR of x0) in v0.9.9 while 0.9.3 gcperm preserves AP
     * and SDP.
     */
    NEXT_TEST "non-zero reserved0 metadata fails ybld, yss, and v0.9.9 ypermr"
    SY   a1, 0(a0)
    LX   t1, XBYTES(a0)
    li   t2, PESBT_RESERVED0_BIT
    or   t1, t1, t2
    SX   t1, XBYTES(a0)
    LY   a3, 0(a0)
    YBLD a4, a0, a3
    EXPECT_TAG a4, 0
    YSS  t3, a3, a3
    bnez t3, fail
    YSS  t3, x0, a3              /* cs1 valid untagged, cs2 malformed untagged */
    bnez t3, fail
    YPERMR t3, a3
#ifdef CHERI_093
    YPERMR t4, a1
    bne  t4, t3, fail
    li   t2, 0xfc00
    and  t3, t3, t2
    bnez t3, fail
#else
    YPERMR t4, x0
    bne  t4, t3, fail
#endif
    EXPECT_NO_TRAP

#if __riscv_xlen == 64
    /*
     * On RV64, v0.9.9 moved the 4-bit SDP field from pesbt[56:53] (bits
     * 120:117) to pesbt[63:60] (bits 127:124), shifting RESERVED1 to
     * pesbt[59:53]. Setting both pesbt[63:60]=0xa and pesbt[56:53]=0x5 puts
     * non-zero bits into RESERVED1 in both versions: 0.9.3 gcperm still
     * reports SDP=0x5 and AP, whereas v0.9.9 ypermr zeroes both AP and SDP
     * (matching YPERMR of x0). Clearing pesbt[59:53] leaves a valid v0.9.9
     * capability with SDP=0xa that passes ybld and yss, while still
     * malformed (RESERVED1 != 0) in 0.9.3.
     */
    NEXT_TEST "rv64 sdp and reserved1 relocation between 0.9.3 and v0.9.9"
    SY   a1, 0(a0)
    LX   t1, XBYTES(a0)
    slli t1, t1, 11
    srli t1, t1, 11              /* clear pesbt[63:53] */
    li   t2, (0xa << 60) | (0x5 << 53)
    or   t2, t1, t2
    SX   t2, XBYTES(a0)
    LY   a3, 0(a0)
    YBLD a4, a0, a3
    EXPECT_TAG a4, 0
    YSS  t3, a3, a3
    bnez t3, fail
    YPERMR t3, a3
#ifdef CHERI_093
    srli t3, t3, 6
    andi t3, t3, 0xf
    li   t4, 0x5
    bne  t4, t3, fail
#else
    YPERMR t4, x0
    bne  t4, t3, fail
#endif
    li   t2, (0xa << 60)
    or   t2, t1, t2
    SX   t2, XBYTES(a0)
    LY   a3, 0(a0)
    YBLD a4, a0, a3
#ifdef CHERI_093
    EXPECT_TAG a4, 0
    YSS  t3, a3, a3
    bnez t3, fail
    YPERMR t3, a3
    srli t3, t3, 6
    andi t3, t3, 0xf
    bnez t3, fail
#else
    EXPECT_TAG a4, 1
    YSS  t3, a3, a3
    beqz t3, fail
    YPERMR t3, a3
    srli t3, t3, 6
    andi t3, t3, 0xf
    li   t4, 0xa
    bne  t4, t3, fail
#endif
    EXPECT_NO_TRAP
#else /* __riscv_xlen == 32 */
    /*
     * On RV32, Quadrant 0 (Q=0) encodings with bit 1 set (such as
     * AP_M = 0b00010 at pesbt[29:25]) are reserved in both 0.9.3 and v0.9.9:
     * YBLD clears the tag, YSS returns 0, 0.9.3 gcperm zeroes AP while
     * preserving SDP (set to 0b10 at pesbt[31:30]), and v0.9.9 ypermr zeroes
     * both AP and SDP (matching YPERMR of x0).
     */
    NEXT_TEST "rv32 reserved ap quadrant 0 encoding is rejected"
    SY   a1, 0(a0)
    LX   t1, XBYTES(a0)
    slli t1, t1, 7
    srli t1, t1, 7               /* clear pesbt[31:25] (SDP and AP_M) */
    li   t2, (0x02 << 30) | (0x02 << 25)
    or   t1, t1, t2
    SX   t1, XBYTES(a0)
    LY   a3, 0(a0)
    YBLD a4, a0, a3
    EXPECT_TAG a4, 0
    YSS  t3, a3, a3
    bnez t3, fail
    YPERMR t3, a3
    YPERMR t4, x0
#ifdef CHERI_093
    ori  t4, t4, 0x0080          /* 2-bit SDP=0b10 preserved, all AP bits 0 */
#endif
    bne  t4, t3, fail
    EXPECT_NO_TRAP
#endif

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

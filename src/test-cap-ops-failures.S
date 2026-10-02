/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Negative, detagging, and metadata-integrity cases of the capability
 * manipulation and inspection instructions:
 *
 *  - YBNDSW and YBNDSWI are exact, so bounds they cannot encode exactly clear
 *    the tag rather than rounding outwards.
 *  - SRLIY is only defined for a shift of XLEN; any other shift is a reserved
 *    encoding.
 *  - YSUNSEAL and YBLD clear the tag when the authorizing capability is not a
 *    superset or when YSUNSEAL's source capability is unsealed.
 *  - YBLD, YSS, and YPERMR check metadata integrity (non-zero RESERVED0/1
 *    bits, the RV64 SDP relocation to bits 127:124 in v0.9.9, and the RV32
 *    reserved AP Quadrant 0 encoding Q=0, M=1, Q0=0). In v0.9.9, YPERMR sets
 *    bits 15:10 to 1 and zeroes both AP and SDP on any integrity failure; in
 *    0.9.3 (gcperm), bits 15:10 are 0 and SDP is preserved.
 */
#define TEST_NAME "cap-ops-failures"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define PESBT_RESERVED0_BIT (1 << 28)
#else
#define PESBT_RESERVED0_BIT (1 << 21)
#endif

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs t0, CSR_DDC, x0
    la    t1, buf
    YADDRW a0, t0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */

    YMODESWY                     /* capability mode */

#if !defined(CHERI_093) && __riscv_xlen == 32
    /*
     * The 64-bit capability format used on RV32 has a smaller mantissa, so
     * the top of the 16-byte-granular region is not exactly representable
     * and YBNDSWI, being the exact form, clears the tag instead. The
     * immediate still decodes to 4080; it is the bounds that cannot be
     * encoded.
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
    YADDRW a2, a0, t1
    li   t2, 0x100000
    YBNDSW a2, a2, t2
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP               /* it clears the tag rather than trapping */

#ifndef CHERI_093
    /* Any shift amount other than XLEN is a reserved encoding */
    NEXT_TEST "srliy by 8 is a reserved shift amount"
    SRLIY t1, a0, 8
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "srliy by XLEN-1 is a reserved shift amount"
    SRLIY t1, a0, XLEN - 1
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
#endif

    YMV  a1, a0
    li   t2, 16
    YBNDSW a1, a1, t2            /* a1 = [buf, buf + 16), a subset of a0 */
    EXPECT_TAG a1, 1

#ifndef CHERI_093
    YSENTRY a2, a1               /* a2 = a1 sealed as a sentry */

    /* Unsealing under an authority that is not a superset is refused */
    NEXT_TEST "ysunseal under an authority that is not a superset is refused"
    YSUNSEAL a3, a1, a0          /* a0 is not a subset of a1 */
    EXPECT_TAG a3, 0

    /* So is unsealing something that was not sealed to begin with */
    NEXT_TEST "ysunseal of something that was never sealed is refused"
    YSUNSEAL a3, a0, a1
    EXPECT_TAG a3, 0
    EXPECT_NO_TRAP
#endif /* !CHERI_093 */

    YMV  a3, a1
    li   t2, 8
    YBNDSW a3, a3, t2            /* a3 = [buf, buf + 8), a subset of a0 */

    /* Building from an authority that is not a superset is refused */
    NEXT_TEST "ybld from an authority that is not a superset is refused"
    YBLD a4, a3, a0              /* a0 is not a subset of a3 */
    EXPECT_TAG a4, 0
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
     * capability with SDP=0xa that passes ybld and yss, while staying
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

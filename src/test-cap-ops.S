/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Corner cases of the capability manipulation and inspection instructions:
 *
 *  - YBNDSWI's 9-bit immediate does not encode the length linearly. It has
 *    four regions (page-sized, byte granular, 8-byte granular and 16-byte
 *    granular), and the boundaries between them are the interesting part;
 *    each case below sets a length and reads it back with YLENR.
 *  - YBNDSW is the exact form, so bounds it cannot encode exactly clear the
 *    tag rather than rounding outwards.
 *  - SRLIY reads the capability metadata and is only defined for a shift of
 *    exactly XLEN; any other shift is a reserved encoding.
 *  - YSUNSEAL and YBLD both reconstruct a tag under an authorizing
 *    capability, and both have several ways to be refused.
 *  - YTYPER zero-extends the 1-bit CT field (0 unsealed, 1 sentry) regardless
 *    of tag or metadata integrity.
 *  - YBLD, YSS, and YPERMR check metadata integrity (non-zero RESERVED0/1
 *    bits, the RV64 SDP relocation to bits 127:124 in v0.9.9, and the RV32
 *    reserved AP Quadrant 0 encoding Q=0, M=1, Q0=0). In v0.9.9, YPERMR sets
 *    bits 15:10 to 1 and zeroes both AP and SDP on any integrity failure; in
 *    0.9.3 (gcperm), bits 15:10 are 0 and SDP is preserved.
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
     * ddc is the only root data capability a bare-metal test has. Bound a
     * copy to the (page-aligned) buffer so that every length below is
     * exactly representable.
     */
    csrrs t0, CSR_DDC, x0
    la    t1, buf
    YADDRW a0, t0, t1
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
    EXPECT_YBNDSWI_LEN 1         /* byte granular ... */
    EXPECT_YBNDSWI_LEN 7
    EXPECT_YBNDSWI_LEN 255       /* ... up to 255 */
    EXPECT_YBNDSWI_LEN 256       /* 8-byte granular ... */
    EXPECT_YBNDSWI_LEN 264
    EXPECT_YBNDSWI_LEN 504       /* ... up to 504 */
    EXPECT_YBNDSWI_LEN 512       /* 16-byte granular ... */
    EXPECT_YBNDSWI_LEN 1024
#if __riscv_xlen == 64
    EXPECT_YBNDSWI_LEN 4080      /* ... up to 4080 */
#else
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
#endif
    EXPECT_NO_TRAP               /* none of the above may fault */
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
    /* SRLIY by XLEN reads the metadata, which 0.9.3 has no encoding for */
    NEXT_TEST "srliy by XLEN reads the capability metadata"
    SRLIY t1, a0, XLEN
    beqz t1, fail
    EXPECT_NO_TRAP

    /* Any other shift amount is a reserved encoding */
    NEXT_TEST "srliy by 8 is a reserved shift amount"
    SRLIY t1, a0, 8
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "srliy by XLEN-1 is a reserved shift amount"
    SRLIY t1, a0, XLEN - 1
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
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
     * and tagged.
     */
    NEXT_TEST "ysunseal of a sentry under a superset returns it unsealed"
    YSENTRY a2, a1               /* a2 = a1 sealed as a sentry */
    EXPECT_TAG a2, 1
    YTYPER t3, a2
    beqz t3, fail                /* it really is sealed */
    YSUNSEAL a3, a0, a2
    EXPECT_TAG a3, 1
    YTYPER t3, a3
    bnez t3, fail                /* ... and comes back unsealed */
    EXPECT_NO_TRAP

    /* Unsealing under an authority that is not a superset is refused */
    NEXT_TEST "ysunseal under an authority that is not a superset is refused"
    YSUNSEAL a3, a1, a0          /* a0 is not a subset of a1 */
    EXPECT_TAG a3, 0

    /* So is unsealing something that was not sealed to begin with */
    NEXT_TEST "ysunseal of something that was never sealed is refused"
    YSUNSEAL a3, a0, a1
    EXPECT_TAG a3, 0

    /* cs1 = c0 is the documented "copy, untag and unseal" corner */
    NEXT_TEST "ysunseal with cs1=c0 copies untags and unseals"
    YSUNSEAL a3, x0, a2
    EXPECT_TAG a3, 0
    YTYPER t3, a3
    bnez t3, fail
    EXPECT_NO_TRAP

#endif /* !CHERI_093 */

    /* YBLD restores a tag from an authorizing capability. */
    NEXT_TEST "ybld restores a tag from an authorizing capability"
    YMV  a3, a1
    li   t2, 8
    YBNDSW a3, a3, t2            /* a3 = [buf, buf + 8), a subset of a0 */
#ifndef CHERI_093
    YSUNSEAL a3, x0, a3          /* ... with its tag cleared, as above */
    EXPECT_TAG a3, 0             /* YBLD does not need a tagged input */
#endif
    YBLD a4, a0, a3
    EXPECT_TAG a4, 1
    EXPECT_LEN a4, 8
    EXPECT_NO_TRAP

    /* Building from an authority that is not a superset is refused */
    NEXT_TEST "ybld from an authority that is not a superset is refused"
    YBLD a4, a3, a0              /* a0 is not a subset of a3 */
    EXPECT_TAG a4, 0
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
     * capability with SDP=0xa that passes ybld and yss, while remaining
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

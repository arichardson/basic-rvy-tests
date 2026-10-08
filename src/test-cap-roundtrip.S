/* SPDX-License-Identifier: BSD-2-Clause
 *
 * A capability loaded from memory and stored back must write out the bits it
 * read. Any untagged bit pattern is a value a program can hold and move
 * around, so this has to hold for arbitrary ones across the full XLEN width
 * of both halves (including malformed bounds and non-zero reserved bits), not
 * just for patterns that encode a valid capability.
 *
 * The patterns are written with integer stores and checked with integer
 * loads, so the test says nothing about how a capability is encoded and does
 * not depend on tagged memory:
 *  - direct LY -> SY in integer mode (via ddc) and capability mode;
 *  - LY followed by field inspection (YBASER, YLENR, YPERMR, YTYPER, YMODER)
 *    and YBLD with cs1=x0 before SY, so implementations that lazily
 *    decompress capabilities on inspection or re-encode them on YBLD still
 *    preserve every bit;
 *  - capability-mode CSR round-trip through mscratch;
 *  - atomic capability memory operations (AMOSWAP.Y and LR.Y/SC.Y);
 *  - YHIW -> SY and LY -> YHIR (or SRLIY by XLEN on v0.9.9) on RVY.
 */
#define TEST_NAME "cap-roundtrip"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define XLEN                    64
#define SX                      sd
#define LX                      ld
#define XBYTES                  8
#define PAT_ALT_55              0x5555555555555555
#define PAT_ALT_AA              0xaaaaaaaaaaaaaaaa
#define PAT_SIGN                0x8000000000000000
#define PAT_SEQ_LO              0x0123456789abcdef
#define PAT_SEQ_HI              0xfedcba9876543210
#define EBT_MALFORMED_E_MAX     0x0000000000000008
#define EBT_MALFORMED_E_MAX_M1  0x0000000000002001
#define EBT_MALFORMED_E_GT_MAX  0x000000000001c007
#define EBT_WRAP_TOP            0x0000000004003fff
#else
#define XLEN                    32
#define SX                      sw
#define LX                      lw
#define XBYTES                  4
#define PAT_ALT_55              0x55555555
#define PAT_ALT_AA              0xaaaaaaaa
#define PAT_SIGN                0x80000000
#define PAT_SEQ_LO              0x12345678
#define PAT_SEQ_HI              0x9abcdef0
#define EBT_MALFORMED_E_MAX     0x00000004
#define EBT_MALFORMED_E_MAX_M1  0x00000201
#define EBT_MALFORMED_E_GT_MAX  0x00040c03
#define EBT_WRAP_TOP            0x000803ff
#endif

/*
 * Put \lo (the address half) and \hi (the metadata half) in memory, load the
 * capability they spell, store it back and require the same bits out. Also
 * inspect the loaded capability and copy it through YBLD with cs1=x0 so that
 * lazy capability representations are forced to decompress and re-encode it.
 */
.macro EXPECT_BITS_ROUNDTRIP desc, lo, hi
    NEXT_TEST "\desc (ly -> sy)"
    li   t0, \lo
    li   t1, \hi
    SX   t0, 0(a0)
    SX   t1, XBYTES(a0)
    SX   x0, 0(a2)
    SX   x0, XBYTES(a2)
    LY   a1, 0(a0)
    SY   a1, 0(a2)
    EXPECT_NO_TRAP
    LX   t2, 0(a2)
    bne  t2, t0, fail
    LX   t3, XBYTES(a2)
    bne  t3, t1, fail

    NEXT_TEST "\desc (decompressed via inspection and ybld)"
    SX   x0, 0(a2)
    SX   x0, XBYTES(a2)
    LY   a1, 0(a0)
    YBASER t4, a1
    YLENR  t4, a1
    YPERMR t4, a1
    YTYPER t4, a1
    YMODER t4, a1
    YBLD   a3, x0, a1
    YTAGR  t4, a3
    bnez   t4, fail
    SY     a3, 0(a2)
    EXPECT_NO_TRAP
    LX   t2, 0(a2)
    bne  t2, t0, fail
    LX   t3, XBYTES(a2)
    bne  t3, t1, fail
.endm

/*
 * Capability-mode round-trip through LY/SY and through mscratch (which holds
 * a full capability without address legalization).
 */
.macro EXPECT_CAPMODE_ROUNDTRIP desc, lo, hi
    NEXT_TEST "\desc (capability-mode ly -> sy and mscratch)"
    li   t0, \lo
    li   t1, \hi
    SX   t0, 0(a0)
    SX   t1, XBYTES(a0)
    SX   x0, 0(a2)
    SX   x0, XBYTES(a2)
    LY   a1, 0(a0)
    csrrw x0, CSR_MSCRATCH, a1
    li   a1, 0
    csrrs a3, CSR_MSCRATCH, x0
    SY   a3, 0(a2)
    EXPECT_NO_TRAP
    LX   t2, 0(a2)
    bne  t2, t0, fail
    LX   t3, XBYTES(a2)
    bne  t3, t1, fail
.endm

#ifndef CHERI_093
/*
 * RVY YHIW assembles an untagged capability from two integer registers and
 * YHIR (or SRLIY by XLEN on v0.9.9) extracts the metadata half back to an
 * integer register.
 */
.macro EXPECT_YHIW_YHIR_ROUNDTRIP desc, lo, hi
    NEXT_TEST "\desc (yhiw -> sy and yhir)"
    li   t0, \lo
    li   t1, \hi
    SX   x0, 0(a2)
    SX   x0, XBYTES(a2)
    YHIW   a1, t0, t1
    YBASER t4, a1                /* force decompression before YHIR/SY */
    YHIR   t3, a1
    bne    t3, t1, fail
    SY     a1, 0(a2)
    EXPECT_NO_TRAP
    LX   t2, 0(a2)
    bne  t2, t0, fail
    LX   t3, XBYTES(a2)
    bne  t3, t1, fail
.endm
#endif

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    la   a0, src
    la   a2, dst

    /* Integer-mode round-trips across all bit positions and EBT corners. */
    EXPECT_BITS_ROUNDTRIP "all-zero bits round-trip", 0, 0
    EXPECT_BITS_ROUNDTRIP "all-one bits round-trip", -1, -1
    EXPECT_BITS_ROUNDTRIP "0x55 alternating bits round-trip", PAT_ALT_55, PAT_ALT_55
    EXPECT_BITS_ROUNDTRIP "0xaa alternating bits round-trip", PAT_ALT_AA, PAT_ALT_AA
    EXPECT_BITS_ROUNDTRIP "crossed alternating bits (0x55/0xaa) round-trip", PAT_ALT_55, PAT_ALT_AA
    EXPECT_BITS_ROUNDTRIP "crossed alternating bits (0xaa/0x55) round-trip", PAT_ALT_AA, PAT_ALT_55
    EXPECT_BITS_ROUNDTRIP "MSB in address half round-trips", PAT_SIGN, 0
    EXPECT_BITS_ROUNDTRIP "MSB in metadata half round-trips", 0, PAT_SIGN
    EXPECT_BITS_ROUNDTRIP "distinct byte pattern round-trips", PAT_SEQ_LO, PAT_SEQ_HI
    EXPECT_BITS_ROUNDTRIP "malformed E=maxE with non-zero B round-trips", PAT_SEQ_LO, EBT_MALFORMED_E_MAX
    EXPECT_BITS_ROUNDTRIP "malformed E=maxE-1 with Bmsb=1 round-trips", PAT_SEQ_LO, EBT_MALFORMED_E_MAX_M1
    EXPECT_BITS_ROUNDTRIP "malformed E>maxE round-trips", PAT_SEQ_LO, EBT_MALFORMED_E_GT_MAX
    EXPECT_BITS_ROUNDTRIP "E=0 wrapping top/base bounds round-trip", 0, EBT_WRAP_TOP

    /* Derive capability pointers to src and dst for capability-mode tests. */
    csrrs t0, CSR_DDC, x0
    la    t1, src
    YADDRW a0, t0, t1
    li    t2, 32
    YBNDSW a0, a0, t2
    la    t1, dst
    YADDRW a2, t0, t1
    YBNDSW a2, a2, t2

    YMODESWY

    EXPECT_CAPMODE_ROUNDTRIP "all-one bits in capability mode", -1, -1
    EXPECT_CAPMODE_ROUNDTRIP "distinct byte pattern in capability mode", PAT_SEQ_LO, PAT_SEQ_HI
    EXPECT_CAPMODE_ROUNDTRIP "crossed alternating bits in capability mode", PAT_ALT_55, PAT_ALT_AA
    EXPECT_CAPMODE_ROUNDTRIP "malformed E>maxE in capability mode", PAT_SEQ_LO, EBT_MALFORMED_E_GT_MAX
    csrw CSR_MSCRATCH, x0

    /* AMOSWAP.Y preserves arbitrary untagged bit patterns in both directions. */
    NEXT_TEST "amoswap.y preserves arbitrary untagged bit patterns"
    li   t0, PAT_SEQ_LO
    li   t1, PAT_SEQ_HI
    SX   t0, 0(a0)
    SX   t1, XBYTES(a0)
    li   t2, PAT_ALT_55
    li   t3, PAT_ALT_AA
    SX   t2, 0(a2)
    SX   t3, XBYTES(a2)
    LY   a1, 0(a0)               /* a1 = (PAT_SEQ_LO, PAT_SEQ_HI) */
    AMOSWAP_Y a3, a2, a1         /* dst <- a1, a3 <- old dst */
    EXPECT_NO_TRAP
    LX   t4, 0(a2)
    bne  t4, t0, fail
    LX   t4, XBYTES(a2)
    bne  t4, t1, fail
    SY   a3, 0(a0)
    LX   t4, 0(a0)
    bne  t4, t2, fail
    LX   t4, XBYTES(a0)
    bne  t4, t3, fail

    /* LR.Y / SC.Y preserves arbitrary untagged bit patterns. */
    NEXT_TEST "lr.y and sc.y preserve arbitrary untagged bit patterns"
    li   t0, PAT_ALT_AA
    li   t1, PAT_ALT_55
    SX   t0, 0(a0)
    SX   t1, XBYTES(a0)
    LY   a1, 0(a0)               /* a1 = (PAT_ALT_AA, PAT_ALT_55) */
    LR_Y a3, a2                  /* a3 = (PAT_SEQ_LO, PAT_SEQ_HI) from dst */
    SC_Y t4, a2, a1              /* dst <- a1 */
    bnez t4, fail
    EXPECT_NO_TRAP
    LX   t4, 0(a2)
    bne  t4, t0, fail
    LX   t4, XBYTES(a2)
    bne  t4, t1, fail
    SY   a3, 0(a0)
    li   t2, PAT_SEQ_LO
    li   t3, PAT_SEQ_HI
    LX   t4, 0(a0)
    bne  t4, t2, fail
    LX   t4, XBYTES(a0)
    bne  t4, t3, fail

#ifndef CHERI_093
    EXPECT_YHIW_YHIR_ROUNDTRIP "all-zero bits", 0, 0
    EXPECT_YHIW_YHIR_ROUNDTRIP "all-one bits", -1, -1
    EXPECT_YHIW_YHIR_ROUNDTRIP "crossed alternating bits", PAT_ALT_55, PAT_ALT_AA
    EXPECT_YHIW_YHIR_ROUNDTRIP "distinct byte pattern", PAT_SEQ_LO, PAT_SEQ_HI
    EXPECT_YHIW_YHIR_ROUNDTRIP "malformed E>maxE bits", PAT_SEQ_LO, EBT_MALFORMED_E_GT_MAX
#endif

    YMODESWI

    TEST_PASS
fail:
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 16
src:
    .space 32
dst:
    .space 32

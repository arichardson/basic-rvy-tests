/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability bounds manipulation and inspection instructions:
 *
 *  - YAMASK returns an all-ones alignment mask for length 0 and a contiguous
 *    high-bit mask for inexact lengths.
 *  - YBNDSW sets exact bounds on a subset of the authorizing capability and
 *    preserves its tag.
 *  - YBNDSWI encodes lengths across four regions (page-sized, byte granular,
 *    8-byte granular, and 16-byte granular).
 *  - YBNDSRW rounds inexact lengths up to a representable superset while
 *    keeping the tag, including lengths that overflow the internal-exponent
 *    mantissa and increment E.
 *  - YBASER, YLENR, and (on RVY) YTOPR report the decoded bounds, clamping
 *    2^XLEN to ~0.
 */
#define TEST_NAME "bounds-ops"
#include "testmacros.h"
#include "exceptions.h"

.macro EXPECT_LEN reg, len
    YLENR t3, \reg
    li   t4, \len
    EXPECT_EQ t4, t3
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

    /* YAMASK of length 0 -> all-ones mask */
    NEXT_TEST "yamask of length 0 gives an all-ones mask"
    li   t0, 0
    YAMASK t1, t0
    li   t2, -1
    EXPECT_EQ t2, t1

    /* YAMASK of an inexactly representable length -> the mask is
     * still contiguous ones in the high bits, but not all-ones */
    NEXT_TEST "yamask of an inexact length rounds to contiguous high bits"
    li   t0, 0x10000001
    YAMASK t1, t0
    not  t2, t1
    EXPECT_NONZERO t2            /* must require some rounding */
    addi t3, t2, 1
    and  t3, t3, t2
    EXPECT_ZERO t3               /* ~mask + 1 must be a power of two */

    /*
     * ddc is the only root data capability a bare-metal test has. Save it in
     * s0 and bound a copy in a0 to the (page-aligned) buffer so that every
     * length below is a valid subset.
     */
    csrrs s0, CSR_DDC, x0
    lla    t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */

#ifndef CHERI_093
    /*
     * YBNDSWI, one length per representable region. The root
     * capability keeps its tag for exact bounds. 0.9.3 spells the same
     * operation scbndsi with a scale and a 5-bit immediate, so these regions
     * are specific to the v0.9.9 encoding.
     */
    NEXT_TEST "ybndswi encodes one length from each representable region"

.macro CHECK_YBNDSWI length
    YBNDSWI t1, s0, \length
    EXPECT_TAG t1, 1
    YLENR t2, t1
    li   t3, \length
    EXPECT_EQ t3, t2
.endm

    CHECK_YBNDSWI 4096           /* page-sized */
    CHECK_YBNDSWI 1              /* byte granular */
    CHECK_YBNDSWI 16
    CHECK_YBNDSWI 255
    CHECK_YBNDSWI 256            /* 8-byte granular */
    CHECK_YBNDSWI 504
    CHECK_YBNDSWI 512            /* 16-byte granular */
#if __riscv_xlen == 64
    CHECK_YBNDSWI 4080
#else
    /* 4080 is not exactly representable in the RV32 capability format, so
     * the exact bounds request must clear the tag */
    YBNDSWI t1, s0, 4080
    EXPECT_TAG t1, 0
#endif
#endif /* !CHERI_093 */

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
    EXPECT_NO_TRAP               /* none of the above may fault */
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
    lla   t4, buf
    EXPECT_EQ t4, t3
    EXPECT_NO_TRAP

    NEXT_TEST "ybndsrw rounds inexact bounds outward and keeps the tag"
    lla   t1, buf
    addi t1, t1, 1
    YADDRW a2, s0, t1
    li   t2, 0xfff9
    YBNDSRW a2, a2, t2
    EXPECT_TAG a2, 1
    YBASER t3, a2
    sltu t3, t1, t3              /* 1 if rounded base > requested base */
    EXPECT_ZERO t3
    YLENR t4, a2
    sltu t4, t4, t2              /* 1 if rounded length < requested length */
    EXPECT_ZERO t4
    YAMASK t3, t2
    EXPECT_NONZERO t3
    EXPECT_NO_TRAP

    /* YBASER, YLENR, and (on RVY) YTOPR report bounds and clamp 2^XLEN to ~0. */
    NEXT_TEST "ybaser, ylenr, and ytopr report bounded and root bounds"
    YBASER t1, s0
    EXPECT_ZERO t1
    YLENR t1, s0
    li   t2, -1
    EXPECT_EQ t2, t1
#ifndef CHERI_093
    YTOPR t1, s0
    EXPECT_EQ t2, t1
    YTOPR t1, x0
    EXPECT_EQ t2, t1
    YTOPR t1, a0
    lla   t2, buf + 4096
    EXPECT_EQ t2, t1
#endif
    EXPECT_NO_TRAP

    NEXT_TEST "a bounded subset of the authorizing capability keeps its tag"
    YMV  a1, a0
    li   t2, 16
    YBNDSW a1, a1, t2            /* a1 = [buf, buf + 16), a subset of a0 */
    EXPECT_TAG a1, 1

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
buf:
    .space 8192

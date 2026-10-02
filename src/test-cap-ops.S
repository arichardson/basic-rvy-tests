/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Happy-path capability manipulation and inspection instructions:
 *
 *  - YBNDSWI's 9-bit immediate does not encode the length linearly. It has
 *    four regions (page-sized, byte granular, 8-byte granular and 16-byte
 *    granular), and the boundaries between them are the interesting part;
 *    each case below sets a length and reads it back with YLENR.
 *  - SRLIY reads the capability metadata for a shift of XLEN.
 *  - YSUNSEAL and YBLD reconstruct a tag under an authorizing capability,
 *    and YSUNSEAL with cs1=x0 copies, untags, and unseals.
 *  - YTYPER zero-extends the 1-bit CT field (0 unsealed, 1 sentry) regardless
 *    of tag or metadata integrity.
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

    /* SRLIY by XLEN reads the capability metadata, which 0.9.3 has no encoding for */
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
    bnez t3, fail                /* and comes back unsealed */
    EXPECT_NO_TRAP

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
    YSUNSEAL a3, x0, a3          /* with its tag cleared, as above */
    EXPECT_TAG a3, 0             /* YBLD does not need a tagged input */
#endif
    YBLD a4, a0, a3
    EXPECT_TAG a4, 1
    EXPECT_LEN a4, 8
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

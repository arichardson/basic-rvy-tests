/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Corner cases of the capability manipulation instructions:
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
 */
#define TEST_NAME "cap-ops"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define XLEN 64
#else
#define XLEN 32
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
    NEXT_TEST
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

    /* YBNDSWI: one length from each region, plus both ends of each */
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
    NEXT_TEST
    YMV  a2, a0
    YBNDSWI a2, a2, 4080
    EXPECT_TAG a2, 0
#endif
    EXPECT_NO_TRAP               /* none of the above may fault */

    /*
     * YBNDSW is exact: an unaligned base with a large length cannot be
     * encoded, so the result is untagged rather than rounded out.
     */
    NEXT_TEST
    la   t1, buf
    addi t1, t1, 1
    YADDRW a2, a0, t1
    li   t2, 0x100000
    YBNDSW a2, a2, t2
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP               /* it clears the tag rather than trapping */

    /* SRLIY by XLEN reads the metadata, which is non-zero for a real cap */
    NEXT_TEST
    SRLIY t1, a0, XLEN
    beqz t1, fail
    EXPECT_NO_TRAP

    /* Any other shift amount is a reserved encoding */
    NEXT_TEST
    SRLIY t1, a0, 8
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST
    SRLIY t1, a0, XLEN - 1
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    /*
     * YSUNSEAL: a1 is a subset of a0, sealed as a sentry. Unsealing it under
     * a0 is allowed, and the result comes back unsealed and tagged.
     */
    NEXT_TEST
    YMV  a1, a0
    li   t2, 16
    YBNDSW a1, a1, t2            /* a1 = [buf, buf + 16), a subset of a0 */
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
    NEXT_TEST
    YSUNSEAL a3, a1, a0          /* a0 is not a subset of a1 */
    EXPECT_TAG a3, 0

    /* So is unsealing something that was not sealed to begin with */
    NEXT_TEST
    YSUNSEAL a3, a0, a1
    EXPECT_TAG a3, 0

    /* cs1 = c0 is the documented "copy, untag and unseal" corner */
    NEXT_TEST
    YSUNSEAL a3, x0, a2
    EXPECT_TAG a3, 0
    YTYPER t3, a3
    bnez t3, fail
    EXPECT_NO_TRAP

    /*
     * YBLD restores a tag from an authorizing capability, and unlike
     * YSUNSEAL does not need the input to be tagged to begin with.
     */
    NEXT_TEST
    YMV  a3, a1
    li   t2, 8
    YBNDSW a3, a3, t2            /* a3 = [buf, buf + 8), a subset of a0 */
    YSUNSEAL a3, x0, a3          /* ... with its tag cleared, as above */
    EXPECT_TAG a3, 0
    YBLD a4, a0, a3
    EXPECT_TAG a4, 1             /* YBLD does not need a tagged input */
    EXPECT_LEN a4, 8
    EXPECT_NO_TRAP

    /* Building from an authority that is not a superset is refused */
    NEXT_TEST
    YBLD a4, a3, a0              /* a0 is not a subset of a3 */
    EXPECT_TAG a4, 0
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

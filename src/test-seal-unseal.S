/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability sentry sealing, unsealing, and type inspection instructions:
 *
 *  - YSEALE seals an unsealed capability as a sentry (YTYPER == 1) and
 *    detags an already sealed capability.
 *  - YUNSEALS (which 0.9.3 does not have) unseals a sentry capability under an
 *    authorizing superset capability, and with cs1 = x0 copies, untags, and
 *    unseals.
 *  - YTYPER returns 0 for unsealed capabilities (including c0) and 1 for
 *    sentries, even when the sentry is untagged and has corrupted reserved
 *    metadata bits.
 */
#define TEST_NAME "seal-unseal"
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

    csrrs s0, CSR_DDC, x0
    lla   t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */
    li    t2, 16
    YBNDSW a1, a0, t2            /* a1 = [buf, buf + 16), a subset of a0 */

    /* YSEALE (the macro picks each version's encoding) */
    NEXT_TEST "yseale seals as a sentry and sealing again detags"
    YSEALE t1, s0
    EXPECT_TAG t1, 1
    YTYPER t2, t1                /* ytyper = 1 (sentry) */
    li   t3, 1
    EXPECT_EQ t3, t2
    /* sealing an already sealed capability clears the tag */
    YSEALE t4, t1
    EXPECT_TAG t4, 0

    YMODESWY

#ifndef CHERI_093
    /*
     * YUNSEALS, which 0.9.3 does not have: sealing a1 as a sentry and then
     * unsealing it under a0 is allowed, and the result comes back unsealed
     * and tagged. cs1 = x0 copies, untags, and unseals.
     */
    NEXT_TEST "yunseals of a sentry under a superset returns it unsealed"
    YSEALE a2, a1                /* a2 = a1 sealed as a sentry */
    EXPECT_TAG a2, 1
    YTYPER t3, a2
    EXPECT_NONZERO t3            /* it really is sealed */
    YUNSEALS a3, a0, a2
    EXPECT_TAG a3, 1
    YTYPER t3, a3
    EXPECT_ZERO t3               /* comes back unsealed */
    EXPECT_NO_TRAP

    NEXT_TEST "yunseals with cs1=x0 copies untags and unseals"
    YUNSEALS a3, x0, a2
    EXPECT_TAG a3, 0
    YTYPER t3, a3
    EXPECT_ZERO t3
    EXPECT_NO_TRAP
#endif /* !CHERI_093 */

    /*
     * YTYPER returns 0 for unsealed capabilities (including c0) and 1 for
     * sentries, even if the sentry is untagged and has corrupted reserved
     * metadata bits.
     */
    NEXT_TEST "ytyper returns 0 for unsealed capabilities and 1 for sentries"
    YTYPER t3, x0
    EXPECT_ZERO t3
    YTYPER t3, a0
    EXPECT_ZERO t3
    YSEALE a2, a1
    YTYPER t3, a2
    li   t4, 1
    EXPECT_EQ t4, t3
    SY   a2, 0(a0)
    LX   t1, XBYTES(a0)
    li   t2, PESBT_RESERVED0_BIT
    or   t1, t1, t2
    SX   t1, XBYTES(a0)
    LY   a3, 0(a0)
    EXPECT_TAG a3, 0
    YTYPER t3, a3
    li   t4, 1
    EXPECT_EQ t4, t3
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
buf:
    .space 4096

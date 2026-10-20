/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability-mode PERM_C tag filtering and PERM_LM permission filtering on
 * capability loads, stores, and atomics:
 *
 *  - Capabilities without PERM_C strip the tag on stored or loaded
 *    capabilities across SY, LY, LR.Y, SC.Y, and AMOSWAP.Y without trapping.
 *  - Capabilities with PERM_C but without PERM_LM strip PERM_W and PERM_LM
 *    from loaded unsealed capabilities across LY and LR.Y, while preserving
 *    PERM_W and PERM_LM on loaded sealed sentries.
 */
#define TEST_NAME "cap-loadstore-perms"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    lla   a0, buf
    csrrs s0, CSR_DDC, x0
    YADDRW a3, s0, a0            /* a3: full-permission capability at buf */
    li   t0, DROP_MASK(PERM_C)
    DROP_PERMS a5, a3, t0        /* a5: data-only capability (W=1, R=1, C=0) */
    li   t0, DROP_MASK(PERM_W | PERM_LM | PERM_X | PERM_ASR)
    DROP_PERMS s2, a3, t0        /* s2: capability-read without LM (R=1, C=1, W=0, LM=0) */
    YSEALE s1, a3                /* s1: sealed sentry capability at buf */

    YMODESWY

    /*
     * Capability-mode PERM_C tag filtering across SY, SC.Y, AMOSWAP.Y, LY,
     * and LR.Y through a data-only capability (a5: R=1, W=1, C=0).
     */
    NEXT_TEST "capability-mode sy through a capability without PERM_C strips the tag"
    SY   a3, 0(a5)
    EXPECT_NO_TRAP
    LY   t1, 0(a3)
    EXPECT_TAG t1, 0
    EXPECT_EQ a0, t1

    NEXT_TEST "capability-mode lr.y and sc.y without PERM_C strip loaded and stored tags"
    SY   a3, 0(a3)
    LR_Y t1, a5
    EXPECT_TAG t1, 0
    SC_Y t3, a5, a3
    EXPECT_NO_TRAP
    EXPECT_ZERO t3
    LY   t1, 0(a3)
    EXPECT_TAG t1, 0

    NEXT_TEST "capability-mode amoswap.y without PERM_C strips both loaded and stored tags"
    SY   a3, 0(a3)
    AMOSWAP_Y t1, a5, a3
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 0
    LY   t3, 0(a3)
    EXPECT_TAG t3, 0

    NEXT_TEST "capability-mode ly without PERM_C strips the loaded tag"
    SY   a3, 0(a3)
    LY   t1, 0(a5)
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 0
    EXPECT_EQ a0, t1

    /*
     * Capability-mode PERM_LM permission filtering on LY and LR.Y when
     * PERM_C is set and PERM_W | PERM_LM are cleared.
     */
    NEXT_TEST "capability-mode ly and lr.y without PERM_LM strip W and LM from an unsealed capability"
    SY   a3, 0(a3)
    LY   t1, 0(s2)
    LR_Y t2, s2
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 1
    YPERMR t3, t1
    andi t4, t3, (PERM_W | PERM_LM)
    EXPECT_ZERO t4
    EXPECT_TAG t2, 1
    YPERMR t3, t2
    andi t4, t3, (PERM_W | PERM_LM)
    EXPECT_ZERO t4

    NEXT_TEST "capability-mode ly and lr.y without PERM_LM preserve W and LM on a sealed sentry"
    SY   s1, 0(a3)
    LY   t1, 0(s2)
    LR_Y t2, s2
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 1
    YPERMR t3, t1
    andi t4, t3, (PERM_W | PERM_LM)
    li   t0, (PERM_W | PERM_LM)
    EXPECT_EQ t4, t0
    YPERMR t3, t2
    andi t4, t3, (PERM_W | PERM_LM)
    EXPECT_EQ t4, t0

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 64

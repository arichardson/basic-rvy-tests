/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Happy-path tests for capability comparison, metadata inspection, tag
 * reconstruction, and subset testing (bounds, cursor addition, sealing,
 * permission/mode manipulation, and negative/malformed-metadata cases live in
 * their own test files):
 *
 *  - YEQ compares full capability state (tag, cursor, and metadata).
 *  - YHIR reads the capability metadata half.
 *  - YBLD reconstructs a tagged capability from an untagged capability under
 *    an authorizing superset capability.
 *  - YSS tests whether cs2's bounds and permissions are a subset of cs1's.
 */
#define TEST_NAME "cap-ops"
#include "testmacros.h"
#include "exceptions.h"

.macro EXPECT_LEN reg, len
    YLENR t3, \reg
    li   t4, \len
    EXPECT_EQ t4, t3
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs s0, CSR_DDC, x0
    lla    t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */
    li    t2, 16
    YBNDSW a1, a0, t2            /* a1 = [buf, buf + 16), a subset of a0 */

    YMODESWY                     /* capability mode */

    /* YEQ tests exact equality across tag, cursor, and metadata. */
    NEXT_TEST "yeq compares tag, cursor, bounds, permissions, and seal state"
    YMV  a2, a0
    YEQ  t1, a0, a2
    EXPECT_NONZERO t1
    YEQ  t1, x0, x0
    EXPECT_NONZERO t1
    YADDI a2, a0, 4
    YEQ  t1, a0, a2              /* different cursor */
    EXPECT_ZERO t1
    li   t2, 2048
    YBNDSW a2, a0, t2
    YEQ  t1, a0, a2              /* different bounds */
    EXPECT_ZERO t1
    li   t2, DROP_MASK(PERM_W)
    DROP_PERMS a2, a0, t2
    YEQ  t1, a0, a2              /* different permissions */
    EXPECT_ZERO t1
    YSEALE a2, a0
    YEQ  t1, a0, a2              /* different otype */
    EXPECT_ZERO t1
    lla   t2, buf
    YADDRW a2, x0, t2            /* untagged with same address */
    YEQ  t1, a0, a2              /* different tag */
    EXPECT_ZERO t1
    EXPECT_NO_TRAP

    /* YHIR (SRLIY by XLEN on v0.9.9, gchi on 0.9.3) reads the capability metadata half. */
    NEXT_TEST "yhir reads the capability metadata"
    YHIR t1, a0
    EXPECT_NONZERO t1
    EXPECT_NO_TRAP

    /* YBLD restores a tag from an authorizing capability, and YSS confirms subset. */
    NEXT_TEST "ybld restores a tag from an authorizing superset capability"
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
    EXPECT_NO_TRAP

    NEXT_TEST "yss returns 1 when cs2 is a tagged subset of cs1"
    YSS  t3, a0, a4              /* a4 is a tagged subset of a0 */
    EXPECT_NONZERO t3
    EXPECT_NO_TRAP

    NEXT_TEST "yss ignores seal state when bounds and permissions are a subset"
    YSEALE a2, a4
    YSS  t3, a0, a2              /* YSS ignores otype when bounds and perms are a subset */
    EXPECT_NONZERO t3
    EXPECT_NO_TRAP

    NEXT_TEST "yss returns 1 when comparing an untagged capability to itself"
    YSS  t3, a3, a3              /* untagged capability is a subset of itself */
    EXPECT_NONZERO t3
    YSS  t3, x0, x0
    EXPECT_NONZERO t3
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
    .space 4096

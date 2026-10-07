/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability levels on loads and stores (golden Sail
 * src/cheri_cap_common.sail:545-606):
 *
 *  - A tagged capability loaded through an authority without EL is
 *    restricted to the authority's level (GL &= auth.GL), sealed or not.
 *    If it is also unsealed it loses EL. An authority without LM instead
 *    removes W and LM from an unsealed tagged capability.
 *  - A local capability (GL = 0) stored through an authority without SL is
 *    stored untagged; a global one is stored as it is.
 *
 * Everything here is done in capability mode with authorities derived from
 * ddc, which grants every permission and is global. Permissions and level
 * are read back with YPERMR (BitPerms, :408-422).
 */
#define TEST_NAME "cap-levels"
#ifdef CHERI_093
#error "RVY v0.9.9 only"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define PERM_LM   (1 << 1)
#define PERM_EL   (1 << 2)
#define PERM_SL   (1 << 3)
#define PERM_GL   (1 << 4)

#define root  s0                 /* ddc */
#define auth  a0                 /* [buf, buf + 64), every permission */
#define glob  a1                 /* a global capability to store */
#define loc   a2                 /* the same, local */

/* YPERMR of \reg has the bits in \mask set to \val, and \reg is tagged. */
.macro EXPECT_PERMS reg, mask, val
    YTAGR t3, \reg
    beqz t3, fail
    YPERMR t3, \reg
    li   t4, \mask
    and  t3, t3, t4
    li   t4, \val
    bne  t4, t3, fail
.endm

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
    csrrs root, CSR_DDC, x0
    la   t0, buf
    YMODESWY

    li   t1, 64
    YADDRW auth, root, t0
    YBNDSW auth, auth, t1
    addi t1, t0, 48
    YADDRW glob, root, t1
    li   t1, PERM_GL
    YPERMC loc, glob, t1

    NEXT_TEST "control: the stored capabilities are tagged, global and local"
    EXPECT_PERMS glob, PERM_GL|PERM_EL|PERM_LM|PERM_W, \
                       PERM_GL|PERM_EL|PERM_LM|PERM_W
    EXPECT_PERMS loc, PERM_GL, 0
    EXPECT_PERMS auth, PERM_GL|PERM_EL|PERM_SL|PERM_LM, \
                       PERM_GL|PERM_EL|PERM_SL|PERM_LM

    NEXT_TEST "control: a load through the full authority changes nothing"
    SY   glob, 0(auth)
    LY   a3, 0(auth)
    EXPECT_NO_TRAP
    YEQ  t3, a3, glob
    beqz t3, fail

    NEXT_TEST "a global authority without EL clears EL and keeps GL"
    li   t1, PERM_EL
    YPERMC a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_GL|PERM_EL|PERM_LM|PERM_W, PERM_GL|PERM_LM|PERM_W

    NEXT_TEST "a local authority without EL makes the loaded capability local"
    li   t1, PERM_EL|PERM_GL
    YPERMC a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_GL|PERM_EL, 0

    NEXT_TEST "control: a local authority with EL leaves the level alone"
    li   t1, PERM_GL
    YPERMC a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_GL|PERM_EL, PERM_GL|PERM_EL

    NEXT_TEST "an authority without LM clears W and LM from the loaded one"
    li   t1, PERM_LM
    YPERMC a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_GL|PERM_LM|PERM_W, PERM_GL

    NEXT_TEST "a sealed capability is made local without EL, but keeps EL"
    YSENTRY a5, glob
    SY   a5, 0(auth)
    li   t1, PERM_EL|PERM_GL
    YPERMC a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_GL|PERM_EL|PERM_LM|PERM_W, PERM_EL|PERM_LM|PERM_W

    li   t1, PERM_SL
    YPERMC a4, auth, t1          /* a4 = auth without SL */

    NEXT_TEST "a local capability stored without SL is stored untagged"
    SY   loc, 16(a4)
    EXPECT_NO_TRAP
    LY   a3, 16(auth)
    EXPECT_TAG a3, 0

    NEXT_TEST "control: a local capability stored with SL keeps its tag"
    SY   loc, 16(auth)
    LY   a3, 16(auth)
    EXPECT_TAG a3, 1
    EXPECT_PERMS a3, PERM_GL, 0

    NEXT_TEST "control: a global capability stored without SL keeps its tag"
    SY   glob, 32(a4)
    LY   a3, 32(auth)
    EXPECT_TAG a3, 1
    YEQ  t3, a3, glob
    beqz t3, fail

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER_PCC

.section .bss
.balign 64
buf:
    .space 64

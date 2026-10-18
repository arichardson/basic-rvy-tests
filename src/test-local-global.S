/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability local/global level (G) and the Store Local (SL) and Load Global
 * (LG, formerly EL in 0.9.3) permissions (Zylg / Zylevels1, zylevels1.adoc):
 *
 *  - On RVY (zylevels1.adoc #zylevels1_lg_perm and Table
 *    zylevels1_load_summary), loading a tagged capability through an authority
 *    without LG clears the loaded capability's G flag (making it local),
 *    whether the authority itself is global or local. If the loaded capability
 *    is unsealed, its LG permission is cleared as well; if it is sealed, LG is
 *    preserved. On 0.9.3 (Zcherilevels EL), G is instead restricted to
 *    auth.G & loaded.G, so a global authority without EL preserves G=1.
 *  - Loading an unsealed capability through an authority without LM clears W
 *    and LM, which on RVY transitively legalizes SL (dependent on C and W per
 *    rule Zylevels1-2) to 0.
 *  - On RVY, clearing G via YPERMC is permitted even on a sealed sentry
 *    capability without clearing its tag (zylevels1.adoc #zylevels1_acperm_bit_field
 *    and acperm_32bit.adoc); on 0.9.3 ACPERM detags any sealed capability.
 *  - Storing a local capability (G = 0) through an authority without SL strips
 *    its tag in memory, whereas storing a local capability with SL or storing
 *    a global capability (G = 1) without SL preserves the tag
 *    (zylevels1.adoc #zylevels1_sl_perm and Table zylevels1_store_summary).
 *  - Capability subset checks (YSS and YBLD) require cs2.G == 0 || cs1.G == 1
 *    (zylevels1.adoc "Interaction with Capability Subsets"): a local
 *    capability is a subset of an otherwise-equal global capability, while a
 *    global capability is not a subset of a local one.
 */
#define TEST_NAME "local-global"
#include "testmacros.h"
#include "exceptions.h"

#define root  s0                 /* ddc */
#define auth  a0                 /* [buf, buf + 64), data RW + C + LM + LG + SL + G */
#define glob  a1                 /* a global capability to store */
#define loc   a2                 /* the same capability with G = 0 (local) */

/* YPERMR of \reg has the bits in \mask set to \val, and \reg is tagged. */
.macro EXPECT_PERMS reg, mask, val
    EXPECT_TAG \reg, 1
    YPERMR t3, \reg
    li   t4, \mask
    and  t3, t3, t4
    li   t4, \val
    EXPECT_EQ t4, t3
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    csrrs root, CSR_DDC, x0
    lla   t0, buf
    YMODESWY

    /*
     * Derive auth and glob without X and ASR so they are capability-data RW
     * capabilities (Quadrant 3 entry 6 on RV32), allowing LG, SL, and G to be
     * dropped independently on both RV32 and RV64.
     */
    li   t1, 64
    YADDRW auth, root, t0
    YBNDSW auth, auth, t1
    li   t1, DROP_MASK(PERM_X | PERM_ASR)
    DROP_PERMS auth, auth, t1
    addi t1, t0, 48
    YADDRW glob, auth, t1
    li   t1, DROP_MASK(PERM_G)
    DROP_PERMS loc, glob, t1

    NEXT_TEST "control: the stored capabilities are tagged, global and local"
    EXPECT_PERMS glob, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                       PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W
    EXPECT_PERMS loc,  PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                       PERM_LG|PERM_SL|PERM_LM|PERM_W
    EXPECT_PERMS auth, PERM_G|PERM_LG|PERM_SL|PERM_LM, \
                       PERM_G|PERM_LG|PERM_SL|PERM_LM

    NEXT_TEST "control: a load through the full authority changes nothing"
    SY   glob, 0(auth)
    LY   a3, 0(auth)
    EXPECT_NO_TRAP
    YEQ  t3, a3, glob
    EXPECT_NONZERO t3

    NEXT_TEST "a global authority without LG clears G and LG on RVY (EL only on 0.9.3)"
    li   t1, DROP_MASK(PERM_LG)
    DROP_PERMS a4, auth, t1
    LY   a3, 0(a4)
#ifdef CHERI_093
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                     PERM_G|PERM_SL|PERM_LM|PERM_W
#else
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                     PERM_SL|PERM_LM|PERM_W
#endif

    NEXT_TEST "a local authority without LG makes the loaded capability local"
    li   t1, DROP_MASK(PERM_LG | PERM_G)
    DROP_PERMS a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                     PERM_SL|PERM_LM|PERM_W

    NEXT_TEST "control: a local authority with LG leaves the level alone"
    li   t1, DROP_MASK(PERM_G)
    DROP_PERMS a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_G|PERM_LG, PERM_G|PERM_LG
    YEQ  t3, a3, glob
    EXPECT_NONZERO t3

    NEXT_TEST "an authority without LM clears W and LM (and SL on RVY) from the loaded capability"
    li   t1, DROP_MASK(PERM_LM)
    DROP_PERMS a4, auth, t1
    LY   a3, 0(a4)
#ifdef CHERI_093
    EXPECT_PERMS a3, PERM_LM|PERM_W, 0
#else
    EXPECT_PERMS a3, PERM_LM|PERM_W|PERM_SL, 0
#endif

    NEXT_TEST "dropping C clears LG and SL, and dropping R clears LG (and C+SL on RV32)"
    li   t1, DROP_MASK(PERM_C)
    DROP_PERMS a3, auth, t1
    EXPECT_PERMS a3, PERM_C|PERM_LM|PERM_LG|PERM_SL|PERM_R|PERM_W|PERM_G, \
                     PERM_R|PERM_W|PERM_G
    li   t1, DROP_MASK(PERM_R)
    DROP_PERMS a3, auth, t1
#if __riscv_xlen == 64
    EXPECT_PERMS a3, PERM_R|PERM_LM|PERM_LG|PERM_C|PERM_W|PERM_SL|PERM_G, \
                     PERM_C|PERM_W|PERM_SL|PERM_G
#else
    EXPECT_PERMS a3, PERM_R|PERM_LM|PERM_LG|PERM_C|PERM_W|PERM_SL|PERM_G, \
                     PERM_W|PERM_G
#endif

    NEXT_TEST "a sealed capability is made local without LG, but keeps LG"
    auipc a5, 0
    YSEALE a5, a5
    SY   a5, 0(auth)
    li   t1, DROP_MASK(PERM_LG | PERM_G)
    DROP_PERMS a4, auth, t1
    LY   a3, 0(a4)
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_LM|PERM_W, PERM_LG|PERM_LM|PERM_W

    NEXT_TEST "clearing G on a sealed sentry preserves its tag and seal on RVY (detags on 0.9.3)"
    li   t1, DROP_MASK(PERM_G)
    DROP_PERMS a3, a5, t1
#ifdef CHERI_093
    EXPECT_TAG a3, 0
#else
    EXPECT_PERMS a3, PERM_G|PERM_LG, PERM_LG
    YTYPER t3, a3
    EXPECT_NONZERO t3
#endif

    li   t1, DROP_MASK(PERM_SL)
    DROP_PERMS a4, auth, t1      /* a4 = auth without SL */

    NEXT_TEST "a local capability stored without SL is stored untagged"
    SY   loc, 16(a4)
    EXPECT_NO_TRAP
    LY   a3, 16(auth)
    EXPECT_TAG a3, 0

    NEXT_TEST "control: a local capability stored with SL keeps its tag"
    SY   loc, 16(auth)
    LY   a3, 16(auth)
    EXPECT_PERMS a3, PERM_G, 0

    NEXT_TEST "control: a global capability stored without SL keeps its tag"
    SY   glob, 32(a4)
    LY   a3, 32(auth)
    EXPECT_TAG a3, 1
    YEQ  t3, a3, glob
    EXPECT_NONZERO t3

    NEXT_TEST "yss and ybld treat local as a subset of global and reject global under local"
    YSS  t3, glob, loc
    EXPECT_NONZERO t3
    YSS  t3, loc, glob
    EXPECT_ZERO t3
    /* Store loc without SL to obtain an untagged local capability in a3. */
    SY   loc, 16(a4)
    LY   a3, 16(auth)
    EXPECT_TAG a3, 0
    YBLD a5, glob, a3
    EXPECT_TAG a5, 1
    YEQ  t3, a5, loc
    EXPECT_NONZERO t3
    /* Clear the tag of the stored glob in memory and try to rebuild under loc. */
    LX   t1, 32(auth)
    SX   t1, 32(auth)
    LY   a3, 32(auth)
    EXPECT_TAG a3, 0
    YBLD a5, loc, a3
    EXPECT_TAG a5, 0
    EXPECT_NO_TRAP

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

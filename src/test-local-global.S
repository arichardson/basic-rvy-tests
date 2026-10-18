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
 *  - When Zylg is not implemented (rvy64-encoding.adoc #section_cap_encoding64,
 *    rvy32-encoding.adoc #section_cap_encoding32, gcperm_32bit.adoc, and
 *    acperm_32bit.adoc), the G, LG, and SL bits in the unpacked YPERMR/YPERMC
 *    permission bitmask are hardwired to 1 and cannot be cleared by YPERMC,
 *    capability loads and stores never strip tags or G/LG on level grounds,
 *    and the raw G metadata bit and Zylg-only AP encodings are reserved zero
 *    (causing capabilities with those bits set via YHIW to fail integrity
 *    checks).
 */
#define TEST_NAME "local-global"
#include "testmacros.h"
#include "exceptions.h"

#define root       s0            /* ddc */
#define auth       s1            /* [buf, buf + 64), data RW + C + LM (+ LG + SL + G) */
#define global_cap s2            /* a global capability to store */
#define local_cap  s7            /* the same capability with G = 0 (local) */
#define has_zylg   a7            /* 1 when Zylg is enabled, 0 when disabled */

#if __riscv_xlen == 64
#define META_G_SHIFT 43
#ifdef CHERI_093
#define META_LG_SHIFT 50         /* 0.9.3 puts M at bit 52 and AP[7:0] at [51:44] */
#else
#define META_LG_SHIFT 51         /* RVY puts AP[7:0] at [52:45] and M at bit 44 */
#endif
#else
#define META_G_SHIFT 24
#endif

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
     * Derive auth and global_cap without X and ASR so they are capability-data
     * RW capabilities (Quadrant 3 entry 6 with Zylg or entry 7 without Zylg on
     * RV32), allowing LG, SL, and G to be dropped independently when Zylg is
     * enabled on both RV32 and RV64.
     */
    li   t1, 64
    YADDRW auth, root, t0
    YBNDSW auth, auth, t1
    li   t1, DROP_MASK(PERM_X | PERM_ASR)
    DROP_PERMS auth, auth, t1
    addi t1, t0, 48
    YADDRW global_cap, auth, t1
    li   t1, DROP_MASK(PERM_G)
    DROP_PERMS local_cap, global_cap, t1

    /*
     * Probe whether Zylg is enabled on this hart by checking whether YPERMC
     * cleared PERM_G on local_cap: when Zylg is disabled, PERM_G is hardwired
     * to 1 in YPERMC and YPERMR so it remains set after DROP_PERMS.
     */
    YPERMR t1, local_cap
    andi t1, t1, PERM_G
    seqz has_zylg, t1

    SKIPPABLE_BLOCK_BEGIN
    beqz has_zylg, skip_zylg_enabled

    NEXT_TEST "control: the stored capabilities are tagged, global and local"
    EXPECT_PERMS global_cap, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                             PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W
    EXPECT_PERMS local_cap,  PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                             PERM_LG|PERM_SL|PERM_LM|PERM_W
    EXPECT_PERMS auth,       PERM_G|PERM_LG|PERM_SL|PERM_LM, \
                             PERM_G|PERM_LG|PERM_SL|PERM_LM

    NEXT_TEST "control: a load through the full authority changes nothing"
    SY   global_cap, 0(auth)
    LY   a3, 0(auth)
    EXPECT_NO_TRAP
    YEQ  t3, a3, global_cap
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
    YEQ  t3, a3, global_cap
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
    SY   local_cap, 16(a4)
    EXPECT_NO_TRAP
    LY   a3, 16(auth)
    EXPECT_TAG a3, 0

    NEXT_TEST "control: a local capability stored with SL keeps its tag"
    SY   local_cap, 16(auth)
    LY   a3, 16(auth)
    EXPECT_PERMS a3, PERM_G, 0

    NEXT_TEST "control: a global capability stored without SL keeps its tag"
    SY   global_cap, 32(a4)
    LY   a3, 32(auth)
    EXPECT_TAG a3, 1
    YEQ  t3, a3, global_cap
    EXPECT_NONZERO t3

    NEXT_TEST "yss and ybld treat local as a subset of global and reject global under local"
    YSS  t3, global_cap, local_cap
    EXPECT_NONZERO t3
    YSS  t3, local_cap, global_cap
    EXPECT_ZERO t3
    /* Store local_cap without SL to obtain an untagged local capability in a3. */
    SY   local_cap, 16(a4)
    LY   a3, 16(auth)
    EXPECT_TAG a3, 0
    YBLD a5, global_cap, a3
    EXPECT_TAG a5, 1
    YEQ  t3, a5, local_cap
    EXPECT_NONZERO t3
    /* Clear the tag of the stored global_cap in memory and try to rebuild under local_cap. */
    LX   t1, 32(auth)
    SX   t1, 32(auth)
    LY   a3, 32(auth)
    EXPECT_TAG a3, 0
    YBLD a5, local_cap, a3
    EXPECT_TAG a5, 0
    EXPECT_NO_TRAP

    j    zylg_enabled_done
skip_zylg_enabled:
    SKIPPABLE_BLOCK_SKIPPED "Zylg is disabled"
zylg_enabled_done:

    /*
     * When Zylg is disabled, G, LG, and SL are unimplemented extension bits in
     * the [23:0] YPERMR/YPERMC permission bitfield: they always report 1 in
     * YPERMR (even on NULL or capabilities with all allocated permissions
     * cleared), cannot be cleared by YPERMC, never strip tags or permissions
     * on capability loads and stores, and their raw metadata bits are reserved
     * zero.
     */
    SKIPPABLE_BLOCK_BEGIN
    bnez has_zylg, skip_zylg_disabled

    NEXT_TEST "without Zylg: G, LG, and SL report 1 in ypermr while raw metadata bits are zero"
    EXPECT_PERMS root, PERM_G|PERM_LG|PERM_SL, PERM_G|PERM_LG|PERM_SL
    EXPECT_PERMS auth, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_R|PERM_W|PERM_C, \
                       PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_R|PERM_W|PERM_C
    YPERMR t3, x0
    li   t4, PERM_R|PERM_W|PERM_C|PERM_LM|PERM_X|PERM_ASR|PERM_G|PERM_LG|PERM_SL
    and  t3, t3, t4
    li   t4, PERM_G|PERM_LG|PERM_SL
    EXPECT_EQ t4, t3
    YHIR t1, root
    srli t2, t1, META_G_SHIFT
    andi t2, t2, 1
    EXPECT_ZERO t2
#if __riscv_xlen == 64
    srli t2, t1, META_LG_SHIFT
    andi t2, t2, 3               /* AP[7:6] (SL, LG) are reserved zero */
    EXPECT_ZERO t2
#endif

    NEXT_TEST "without Zylg: ypermc ignores requests to clear G, LG, or SL"
    EXPECT_PERMS local_cap, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                            PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W
    YEQ  t3, local_cap, global_cap
    EXPECT_NONZERO t3
    li   t1, DROP_MASK(PERM_G | PERM_LG | PERM_SL)
    DROP_PERMS a3, auth, t1
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_R|PERM_W|PERM_C, \
                     PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_R|PERM_W|PERM_C
    YEQ  t3, a3, auth
    EXPECT_NONZERO t3
    li   t1, DROP_MASK(~0)
    DROP_PERMS a3, auth, t1      /* clear every clearable permission */
    EXPECT_PERMS a3, PERM_R|PERM_W|PERM_C|PERM_LM|PERM_X|PERM_ASR|PERM_G|PERM_LG|PERM_SL, \
                     PERM_G|PERM_LG|PERM_SL
    auipc a5, 0
    YSEALE a5, a5
    li   t1, DROP_MASK(PERM_G | PERM_LG | PERM_SL)
    DROP_PERMS a3, a5, t1
#ifdef CHERI_093
    EXPECT_TAG a3, 0
#else
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_SL, PERM_G|PERM_LG|PERM_SL
    YEQ  t3, a3, a5
    EXPECT_NONZERO t3
#endif

    NEXT_TEST "without Zylg: dropping C, R, or W leaves G, LG, and SL hardwired to 1"
    li   t1, DROP_MASK(PERM_C)
    DROP_PERMS a3, auth, t1
    EXPECT_PERMS a3, PERM_C|PERM_LM|PERM_LG|PERM_SL|PERM_R|PERM_W|PERM_G, \
                     PERM_R|PERM_W|PERM_G|PERM_LG|PERM_SL
    li   t1, DROP_MASK(PERM_R)
    DROP_PERMS a3, auth, t1
#if __riscv_xlen == 64
    EXPECT_PERMS a3, PERM_R|PERM_LM|PERM_LG|PERM_C|PERM_W|PERM_SL|PERM_G, \
                     PERM_C|PERM_W|PERM_G|PERM_LG|PERM_SL
#else
    EXPECT_PERMS a3, PERM_R|PERM_LM|PERM_LG|PERM_C|PERM_W|PERM_SL|PERM_G, \
                     PERM_W|PERM_G|PERM_LG|PERM_SL
#endif
    li   t1, DROP_MASK(PERM_W)
    DROP_PERMS a3, auth, t1
    EXPECT_PERMS a3, PERM_R|PERM_W|PERM_C|PERM_LM|PERM_G|PERM_LG|PERM_SL, \
                     PERM_R|PERM_C|PERM_LM|PERM_G|PERM_LG|PERM_SL

    NEXT_TEST "without Zylg: capability loads and stores never strip tags or G/LG"
    li   t1, DROP_MASK(PERM_LG | PERM_SL | PERM_G)
    DROP_PERMS a4, auth, t1
    SY   local_cap, 0(a4)
    LY   a3, 0(a4)
    EXPECT_NO_TRAP
    EXPECT_PERMS a3, PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W, \
                     PERM_G|PERM_LG|PERM_SL|PERM_LM|PERM_W
    YEQ  t3, a3, global_cap
    EXPECT_NONZERO t3

    NEXT_TEST "without Zylg: setting the reserved G bit or Zylg AP encodings fails integrity checks"
    YHIR t1, auth
    li   t2, 1
    slli t2, t2, META_G_SHIFT
    or   t2, t1, t2              /* set reserved G metadata bit */
    YHIW a3, auth, t2
    EXPECT_TAG a3, 0
#ifndef CHERI_093
    YPERMR t3, a3
    li   t4, PERM_R|PERM_W|PERM_C|PERM_LM|PERM_X|PERM_ASR|PERM_G|PERM_LG|PERM_SL
    and  t3, t3, t4
    li   t4, PERM_G|PERM_LG|PERM_SL
    EXPECT_EQ t4, t3
#endif
    SY   a3, 0(auth)
    LY   a3, 0(auth)
    YBLD a5, root, a3
    EXPECT_TAG a5, 0
#if __riscv_xlen == 64
    li   t2, 1
    slli t2, t2, META_LG_SHIFT
    or   t2, t1, t2              /* set reserved AP[6] (LG) bit on RV64 */
#else
    li   t2, ~(0x1f << 25)
    and  t2, t1, t2
    li   t3, (0x1e << 25)        /* Quadrant 3 entry 6 (Zylg-only) on RV32 */
    or   t2, t2, t3
#endif
    YHIW a3, auth, t2
    EXPECT_TAG a3, 0
#ifndef CHERI_093
    YPERMR t3, a3
    li   t4, PERM_R|PERM_W|PERM_C|PERM_LM|PERM_X|PERM_ASR|PERM_G|PERM_LG|PERM_SL
    and  t3, t3, t4
    li   t4, PERM_G|PERM_LG|PERM_SL
    EXPECT_EQ t4, t3
#endif
    SY   a3, 0(auth)
    LY   a3, 0(auth)
    YBLD a5, root, a3
    EXPECT_TAG a5, 0
    EXPECT_NO_TRAP

    j    zylg_disabled_done
skip_zylg_disabled:
    SKIPPABLE_BLOCK_SKIPPED "Zylg is enabled"
zylg_disabled_done:

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

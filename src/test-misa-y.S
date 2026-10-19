/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY misa.Y enable/disable and Xenvcfg.Y tests:
 *  - misa.Y is set (1) at reset
 *  - when Zyhybrid (Smyhybrid/Ssyhybrid) is implemented:
 *    - menvcfg, senvcfg, and henvcfg reset to 0 and their Y bit is bit 9
 *      (bit 28 is not writable)
 *    - misa.Y can only be cleared while pcc, ddc, and every implemented
 *      xtvec/xepc (mtvecc/mepcc, stvecc/sepcc, vstvecc/vsepcc) are currently
 *      equal to root capabilities (including full architectural and
 *      software-defined permissions and unsealed CT=0)
 *    - once cleared, RVY instructions and every CSR the extension adds raise
 *      illegal instruction, and both come back when it is set again
 *    - while misa.Y is 0, menvcfg.Y, senvcfg.Y, and henvcfg.Y are
 *      read-only 0
 *    - misa.Y can be set again
 *    - S-mode CHERI enable is gated by misa.Y & menvcfg.Y
 *    - U-mode CHERI enable is gated by misa.Y & menvcfg.Y & senvcfg.Y
 *  - when Zyhybrid is not implemented:
 *    - misa.Y, menvcfg.Y, senvcfg.Y, and henvcfg.Y are read-only 1
 *    - ddc and the Zyhybrid mode-switch instructions raise illegal instruction
 *    - S-mode and U-mode CHERI are always enabled
 */
#define TEST_NAME "misa-y"
#ifdef CHERI_093
#error "Requires RVY >= 0.9.9 (0.9.3 gates CHERI on mseccfg.CRE rather than misa.Y)"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define has_zyhybrid s0
#define has_h        s1

/*
 * Enter privilege mode \mpp (0x0800 for S-mode, 0 for U-mode) at \target and
 * return to M-mode at \cont when \target executes ecall. Uses YADDRW when
 * misa.Y is set so CSR_MEPC receives a valid capability on purecap-only harts
 * without Zyhybrid as well as an address in integer mode.
 */
.macro ENTER_PRIV mpp, target, cont
    li     t0, 0x1800
    csrc   CSR_MSTATUS, t0
    .if (\mpp) != 0
    li     t0, \mpp
    csrs   CSR_MSTATUS, t0
    .endif
    lla    t0, \target
    csrr   t1, CSR_MISA
    slli   t1, t1, (XLEN - 1 - 24)
    bgez   t1, 1f
    auipc  t1, 0
    YADDRW t0, t1, t0
1:  csrw   CSR_MEPC, t0
    lla    m_continue, \cont
    mret
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* Configure PMP entry 0 as NAPOT RWX over the entire address space. */
    li   t0, -1
    csrw CSR_PMPADDR0, t0
    li   t0, 0x1f
    csrw CSR_PMPCFG0, t0

    csrr has_h, CSR_MISA
    andi has_h, has_h, (1 << 7)  /* misa.H */

    /*
     * Probe whether Zyhybrid is implemented on this hart: YMODER is part of
     * Zyhybrid, so it executes without trapping when Zyhybrid is present and
     * raises CAUSE_ILLEGAL_INSN on a purecap-only hart.
     */
    li   has_zyhybrid, 1
    YMODER t0, x0
    beqz trap_count, 1f
    li   has_zyhybrid, 0
    CLEAR_TRAPS
1:

    /* misa.Y is set (1) at reset on all RVY harts. */
    NEXT_TEST "misa.Y is set at reset"
    csrr t0, CSR_MISA
    li   t1, MISA_Y
    and  t2, t0, t1
    EXPECT_NONZERO t2

    SKIPPABLE_BLOCK_BEGIN
    beqz has_zyhybrid, .Lskip_zyhybrid

    /* menvcfg, senvcfg, and henvcfg reset to 0; Y is bit 9; bit 28 is not writable. */
    NEXT_TEST "menvcfg resets to 0 and Y is bit 9 not bit 28"
    csrr t0, CSR_MENVCFG
    EXPECT_ZERO t0
    li   t1, ENVCFG_Y
    csrs CSR_MENVCFG, t1
    csrr t0, CSR_MENVCFG
    EXPECT_EQ t0, t1
    li   t2, 1 << 28             /* pre-0.9.9 CRE position */
    csrs CSR_MENVCFG, t2
    csrr t0, CSR_MENVCFG
    EXPECT_EQ t0, t1
    csrc CSR_MENVCFG, t1         /* back to the reset value */

    NEXT_TEST "senvcfg and henvcfg reset to 0 and Y is bit 9 not bit 28"
    csrr t0, CSR_SENVCFG
    EXPECT_ZERO t0
    li   t1, ENVCFG_Y
    csrs CSR_SENVCFG, t1
    csrr t0, CSR_SENVCFG
    EXPECT_EQ t0, t1
    li   t2, 1 << 28
    csrs CSR_SENVCFG, t2
    csrr t0, CSR_SENVCFG
    EXPECT_EQ t0, t1
    csrc CSR_SENVCFG, t1
    beqz has_h, 1f
    csrr t0, CSR_HENVCFG
    EXPECT_ZERO t0
    csrs CSR_HENVCFG, t1
    csrr t0, CSR_HENVCFG
    EXPECT_EQ t0, t1
    csrs CSR_HENVCFG, t2
    csrr t0, CSR_HENVCFG
    EXPECT_EQ t0, t1
    csrc CSR_HENVCFG, t1
1:

    /*
     * misa.Y writes of 0 are ignored while pcc, ddc, or any xtvec/xepc is not
     * currently a root capability. Each register is corrupted (replaced with
     * the NULL capability, or, for pcc, a tightly bounded derived capability),
     * the clear attempt is checked to fail, and the register is restored to
     * root before moving on so later checks are unaffected. Capability CSR
     * writes need capability pointer mode.
     */
    NEXT_TEST "clearing misa.Y is refused unless every xtvec/xepc is root"
    YMODESWY                             /* enter cap mode */

    /*
     * Corrupt \csr_num (saving its root value in \save_creg), verify
     * clearing misa.Y is rejected, then restore \csr_num.
     */
.macro CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT csr_num, save_creg
    csrrw \save_creg, \csr_num, x0
    li    t2, MISA_Y
    csrc  CSR_MISA, t2
    csrr  t3, CSR_MISA
    csrs  CSR_MISA, t2
    and   t3, t3, t2
    EXPECT_NONZERO t3
    YMODESWY
    csrrw x0, \csr_num, \save_creg
.endm

    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_DDC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_MTVEC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_MEPC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_STVEC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_SEPC, s2
    /* vstvec/vsepc only exist when the hypervisor extension is implemented. */
    beqz  has_h, 1f
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_VSTVEC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_VSEPC, s2
1:

    /*
     * A capability with full bounds and tag=1 that has a single architectural
     * or software-defined permission stripped, or is sealed as a sentry, is
     * also not equal to root and must prevent clearing misa.Y.
     */
    csrrs s2, CSR_DDC, x0
    li    t0, PERM_W
    YPERMC t1, s2, t0
    csrrw x0, CSR_DDC, t1
    li    t2, MISA_Y
    csrc  CSR_MISA, t2
    csrr  t3, CSR_MISA
    csrs  CSR_MISA, t2
    and   t3, t3, t2
    EXPECT_NONZERO t3
    YMODESWY

    li    t0, (1 << 6)           /* single SDP bit */
    YPERMC t1, s2, t0
    csrrw x0, CSR_DDC, t1
    li    t2, MISA_Y
    csrc  CSR_MISA, t2
    csrr  t3, CSR_MISA
    csrs  CSR_MISA, t2
    and   t3, t3, t2
    EXPECT_NONZERO t3
    YMODESWY
    csrrw x0, CSR_DDC, s2

    csrrs s2, CSR_MEPC, x0
    YSEALE t1, s2                /* root bounds and perms, but sealed (CT=1) */
    csrrw x0, CSR_MEPC, t1
    li    t2, MISA_Y
    csrc  CSR_MISA, t2
    csrr  t3, CSR_MISA
    csrs  CSR_MISA, t2
    and   t3, t3, t2
    EXPECT_NONZERO t3
    YMODESWY
    csrrw x0, CSR_MEPC, s2

    /*
     * pcc itself must also be root. There is no CSR to overwrite it
     * directly, so derive a tightly bounded (non-root) capability from
     * the current (root) pcc and briefly make it the active pcc via a
     * capability jump (JALR in capability mode takes its new pcc from
     * cs1), then jump back using a second, unmodified root-derived
     * capability. Every instruction below is exactly 4 bytes
     * (.option norvc is in effect for the whole file), so the jump
     * offsets are simple compile-time byte counts, annotated with the
     * offset of each instruction relative to the first "auipc t0, 0".
     */
    auipc t0, 0                          /* +0:  ct0 = root, cursor = here */
    auipc t1, 0                          /* +4:  ct1 = root, cursor = here */
    addi  t2, x0, 64                     /* +8:  requested bounds length */
    YBNDSW t1, t1, t2                    /* +12: setbounds ct1,ct1,t2 (non-root) */
    jalr  x0, 16(t1)                     /* +16: pcc <- ct1; jump to +20 */
    lui   t2, 0x1000                     /* +20: t2 = MISA_Y (pcc is not root here) */
    csrc  CSR_MISA, t2                   /* +24 */
    csrr  t3, CSR_MISA                   /* +28 */
    and   t3, t3, t2                     /* +32 */
    csrs  CSR_MISA, t2                   /* +36 */
    jalr  x0, 44(t0)                     /* +40: pcc <- ct0 (root); jump to +44 */

    YMODESWI                             /* +44: back to int mode */
    EXPECT_NONZERO t3

    /* With every checked register a root capability again, clearing misa.Y succeeds. */
    NEXT_TEST "with all of them root again misa.Y clears"
    li   t1, MISA_Y
    csrc CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    ASSERT_ZERO t2

    /*
     * With Y=0 the extension is gone, so its instructions and every CSR it
     * adds must read as illegal rather than as some stale value. The CSRs are
     * checked one at a time so a failure names the one at fault. Re-enable
     * misa.Y across EXPECT_* so console_fail can run if a check fails.
     */
.macro EXPECT_ILLEGAL_WITH_Y_CLEAR
    li   t4, MISA_Y
    csrs CSR_MISA, t4
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    li   t4, MISA_Y
    csrc CSR_MISA, t4
.endm

.macro EXPECT_ZERO_WITH_Y_CLEAR reg
    li   t4, MISA_Y
    csrs CSR_MISA, t4
    EXPECT_ZERO \reg
    li   t4, MISA_Y
    csrc CSR_MISA, t4
.endm

    NEXT_TEST "with Y clear an RVY instruction is illegal"
    YAMASK t2, t0
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    NEXT_TEST "with Y clear reading ddc is illegal"
    csrrs t2, CSR_DDC, x0
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    NEXT_TEST "with Y clear reading mtidc is illegal"
    csrrs t2, CSR_MTIDC, x0
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    NEXT_TEST "with Y clear reading stidc is illegal"
    csrrs t2, CSR_STIDC, x0
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    NEXT_TEST "with Y clear reading utidc is illegal"
    csrrs t2, CSR_UTIDC, x0
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    /* Writes are gone too, not just reads. */
    NEXT_TEST "with Y clear writing mtidc is illegal"
    csrw CSR_MTIDC, x0
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    /*
     * When misa.Y is 0, the base architecture is RVI/RVE rather than RVY, so
     * menvcfg.Y, senvcfg.Y, and henvcfg.Y are read-only 0: writes while
     * misa.Y is 0 are ignored, and setting Y while misa.Y is 1 still reads
     * back as 0 while misa.Y is 0.
     */
    NEXT_TEST "with Y clear menvcfg.Y is read-only 0"
    li   t1, ENVCFG_Y
    csrs CSR_MENVCFG, t1
    csrr t2, CSR_MENVCFG
    and  t2, t2, t1
    EXPECT_ZERO_WITH_Y_CLEAR t2
    li   t4, MISA_Y
    csrs CSR_MISA, t4
    csrr t2, CSR_MENVCFG
    and  t2, t2, t1
    EXPECT_ZERO t2
    csrc CSR_MENVCFG, t1
    csrc CSR_MISA, t4

    NEXT_TEST "with Y clear senvcfg.Y and henvcfg.Y are read-only 0"
    li   t1, ENVCFG_Y
    csrs CSR_SENVCFG, t1
    csrr t2, CSR_SENVCFG
    and  t2, t2, t1
    EXPECT_ZERO_WITH_Y_CLEAR t2
    li   t4, MISA_Y
    csrs CSR_MISA, t4
    csrr t2, CSR_SENVCFG
    and  t2, t2, t1
    EXPECT_ZERO t2
    csrc CSR_SENVCFG, t1
    csrc CSR_MISA, t4
    beqz has_h, 1f
    csrs CSR_HENVCFG, t1
    csrr t2, CSR_HENVCFG
    and  t2, t2, t1
    EXPECT_ZERO_WITH_Y_CLEAR t2
    csrs CSR_MISA, t4
    csrr t2, CSR_HENVCFG
    and  t2, t2, t1
    EXPECT_ZERO t2
    csrc CSR_HENVCFG, t1
    csrc CSR_MISA, t4
1:

    NEXT_TEST "clearing misa.Y makes menvcfg.Y, senvcfg.Y, and henvcfg.Y read as 0"
    li   t4, MISA_Y
    csrs CSR_MISA, t4
    li   t1, ENVCFG_Y
    csrs CSR_MENVCFG, t1
    csrs CSR_SENVCFG, t1
    beqz has_h, 1f
    csrs CSR_HENVCFG, t1
1:  csrc CSR_MISA, t4
    csrr t2, CSR_MENVCFG
    and  t2, t2, t1
    EXPECT_ZERO_WITH_Y_CLEAR t2
    csrr t2, CSR_SENVCFG
    and  t2, t2, t1
    EXPECT_ZERO_WITH_Y_CLEAR t2
    beqz has_h, 2f
    csrr t2, CSR_HENVCFG
    and  t2, t2, t1
    EXPECT_ZERO_WITH_Y_CLEAR t2
2:

    /* Even if menvcfg.Y was set before clearing misa.Y, S-mode has CHERI disabled. */
    NEXT_TEST "with Y clear S-mode CHERI is disabled even after setting menvcfg.Y"
    ENTER_PRIV 0x0800, s_code_y_clear, m_cont_y_clear
s_code_y_clear:
    YAMASK t2, t0
    ecall
m_cont_y_clear:
    EXPECT_ILLEGAL_WITH_Y_CLEAR

    /* misa.Y can be set again and RVY instructions work. */
    NEXT_TEST "misa.Y can be set again and RVY instructions work"
    li   t1, MISA_Y
    csrs CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    ASSERT_NONZERO t2
    li   t0, 0
    YAMASK t2, t0
    EXPECT_NO_TRAP

    /* ... and so do the CSRs it adds. */
    NEXT_TEST "and so do the CSRs the extension adds"
    csrrs t2, CSR_DDC, x0
    csrrs t2, CSR_MTIDC, x0
    csrrs t2, CSR_STIDC, x0
    csrrs t2, CSR_UTIDC, x0
    EXPECT_NO_TRAP

    /* S-mode CHERI enable is menvcfg.Y. */
    NEXT_TEST "S-mode CHERI is gated by menvcfg.Y"
    li   t1, ENVCFG_Y
    csrc CSR_MENVCFG, t1
    csrc CSR_SENVCFG, t1
    beqz has_h, 1f
    csrc CSR_HENVCFG, t1
1:  ENTER_PRIV 0x0800, s_code_disabled, m_cont_a
s_code_disabled:
    YAMASK t2, t0                        /* in S-mode: illegal */
    ecall
m_cont_a:
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    /* enable S-mode CHERI and retry */
    li   t1, ENVCFG_Y
    csrs CSR_MENVCFG, t1
    ENTER_PRIV 0x0800, s_code_enabled, m_cont_b
s_code_enabled:
    YAMASK t2, t0                        /* in S-mode: works */
    ecall
m_cont_b:
    EXPECT_NO_TRAP

    /* U-mode CHERI enable requires both menvcfg.Y and senvcfg.Y. */
    NEXT_TEST "U-mode CHERI requires both menvcfg.Y and senvcfg.Y"
    li   t1, ENVCFG_Y
    csrs CSR_MENVCFG, t1
    csrc CSR_SENVCFG, t1
    ENTER_PRIV 0, u_code_s0, m_cont_u0
u_code_s0:
    YAMASK t2, t0                        /* menvcfg.Y=1, senvcfg.Y=0: illegal */
    ecall
m_cont_u0:
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    li   t1, ENVCFG_Y
    csrc CSR_MENVCFG, t1
    csrs CSR_SENVCFG, t1
    ENTER_PRIV 0, u_code_m0, m_cont_u1
u_code_m0:
    YAMASK t2, t0                        /* menvcfg.Y=0, senvcfg.Y=1: illegal */
    ecall
m_cont_u1:
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    li   t1, ENVCFG_Y
    csrs CSR_MENVCFG, t1
    csrs CSR_SENVCFG, t1
    ENTER_PRIV 0, u_code_enabled, m_cont_u2
u_code_enabled:
    YAMASK t2, t0                        /* menvcfg.Y=1, senvcfg.Y=1: works */
    ecall
m_cont_u2:
    EXPECT_NO_TRAP

    j    .Ldone_zyhybrid
.Lskip_zyhybrid:
    SKIPPABLE_BLOCK_SKIPPED "Zyhybrid not implemented"
.Ldone_zyhybrid:

    /*
     * Purecap-only RVY hart (Zyhybrid not implemented):
     * misa.Y, menvcfg.Y, senvcfg.Y, and henvcfg.Y are read-only 1,
     * ddc and mode-switch instructions are not implemented, and CHERI is
     * always enabled in S-mode and U-mode.
     */
    SKIPPABLE_BLOCK_BEGIN
    bnez has_zyhybrid, .Lskip_no_zyhybrid

    NEXT_TEST "without Zyhybrid misa.Y is read-only 1"
    li   t1, MISA_Y
    csrc CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    EXPECT_NONZERO t2

    NEXT_TEST "without Zyhybrid menvcfg.Y is read-only 1 and bit 28 is not writable"
    li   t1, ENVCFG_Y
    csrr t0, CSR_MENVCFG
    EXPECT_EQ t0, t1
    csrc CSR_MENVCFG, t1
    csrr t0, CSR_MENVCFG
    EXPECT_EQ t0, t1
    li   t2, 1 << 28
    csrs CSR_MENVCFG, t2
    csrr t0, CSR_MENVCFG
    EXPECT_EQ t0, t1

    NEXT_TEST "without Zyhybrid senvcfg.Y and henvcfg.Y are read-only 1 and bit 28 is not writable"
    li   t1, ENVCFG_Y
    csrr t0, CSR_SENVCFG
    EXPECT_EQ t0, t1
    csrc CSR_SENVCFG, t1
    csrr t0, CSR_SENVCFG
    EXPECT_EQ t0, t1
    li   t2, 1 << 28
    csrs CSR_SENVCFG, t2
    csrr t0, CSR_SENVCFG
    EXPECT_EQ t0, t1
    beqz has_h, 1f
    csrr t0, CSR_HENVCFG
    EXPECT_EQ t0, t1
    csrc CSR_HENVCFG, t1
    csrr t0, CSR_HENVCFG
    EXPECT_EQ t0, t1
    csrs CSR_HENVCFG, t2
    csrr t0, CSR_HENVCFG
    EXPECT_EQ t0, t1
1:

    NEXT_TEST "without Zyhybrid ddc and mode-switch instructions are illegal"
    csrrs t2, CSR_DDC, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YMODESWI
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YMODESWY
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YMODER t2, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    YMODEW t2, x0, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "without Zyhybrid S-mode and U-mode CHERI are always enabled"
    ENTER_PRIV 0x0800, s_code_purecap, m_cont_purecap_s
s_code_purecap:
    YAMASK t2, t0
    ecall
m_cont_purecap_s:
    EXPECT_NO_TRAP
    ENTER_PRIV 0, u_code_purecap, m_cont_purecap_u
u_code_purecap:
    YAMASK t2, t0
    ecall
m_cont_purecap_u:
    EXPECT_NO_TRAP

    j    .Ldone_no_zyhybrid
.Lskip_no_zyhybrid:
    SKIPPABLE_BLOCK_SKIPPED "Zyhybrid implemented"
.Ldone_no_zyhybrid:

    TEST_PASS
fail:
    TEST_FAIL

TRAP_HANDLER

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY misa.Y enable/disable and Xenvcfg.CRE tests:
 *  - misa.Y is set (1) at reset
 *  - menvcfg/senvcfg reset to just Y (bit 9, formerly CRE), which is
 *    read-only 1; bits 8 and 28 are WPRI (golden Sail, see Test 2)
 *  - misa.Y can only be cleared while pcc, ddc, and every implemented
 *    xtvec/xepc (mtvecc/mepcc, stvecc/sepcc, vstvecc/vsepcc) are currently
 *    equal to root capabilities (including full architectural and
 *    software-defined permissions and unsealed CT=0)
 *  - once cleared, RVY instructions and ddc raise illegal instruction, and
 *    both come back when it is set again; the Zstid CSRs (mtidc, stidc,
 *    utidc) do not depend on misa.Y and stay accessible
 *  - misa.Y can be set again
 *  - S-mode CHERI stays enabled: clearing menvcfg.Y is ignored
 */
#define TEST_NAME "misa-y"
#ifdef CHERI_093
#error "RVY v0.9.9 only: 0.9.3 gates CHERI on mseccfg.CRE rather than misa.Y"
#endif
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* Test 1: misa.Y is set (1) at reset */
    NEXT_TEST "misa.Y is set at reset"
    csrr t0, CSR_MISA
    li   t1, MISA_Y
    and  t2, t0, t1
    beqz t2, fail

    /*
     * Test 2: menvcfg/senvcfg.Y (formerly CRE) is bit 9 and read-only 1.
     * Golden Sail sail-cheri-riscv 42e2d75: Y : 9 in
     * src/cheri_sys_regs_types.sail:12, :32 (bit 8 is wpri_1, :14);
     * legalize_menvcfg/legalize_senvcfg force Y = 0b1 and keep every other
     * field read-only 0 bar FIOM (src/cheri_sys_regs_envcfg.sail:10-36), and
     * the reset value is that legalization applied to zeros (sail-riscv
     * model/riscv_sys_regs.sail:408-409). So clearing Y is ignored, and the
     * bit-8 (spec-text diagram) and bit-28 (0.9.3) positions are WPRI.
     */
    NEXT_TEST "menvcfg/senvcfg.Y is bit 9 and read-only 1; bits 8, 28 WPRI"
    li   t1, MENVCFG_CRE
    csrr t0, CSR_MENVCFG
    bne  t1, t0, fail            /* reset value: Y only */
    csrc CSR_MENVCFG, t1
    csrr t0, CSR_MENVCFG
    bne  t1, t0, fail            /* clearing Y is ignored */
    li   t2, 1 << 8              /* WPRI (riscv-cheri diagram CRE position) */
    csrs CSR_MENVCFG, t2
    csrr t0, CSR_MENVCFG
    bne  t1, t0, fail
    li   t2, 1 << 28             /* WPRI (0.9.3 CRE position) */
    csrs CSR_MENVCFG, t2
    csrr t0, CSR_MENVCFG
    bne  t1, t0, fail
    li   t1, SENVCFG_CRE
    csrr t0, CSR_SENVCFG
    bne  t1, t0, fail
    csrc CSR_SENVCFG, t1
    csrr t0, CSR_SENVCFG
    bne  t1, t0, fail

    /*
     * Test 3: misa.Y writes of 0 are ignored while pcc, ddc, or any
     * xtvec/xepc is not currently a root capability. Each register is
     * corrupted (replaced with the NULL capability, or -- for pcc -- a
     * tightly bounded derived capability), the clear attempt is checked
     * to fail, and the register is restored to root before moving on so
     * later checks are unaffected. Capability CSR writes need capability
     * pointer mode.
     */
    NEXT_TEST "clearing misa.Y is refused unless every xtvec/xepc is root"
    YMODESWY                             /* enter cap mode */

    /*
     * Corrupt \csr_num (saving its root value in \save_creg), verify
     * clearing misa.Y is rejected, then restore \csr_num.
     */
.macro CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT csr_num, save_creg
    csrrw \save_creg, \csr_num, x0
    li    t5, MISA_Y
    csrc  CSR_MISA, t5
    csrr  t6, CSR_MISA
    and   t6, t6, t5
    beqz  t6, fail
    csrrw x0, \csr_num, \save_creg
.endm

    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_DDC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_MTVEC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_MEPC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_STVEC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_SEPC, s2
    /* vstvec/vsepc only exist (and only count) when misa.H is set. */
    csrr  t0, CSR_MISA
    andi  t0, t0, (1 << 7)               /* misa.H */
    beqz  t0, 1f
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
    li    t5, MISA_Y
    csrc  CSR_MISA, t5
    csrr  t6, CSR_MISA
    and   t6, t6, t5
    beqz  t6, fail

    li    t0, (1 << 6)           /* single SDP bit */
    YPERMC t1, s2, t0
    csrrw x0, CSR_DDC, t1
    csrc  CSR_MISA, t5
    csrr  t6, CSR_MISA
    and   t6, t6, t5
    beqz  t6, fail
    csrrw x0, CSR_DDC, s2

    csrrs s2, CSR_MEPC, x0
    YSENTRY t1, s2               /* root bounds and perms, but sealed (CT=1) */
    csrrw x0, CSR_MEPC, t1
    csrc  CSR_MISA, t5
    csrr  t6, CSR_MISA
    and   t6, t6, t5
    beqz  t6, fail
    csrrw x0, CSR_MEPC, s2

    /*
     * pcc itself must also be root. There is no CSR to overwrite it
     * directly, so derive a tightly bounded (non-root) capability from
     * the current (root) pcc and briefly make it the active pcc via a
     * capability jump (JALR in capability mode takes its new pcc from
     * cs1), then jump back using a second, unmodified root-derived
     * capability. Every instruction below is exactly 4 bytes
     * (.option norvc is in effect for the whole file), so the jump
     * offsets are simple compile-time byte counts -- annotated with the
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
    beqz  t3, fail                       /* +36 */
    jalr  x0, 44(t0)                     /* +40: pcc <- ct0 (root); jump to +44 */

    YMODESWI                             /* +44: back to int mode */

    /* Test 4: with every checked register a root capability again,
     * clearing misa.Y succeeds */
    NEXT_TEST "with all of them root again misa.Y clears"
    li   t1, MISA_Y
    csrc CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    bnez t2, fail

    /*
     * Test 5: with Y=0 the extension is gone, so its instructions and ddc
     * must read as illegal rather than as some stale value. The CSRs are
     * checked one at a time so a failure names the one at fault.
     */
    NEXT_TEST "with Y clear an RVY instruction is illegal"
    YAMASK t2, t0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "with Y clear reading ddc is illegal"
    csrrs t2, CSR_DDC, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    /*
     * The Zstid CSRs are defined by haveZstid() alone, not misa.Y
     * (sail-cheri-riscv src/cheri_csr_ext.sail:9-11), unlike ddc (:8).
     */
    NEXT_TEST "with Y clear reading mtidc still works"
    csrrs t2, CSR_MTIDC, x0
    EXPECT_NO_TRAP

    NEXT_TEST "with Y clear reading stidc still works"
    csrrs t2, CSR_STIDC, x0
    EXPECT_NO_TRAP

    NEXT_TEST "with Y clear reading utidc still works"
    csrrs t2, CSR_UTIDC, x0
    EXPECT_NO_TRAP

    /* Writes too (root pcc grants the ASR a Zstid write needs). */
    NEXT_TEST "with Y clear writing mtidc still works"
    csrw CSR_MTIDC, x0
    EXPECT_NO_TRAP

    /* Test 6: misa.Y can be set again and RVY instructions work */
    NEXT_TEST "misa.Y can be set again and RVY instructions work"
    li   t1, MISA_Y
    csrs CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    beqz t2, fail
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

    /*
     * Test 7: S-mode CHERI stays enabled because menvcfg.Y is read-only 1.
     * Golden Sail forces Y = 0b1 on every write
     * (src/cheri_sys_regs_envcfg.sail:20), and cheri_registers_enabled()
     * grants S-mode access when misa.Y and menvcfg.Y are both 1
     * (src/cheri_sys_regs.sail:41-47). So an attempt to clear it does not
     * make RVY instructions illegal in S-mode.
     */
    NEXT_TEST "S-mode CHERI stays enabled: menvcfg.Y cannot be cleared"
    li   t0, -1                  /* PMP entry 0: allow everything */
    csrw CSR_PMPADDR0, t0
    li   t0, 0x1f                /* NAPOT, RWX */
    csrw CSR_PMPCFG0, t0
    li   t1, MENVCFG_CRE
    csrc CSR_MENVCFG, t1
    csrr t0, CSR_MENVCFG
    and  t0, t0, t1
    beqz t0, fail                /* Y still reads 1 */
    li   t0, 0x1800              /* mstatus.MPP = S */
    csrc CSR_MSTATUS, t0
    li   t0, 0x0800
    csrs CSR_MSTATUS, t0
    la   t0, s_code_enabled
    csrw CSR_MEPC, t0
    la   m_continue, m_cont_b
    mv   s0, trap_count
    mret
s_code_enabled:
    YAMASK t2, t0                        /* in S-mode: works */
    ecall
m_cont_b:
    bne  trap_count, s0, fail

    TEST_PASS
fail:
    /*
     * A failed check may have left misa.Y clear, and TEST_FAIL needs RVY
     * to be enabled; csrs is a base instruction, so set it back first.
     */
    li   t5, MISA_Y
    csrs CSR_MISA, t5
    TEST_FAIL

TRAP_HANDLER

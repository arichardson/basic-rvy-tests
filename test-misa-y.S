/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY misa.Y enable/disable and Xenvcfg.CRE tests:
 *  - misa.Y is set (1) at reset
 *  - menvcfg resets to 0 and its CRE bit is bit 9 (bit 28 is not writable)
 *  - misa.Y can only be cleared while pcc, ddc, and every implemented
 *    xtvec/xepc (mtvecc/mepcc, stvecc/sepcc, vstvecc/vsepcc) are currently
 *    root capabilities; each is checked individually below
 *  - once cleared, RVY instructions and YLEN CSRs raise illegal instruction
 *  - misa.Y can be set again
 *  - S-mode CHERI enable is gated by menvcfg.CRE
 */
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* Test 1: misa.Y is set (1) at reset */
    NEXT_TEST
    csrr t0, CSR_MISA
    li   t1, MISA_Y
    and  t2, t0, t1
    beqz t2, fail

    /* Test 2: menvcfg resets to 0; CRE is bit 9; bit 28 is not writable */
    NEXT_TEST
    csrr t0, CSR_MENVCFG
    bnez t0, fail
    li   t1, MENVCFG_CRE
    csrs CSR_MENVCFG, t1
    csrr t0, CSR_MENVCFG
    bne  t1, t0, fail
    li   t2, 1 << 28             /* pre-0.9.9 CRE position */
    csrs CSR_MENVCFG, t2
    csrr t0, CSR_MENVCFG
    bne  t1, t0, fail
    csrc CSR_MENVCFG, t1         /* back to the reset value */

    /*
     * Test 3: misa.Y writes of 0 are ignored while pcc, ddc, or any
     * xtvec/xepc is not currently a root capability. Each register is
     * corrupted (replaced with the NULL capability, or -- for pcc -- a
     * tightly bounded derived capability), the clear attempt is checked
     * to fail, and the register is restored to root before moving on so
     * later checks are unaffected. Capability CSR writes need capability
     * pointer mode.
     */
    NEXT_TEST
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
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_VSTVEC, s2
    CHECK_MISA_Y_BLOCKED_WITHOUT_ROOT CSR_VSEPC, s2

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
    NEXT_TEST
    li   t1, MISA_Y
    csrc CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    bnez t2, fail

    /* Test 5: with Y=0, RVY instructions and YLEN CSRs are illegal */
    NEXT_TEST
    mv   s0, trap_count
    addi s0, s0, 1
    YAMASK t2, t0
    bne  trap_count, s0, fail
    addi s0, s0, 1
    csrrs t2, CSR_DDC, x0                /* ddc requires CRE */
    bne  trap_count, s0, fail

    /* Test 6: misa.Y can be set again and RVY instructions work */
    NEXT_TEST
    li   t1, MISA_Y
    csrs CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    beqz t2, fail
    mv   s0, trap_count
    li   t0, 0
    YAMASK t2, t0                        /* no trap expected */
    bne  trap_count, s0, fail

    /* Test 7: S-mode CHERI enable is menvcfg.CRE */
    NEXT_TEST
    li   t0, -1                  /* PMP entry 0: allow everything */
    csrw CSR_PMPADDR0, t0
    li   t0, 0x1f                /* NAPOT, RWX */
    csrw CSR_PMPCFG0, t0
    li   t1, MENVCFG_CRE
    csrc CSR_MENVCFG, t1
    li   t0, 0x1800              /* mstatus.MPP = S */
    csrc CSR_MSTATUS, t0
    li   t0, 0x0800
    csrs CSR_MSTATUS, t0
    la   t0, s_code_disabled
    csrw CSR_MEPC, t0
    la   m_continue, m_cont_a
    mv   s0, trap_count
    addi s0, s0, 1
    mret
s_code_disabled:
    YAMASK t2, t0                        /* in S-mode: illegal */
    ecall
m_cont_a:
    bne  trap_count, s0, fail
    /* enable S-mode CHERI and retry */
    li   t1, MENVCFG_CRE
    csrs CSR_MENVCFG, t1
    li   t0, 0x1800
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
    TEST_FAIL

TRAP_HANDLER

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY misa.Y enable/disable and Xenvcfg.CRE tests:
 *  - misa.Y is set at reset
 *  - menvcfg resets to 0 and its CRE bit is bit 9 (bit 28 is not writable)
 *  - misa.Y cannot be cleared while a trap vector is not a root capability
 *  - once cleared, RVY instructions and YLEN CSRs raise illegal instruction
 *  - misa.Y can be set again
 *  - S-mode CHERI enable is gated by menvcfg.CRE
 */
#include "testmacros.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAP_HANDLER

    /* Test 1: misa.Y is set at reset */
    li   s10, 1
    csrr t0, CSR_MISA
    li   t1, MISA_Y
    and  t2, t0, t1
    beqz t2, fail

    /* Test 2: menvcfg resets to 0; CRE is bit 9; bit 28 is not writable */
    li   s10, 2
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

    /* Test 3: misa.Y writes of 0 are ignored while mtvecc is not a root
     * capability. Capability CSR writes need capability pointer mode. */
    li   s10, 3
    .insn r 0x7b, 0, 0x2b, x0, x0, x0    /* ymodesw.y (to cap mode) */
    csrrw s2, CSR_MTVEC, x0      /* cs2 = root mtvecc, write NULL cap */
    li   t1, MISA_Y
    csrc CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    beqz t2, fail                /* Y must still be set */
    csrrw x0, CSR_MTVEC, s2      /* restore the root trap vector */
    .insn r 0x7b, 0, 0x2b, x0, x0, x1    /* ymodesw.i (back to int mode) */

    /* Test 4: with every checked register a root capability again,
     * clearing misa.Y succeeds */
    li   s10, 4
    csrc CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    bnez t2, fail

    /* Test 5: with Y=0, RVY instructions and YLEN CSRs are illegal */
    li   s10, 5
    mv   s0, s11
    addi s0, s0, 1
    .insn r 0x7b, 0, 0x78, t2, t0, x0    /* yamask */
    bne  s11, s0, fail
    addi s0, s0, 1
    csrrs t2, CSR_DDC, x0                /* ddc requires CRE */
    bne  s11, s0, fail

    /* Test 6: misa.Y can be set again and RVY instructions work */
    li   s10, 6
    li   t1, MISA_Y
    csrs CSR_MISA, t1
    csrr t0, CSR_MISA
    and  t2, t0, t1
    beqz t2, fail
    mv   s0, s11
    li   t0, 0
    .insn r 0x7b, 0, 0x78, t2, t0, x0    /* yamask, no trap expected */
    bne  s11, s0, fail

    /* Test 7: S-mode CHERI enable is menvcfg.CRE */
    li   s10, 7
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
    la   s9, m_cont_a
    mv   s0, s11
    addi s0, s0, 1
    mret
s_code_disabled:
    .insn r 0x7b, 0, 0x78, t2, t0, x0    /* yamask in S-mode: illegal */
    ecall
m_cont_a:
    bne  s11, s0, fail
    /* enable S-mode CHERI and retry */
    li   t1, MENVCFG_CRE
    csrs CSR_MENVCFG, t1
    li   t0, 0x1800
    csrc CSR_MSTATUS, t0
    li   t0, 0x0800
    csrs CSR_MSTATUS, t0
    la   t0, s_code_enabled
    csrw CSR_MEPC, t0
    la   s9, m_cont_b
    mv   s0, s11
    mret
s_code_enabled:
    .insn r 0x7b, 0, 0x78, t2, t0, x0    /* yamask in S-mode: works */
    ecall
m_cont_b:
    bne  s11, s0, fail

    TEST_PASS
fail:
    TEST_FAIL_S10

TRAP_HANDLER

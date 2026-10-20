/* SPDX-License-Identifier: BSD-2-Clause
 *
 * S-mode cache-block operation gating via menvcfg.{CBZE,CBCFE,CBIE}:
 *
 *  - When menvcfg.CBZE, menvcfg.CBCFE, and menvcfg.CBIE are clear (0),
 *    executing cbo.zero, cbo.clean, cbo.flush, or cbo.inval in S-mode raises
 *    an illegal-instruction exception even when the authorizing capability
 *    grants full permissions over the cache block.
 *  - Once menvcfg.CBZE, menvcfg.CBCFE, and menvcfg.CBIE are set, all four
 *    CBOs execute in S-mode without trapping.
 */
#define TEST_NAME "cbo-menvcfg"
#include "testmacros.h"
#include "exceptions.h"

#define CBOM_LEN        64
#define MENVCFG_CBO_ALL 0xf0         /* CBIE (3 << 4) | CBCFE (1 << 6) | CBZE (1 << 7) */

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY

    csrrs a0, CSR_DDC, x0
    lla   t0, buf
    YADDRW a0, a0, t0
    li   t1, CBOM_LEN
    YBNDSW a0, a0, t1

    /*
     * S-mode CBO gating via menvcfg.{CBZE,CBCFE,CBIE}: when clear (0), S-mode
     * CBOs raise illegal instruction; once set in menvcfg, S-mode CBOs
     * execute normally.
     */
    li   t1, -1
    csrw CSR_PMPADDR0, t1
    li   t1, 0x1f
    csrw CSR_PMPCFG0, t1
    li   t1, MENVCFG_CRE
    csrs CSR_MENVCFG, t1
    li   t1, MENVCFG_CBO_ALL
    csrc CSR_MENVCFG, t1

    li   t1, 0x1800
    csrc CSR_MSTATUS, t1
    li   t1, 0x0800
    csrs CSR_MSTATUS, t1
    auipc t2, 0
    lla   t1, s_cbo_disabled
    YADDRW t2, t2, t1
    csrw CSR_MEPC, t2
    lla   m_continue, s_cbo_disabled_done
    mret

s_cbo_disabled:
    NEXT_TEST "S-mode cbo.zero faults with illegal instruction when menvcfg.CBZE is clear"
    CBO_ZERO a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode cbo.clean faults with illegal instruction when menvcfg.CBCFE is clear"
    CBO_CLEAN a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode cbo.flush faults with illegal instruction when menvcfg.CBCFE is clear"
    CBO_FLUSH a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode cbo.inval faults with illegal instruction when menvcfg.CBIE is clear"
    CBO_INVAL a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    ecall

s_cbo_disabled_done:
    /* Enable CBZE, CBCFE, and CBIE in menvcfg and re-enter S-mode. */
    NEXT_TEST "menvcfg CBO enable fields are writable"
    li   t1, MENVCFG_CBO_ALL
    csrs CSR_MENVCFG, t1
    csrr t2, CSR_MENVCFG
    and  t2, t2, t1
    EXPECT_EQ t2, t1

    li   t1, 0x1800
    csrc CSR_MSTATUS, t1
    li   t1, 0x0800
    csrs CSR_MSTATUS, t1
    auipc t2, 0
    lla   t1, s_cbo_enabled
    YADDRW t2, t2, t1
    csrw CSR_MEPC, t2
    lla   m_continue, s_cbo_enabled_done
    mret

s_cbo_enabled:
    NEXT_TEST "S-mode cbo.zero succeeds once menvcfg.CBZE is set"
    CBO_ZERO a0
    EXPECT_NO_TRAP

    NEXT_TEST "S-mode cbo.clean succeeds once menvcfg.CBCFE is set"
    CBO_CLEAN a0
    EXPECT_NO_TRAP

    NEXT_TEST "S-mode cbo.flush succeeds once menvcfg.CBCFE is set"
    CBO_FLUSH a0
    EXPECT_NO_TRAP

    NEXT_TEST "S-mode cbo.inval succeeds once menvcfg.CBIE is set"
    CBO_INVAL a0
    EXPECT_NO_TRAP
    ecall

s_cbo_enabled_done:
    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    lla   m_continue, m_fail
    ecall
m_fail:
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space CBOM_LEN

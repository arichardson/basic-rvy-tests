/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify capability CSR read/write semantics across CSR instructions,
 * execution modes, ASR permissions, and privilege levels:
 *
 *  - In Capability Mode, CSRRW writes the full YLEN capability from cs1 and
 *    reads the full YLEN capability into cd (including when cd == cs1), while
 *    CSRRS and CSRRC with rs1=x0 and CSRRSI and CSRRCI with uimm=0 read the
 *    full YLEN capability without modifying the CSR.
 *  - In Capability Mode, CSRRS and CSRRC with rs1!=x0, CSRRSI and CSRRCI with
 *    uimm!=0, and CSRRWI (even with uimm=0) return the old full YLEN
 *    capability in cd and perform an XLEN address update on the capability
 *    already in the CSR, preserving its tag and bounds when unsealed and
 *    representable and clearing the tag when the CSR holds a sealed sentry.
 *  - In Integer Mode, reading an extended capability CSR (mscratch, sscratch,
 *    mepc, sepc, mtvec, stvec) returns only the XLEN integer address in rd
 *    (untagged), whereas reading ddc (and utidc/stidc/mtidc on RVY v0.9.9,
 *    which adds them as YLEN-wide CSRs rather than extending XLEN CSRs)
 *    returns the full YLEN capability in both execution modes; writing any
 *    capability CSR in Integer Mode updates only the cursor of the CSR's
 *    existing capability.
 *  - The thread ID capability CSRs (utidc, stidc, mtidc) are readable without
 *    ASR in PCC (via rs1=x0 or uimm=0) and require ASR for any write (including
 *    CSRRWI with uimm=0).
 *  - In S-mode with menvcfg.CRE=1 and ASR granted in PCC, S-mode and U-mode
 *    capability CSRs (sscratch, sepc, stvec, stidc, utidc, ddc) are accessible
 *    while M-mode capability CSRs (mscratch, mepc, mtvec, mtidc) fault with an
 *    illegal-instruction exception.
 */
#define TEST_NAME "cap-csrs"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs s0, CSR_DDC, x0        /* save root DDC */
    la    s1, buf
    YADDRW a0, s0, s1
    li    t0, 64
    YBNDSW a0, a0, t0            /* a0: tagged capability [buf, buf + 64) */
    YSENTRY a1, a0               /* a1: sealed sentry at buf */

    /* =====================================================================
     * Capability Mode: CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI
     * ===================================================================== */
    YMODESWY

    NEXT_TEST "capability-mode csrrw round-trips full capabilities through mscratch and sscratch"
    csrrw x0, CSR_MSCRATCH, a0
    csrrw x0, CSR_SSCRATCH, a1
    csrrs t1, CSR_MSCRATCH, x0
    csrrs t2, CSR_SSCRATCH, x0
    EXPECT_NO_TRAP
    YEQ   t3, t1, a0
    beqz  t3, fail
    YEQ   t3, t2, a1
    beqz  t3, fail

    NEXT_TEST "capability-mode csrrw with cd == cs1 atomically swaps register and CSR"
    csrrw x0, CSR_MSCRATCH, a0
    YMV   t1, a1
    csrrw t1, CSR_MSCRATCH, t1
    EXPECT_NO_TRAP
    YEQ   t2, t1, a0             /* t1 received the old CSR value (a0) */
    beqz  t2, fail
    csrrs t3, CSR_MSCRATCH, x0
    YEQ   t2, t3, a1             /* CSR received the old t1 value (a1) */
    beqz  t2, fail

    NEXT_TEST "capability-mode csrrw round-trips full capabilities through utidc, stidc, and mtidc"
    csrrw x0, CSR_UTIDC, a0
    csrrw x0, CSR_STIDC, a1
    csrrw x0, CSR_MTIDC, a0
    csrrs t1, CSR_UTIDC, x0
    csrrs t2, CSR_STIDC, x0
    csrrs t3, CSR_MTIDC, x0
    EXPECT_NO_TRAP
    YEQ   t4, t1, a0
    beqz  t4, fail
    YEQ   t4, t2, a1
    beqz  t4, fail
    YEQ   t4, t3, a0
    beqz  t4, fail

    NEXT_TEST "capability-mode csrrs, csrrc, csrrsi, and csrrci with zero operand do not write"
    csrrw x0, CSR_MSCRATCH, a1   /* place sealed sentry a1 in mscratch */
    csrrs t1, CSR_MSCRATCH, x0
    csrrc t2, CSR_MSCRATCH, x0
    csrrsi t3, CSR_MSCRATCH, 0
    csrrci t4, CSR_MSCRATCH, 0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a1
    beqz  t0, fail
    YEQ   t0, t2, a1
    beqz  t0, fail
    YEQ   t0, t3, a1
    beqz  t0, fail
    YEQ   t0, t4, a1
    beqz  t0, fail

    NEXT_TEST "capability-mode csrrs and csrrc with rs1 != x0 update the CSR cursor and keep bounds"
    csrrw x0, CSR_MSCRATCH, a0   /* [buf, buf + 64) at cursor buf (64-byte aligned) */
    li    t0, 0x18               /* untagged integer register with low bits 0x18 */
    csrrs t1, CSR_MSCRATCH, t0   /* t1 = old a0; mscratch.addr = buf | 0x18 */
    li    t2, 0x08
    csrrc t3, CSR_MSCRATCH, t2   /* t3 = buf | 0x18; mscratch.addr = buf | 0x10 */
    csrrs t4, CSR_MSCRATCH, x0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a0
    beqz  t0, fail
    YTAGR t0, t3
    beqz  t0, fail
    addi  t0, s1, 0x18
    bne   t3, t0, fail
    YTAGR t0, t4
    beqz  t0, fail
    YLENR t0, t4
    li    t2, 64
    bne   t2, t0, fail
    addi  t0, s1, 0x10
    bne   t4, t0, fail

    NEXT_TEST "capability-mode csrrs and csrrc with rs1 != x0 detag a sealed sentry in the CSR"
    csrrw x0, CSR_MSCRATCH, a1   /* sealed sentry at buf */
    li    t0, 4
    csrrs t1, CSR_MSCRATCH, t0
    csrrs t2, CSR_MSCRATCH, x0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a1             /* returned the old tagged sentry */
    beqz  t0, fail
    YTAGR t0, t2
    bnez  t0, fail               /* CSR was detagged by the XLEN cursor write */
    csrrw x0, CSR_MSCRATCH, a1
    li    t0, 4
    csrrc t1, CSR_MSCRATCH, t0
    csrrs t2, CSR_MSCRATCH, x0
    YEQ   t0, t1, a1
    beqz  t0, fail
    YTAGR t0, t2
    bnez  t0, fail

    NEXT_TEST "capability-mode csrrsi and csrrci with uimm != 0 update the CSR cursor and keep bounds"
    csrrw x0, CSR_SSCRATCH, a0   /* [buf, buf + 64) at cursor buf */
    csrrsi t1, CSR_SSCRATCH, 0x1c
    csrrci t2, CSR_SSCRATCH, 0x04
    csrrs t3, CSR_SSCRATCH, x0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a0
    beqz  t0, fail
    YTAGR t0, t2
    beqz  t0, fail
    addi  t0, s1, 0x1c
    bne   t2, t0, fail
    YTAGR t0, t3
    beqz  t0, fail
    YLENR t0, t3
    li    t4, 64
    bne   t4, t0, fail
    addi  t0, s1, 0x18
    bne   t3, t0, fail

    NEXT_TEST "capability-mode csrrwi writes an XLEN immediate to the CSR cursor even for uimm == 0"
    csrrw x0, CSR_MSCRATCH, s0   /* root capability in mscratch */
    csrrwi t1, CSR_MSCRATCH, 27  /* mscratch.addr = 27, tag and root bounds kept */
    csrrs t2, CSR_MSCRATCH, x0
    EXPECT_NO_TRAP
    YEQ   t0, t1, s0
    beqz  t0, fail
    YTAGR t0, t2
    beqz  t0, fail
    li    t0, 27
    bne   t2, t0, fail
    /* On a sealed sentry, even csrrwi with uimm == 0 performs a write and detags it. */
    csrrw x0, CSR_MSCRATCH, a1
    csrrwi t1, CSR_MSCRATCH, 0
    csrrs t2, CSR_MSCRATCH, x0
    YEQ   t0, t1, a1
    beqz  t0, fail
    YTAGR t0, t2
    bnez  t0, fail
    bnez  t2, fail

    /* =====================================================================
     * Integer Mode: extended capability CSRs vs DDC and *tidc
     * ===================================================================== */
    csrrw x0, CSR_MSCRATCH, a0
    csrrw x0, CSR_SSCRATCH, a0
    csrrw x0, CSR_MEPC, a0
    csrrw x0, CSR_SEPC, a0
    csrrw x0, CSR_UTIDC, a0
    csrrw x0, CSR_STIDC, a0
    csrrw x0, CSR_MTIDC, a0
    csrrw x0, CSR_DDC, a0
    YMODESWI

    NEXT_TEST "integer-mode reads of extended capability CSRs return untagged XLEN integers"
    csrrs t1, CSR_MSCRATCH, x0
    csrrc t2, CSR_SSCRATCH, x0
    csrrsi t3, CSR_MEPC, 0
    csrrci t4, CSR_SEPC, 0
    EXPECT_NO_TRAP
    bne   t1, s1, fail
    bne   t2, s1, fail
    bne   t3, s1, fail
    bne   t4, s1, fail
    YTAGR t0, t1
    bnez  t0, fail
    YTAGR t0, t2
    bnez  t0, fail
    YTAGR t0, t3
    bnez  t0, fail
    YTAGR t0, t4
    bnez  t0, fail

    NEXT_TEST "integer-mode reads of ddc return the full YLEN capability"
    csrrs t1, CSR_DDC, x0
    csrrc t2, CSR_DDC, x0
    csrrsi t3, CSR_DDC, 0
    csrrci t4, CSR_DDC, 0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a0
    beqz  t0, fail
    YEQ   t0, t2, a0
    beqz  t0, fail
    YEQ   t0, t3, a0
    beqz  t0, fail
    YEQ   t0, t4, a0
    beqz  t0, fail

    NEXT_TEST "integer-mode reads of utidc, stidc, and mtidc return YLEN on RVY and XLEN on 0.9.3"
    csrrs t1, CSR_UTIDC, x0
    csrrc t2, CSR_STIDC, x0
    csrrsi t3, CSR_MTIDC, 0
    EXPECT_NO_TRAP
#ifdef CHERI_093
    bne   t1, s1, fail
    bne   t2, s1, fail
    bne   t3, s1, fail
    YTAGR t0, t1
    bnez  t0, fail
    YTAGR t0, t2
    bnez  t0, fail
    YTAGR t0, t3
    bnez  t0, fail
#else
    YEQ   t0, t1, a0
    beqz  t0, fail
    YEQ   t0, t2, a0
    beqz  t0, fail
    YEQ   t0, t3, a0
    beqz  t0, fail
#endif

    NEXT_TEST "integer-mode csrrw, csrrs, and csrrc update the CSR cursor while preserving tag and bounds"
    addi  t0, s1, 8
    csrrw t1, CSR_MSCRATCH, t0   /* XLEN write: sets cursor to buf + 8 */
    li    t2, 0x10
    csrrs t3, CSR_MSCRATCH, t2   /* sets cursor to buf + 0x18 */
    li    t2, 0x08
    csrrc t4, CSR_MSCRATCH, t2   /* sets cursor to buf + 0x10 */
    EXPECT_NO_TRAP
    bne   t1, s1, fail
    YTAGR t0, t1
    bnez  t0, fail               /* integer-mode read still returned untagged XLEN */
    YMODESWY
    csrrs t1, CSR_MSCRATCH, x0
    YMODESWI
    YTAGR t0, t1
    beqz  t0, fail               /* tag in CSR was preserved across integer-mode writes */
    YLENR t0, t1
    li    t2, 64
    bne   t0, t2, fail
    addi  t0, s1, 0x10
    bne   t1, t0, fail

    /* Restore root DDC before the ASR and S-mode tests. */
    YMODESWY
    csrrw x0, CSR_DDC, s0

    /* =====================================================================
     * Thread ID capability CSRs (utidc, stidc, mtidc) without ASR in PCC
     * ===================================================================== */
    NEXT_TEST "utidc, stidc, and mtidc are readable without ASR but fault on any write"
    csrrw x0, CSR_UTIDC, a0
    csrrw x0, CSR_STIDC, a0
    csrrw x0, CSR_MTIDC, a0
    auipc a2, 0
    la    t0, tidc_no_asr_stub
    YADDRW a2, a2, t0
    li    t1, DROP_MASK(PERM_ASR)
    DROP_PERMS a2, a2, t1
    jalr  ra, a2, 0
    EXPECT_NO_TRAP

    /* =====================================================================
     * S-mode capability CSR privilege checks (with ASR granted and CRE=1)
     * ===================================================================== */
    li    t0, -1                 /* PMP entry 0: allow all physical memory in S-mode */
    csrw  CSR_PMPADDR0, t0
    li    t0, 0x1f               /* NAPOT, RWX */
    csrw  CSR_PMPCFG0, t0
    li    t0, MENVCFG_CRE
    csrs  CSR_MENVCFG, t0        /* enable S-mode CHERI */

    csrrw x0, CSR_SSCRATCH, x0
    csrrw x0, CSR_STIDC, x0
    csrrw x0, CSR_UTIDC, x0
    csrrw x0, CSR_MSCRATCH, a0
    csrrw x0, CSR_MTIDC, a0

    li    t0, 0x1800             /* mstatus.MPP = S */
    csrc  CSR_MSTATUS, t0
    li    t0, 0x0800
    csrs  CSR_MSTATUS, t0
    auipc t1, 0
    la    t0, s_mode_csr_tests
    YADDRW t1, t1, t0
    csrrw x0, CSR_MEPC, t1
    la    m_continue, s_mode_done
    li    s2, 0
    mret

s_mode_csr_tests:
    NEXT_TEST "S-mode with ASR can read and write sscratch, stidc, utidc, and ddc"
    csrrw x0, CSR_SSCRATCH, a0
    csrrw x0, CSR_STIDC, a1
    csrrw x0, CSR_UTIDC, a0
    csrrs t1, CSR_SSCRATCH, x0
    csrrs t2, CSR_STIDC, x0
    csrrs t3, CSR_UTIDC, x0
    csrrs t4, CSR_DDC, x0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a0
    beqz  t0, s_fail
    YEQ   t0, t2, a1
    beqz  t0, s_fail
    YEQ   t0, t3, a0
    beqz  t0, s_fail
    YEQ   t0, t4, s0
    beqz  t0, s_fail

    NEXT_TEST "S-mode reading mscratch faults with illegal instruction even with ASR"
    csrrs t1, CSR_MSCRATCH, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode writing mscratch faults with illegal instruction even with ASR"
    csrrw x0, CSR_MSCRATCH, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode reading mtidc faults with illegal instruction even with ASR"
    csrrs t1, CSR_MTIDC, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode writing mtidc faults with illegal instruction even with ASR"
    csrrw x0, CSR_MTIDC, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "S-mode reading mepc and mtvec faults with illegal instruction even with ASR"
    csrrs t1, CSR_MEPC, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    csrrs t1, CSR_MTVEC, x0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    ecall

s_fail:
    li    s2, 1
    ecall

s_mode_done:
    bnez  s2, fail

    /* Verify S-mode failed writes did not corrupt M-mode CSRs. */
    NEXT_TEST "failed S-mode writes leave mscratch and mtidc unmodified"
    csrrs t1, CSR_MSCRATCH, x0
    csrrs t2, CSR_MTIDC, x0
    EXPECT_NO_TRAP
    YEQ   t0, t1, a0
    beqz  t0, fail
    YEQ   t0, t2, a0
    beqz  t0, fail

    YMODESWI
    csrrw x0, CSR_DDC, s0
    TEST_PASS
fail:
    YMODESWI
    csrrw x0, CSR_DDC, s0
    TEST_FAIL

/*
 * Entered in Capability Mode with a PCC that has PERM_ASR cleared.
 */
.balign 8
tidc_no_asr_stub:
    /* Reading utidc, stidc, and mtidc with rs1=x0 or uimm=0 needs no ASR. */
    csrrs  t1, CSR_UTIDC, x0
    csrrc  t2, CSR_STIDC, x0
    csrrsi t3, CSR_MTIDC, 0
    csrrci t4, CSR_UTIDC, 0
    EXPECT_NO_TRAP
    YEQ    t0, t1, a0
    beqz   t0, fail
    YEQ    t0, t2, a0
    beqz   t0, fail
    YEQ    t0, t3, a0
    beqz   t0, fail
    YEQ    t0, t4, a0
    beqz   t0, fail

    /* Any write to utidc, stidc, or mtidc without ASR must fault. */
    NEXT_TEST "writing utidc without ASR faults with TRAP_ASR_DENIED"
    csrrw  x0, CSR_UTIDC, x0
    EXPECT_TRAP TRAP_ASR_DENIED

    NEXT_TEST "writing stidc without ASR faults with TRAP_ASR_DENIED"
    csrrs  x0, CSR_STIDC, s1
    EXPECT_TRAP TRAP_ASR_DENIED

    NEXT_TEST "writing mtidc via csrrwi with uimm == 0 without ASR faults with TRAP_ASR_DENIED"
    csrrwi x0, CSR_MTIDC, 0
    EXPECT_TRAP TRAP_ASR_DENIED

    NEXT_TEST "writing utidc via csrrsi with uimm != 0 without ASR faults with TRAP_ASR_DENIED"
    csrrsi x0, CSR_UTIDC, 1
    EXPECT_TRAP TRAP_ASR_DENIED

    NEXT_TEST "writing utidc via csrrci with uimm != 0 without ASR faults with TRAP_ASR_DENIED"
    csrrci x0, CSR_UTIDC, 1
    EXPECT_TRAP TRAP_ASR_DENIED

    ret

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 64

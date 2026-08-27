/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Shared exception-checking machinery for the bare-metal RVY tests.
 *
 * A test installs a handler with SETUP_TRAPS, runs an operation that should
 * (or should not) fault, and states what it expects:
 *
 *     EXPECT_NO_TRAP                       nothing faulted
 *     EXPECT_TRAP cause[, tval2]           exactly one trap, with this cause
 *     EXPECT_EPC reg                       ... reported against this address
 *     EXPECT_EPC_TAG tag                   ... with a PCC of this tag
 *
 * EXPECT_TRAP consumes the trap, so each operation under test is followed by
 * exactly one of it or EXPECT_NO_TRAP. EXPECT_EPC and EXPECT_EPC_TAG read the
 * recorded state and may follow in any order.
 *
 * Tests number themselves with NEXT_TEST rather than a literal, so inserting
 * a case does not renumber the ones after it. The id is what a failure
 * reports as the exit code, so it is also how to find the failing case:
 * count NEXT_TEST from the top.
 *
 * Two handlers are provided, and a test places exactly one of them:
 *
 *   TRAP_HANDLER      records the cause (and mtval2 on 0.9.3), then steps
 *                     over the faulting four-byte instruction. Uses no RVY
 *                     instructions, so it also works for tests that turn
 *                     CHERI off.
 *   TRAP_HANDLER_PCC  additionally records the tag of the capability left in
 *                     mepc and supports RESUME_AFTER_FAULT, for tests where
 *                     PCC itself is what faulted and stepping over the
 *                     instruction would just fault again.
 *
 * Both return to M-mode at m_continue on an ecall from S-mode; that is a
 * test's way back out of S-mode rather than a fault, so it is not counted.
 *
 * Reserved registers: the raw names of these and of test_id/trap_count are
 * poisoned at the end of this header, so a test cannot quietly reuse one for
 * something else. Tests have s0, s1, s2, s7, a0-a7 and t0-t4 to themselves;
 * t5/t6 are handler scratch.
 */
#pragma once

/* Standard RISC-V causes. */
#define CAUSE_ILLEGAL_INSN         2
#define CAUSE_LOAD_ACCESS_FAULT    5
#define CAUSE_STORE_ACCESS_FAULT   7
#define CAUSE_S_ECALL              9
#define CAUSE_LOAD_PAGE_FAULT     13

#ifdef CHERI_093
/* 0.9.3 reports every capability fault as one cause, detailed in xtval2. */
#define CAUSE_CHERI_ANY         0x1c
#else
#define CAUSE_CHERI_INST          32
#define CAUSE_CHERI_LOAD          33
#define CAUSE_CHERI_STORE         34
#define CAUSE_CHERI_LOAD_CAP      35
#define CAUSE_CHERI_STORE_PAGE    36
#endif

/* State maintained by the handlers. */
#define trap_cause    s4         /* mcause of the most recent trap */
#define trap_epc_tag  s5         /* tag of the capability left in mepc */
#define trap_epc      s6         /* mepc of the most recent trap */
#define trap_tval2    s3         /* mtval2 of the most recent trap (0.9.3) */
#define resume_at     s8         /* recovery point, see RESUME_AFTER_FAULT */
#define m_continue    s9         /* where an ecall from S-mode returns to */

.macro SETUP_TRAPS
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   test_id, 0
    li   trap_cause, 0
    li   trap_epc, 0
    li   trap_epc_tag, 0
    li   trap_tval2, 0
    li   resume_at, 0
    li   m_continue, 0
    li   trap_count, 0
.endm

/* Start the next case; a failure from here on reports this id. */
.macro NEXT_TEST
    addi test_id, test_id, 1
.endm

/* Forget any traps taken so far; the next EXPECT_TRAP starts from zero. */
.macro CLEAR_TRAPS
    li   trap_count, 0
.endm

/*
 * The next fault leaves PCC unusable, so resume at \label with a capability
 * derived from mtvecc instead of stepping over the faulting instruction.
 * Requires TRAP_HANDLER_PCC.
 */
.macro RESUME_AFTER_FAULT label
    la   resume_at, \label
__rvy_used_resume_after_fault = 1
.endm

.macro EXPECT_NO_TRAP
    bnez trap_count, fail
.endm

/*
 * Exactly one trap since the last expectation, reporting \cause. \tval2 is
 * only checked in 0.9.3 builds, where the capability cause and access type
 * live there rather than in mcause.
 */
.macro EXPECT_TRAP cause, tval2=0
    li   t3, 1
    bne  t3, trap_count, fail
    li   t3, \cause
    bne  t3, trap_cause, fail
#ifdef CHERI_093
    li   t3, \tval2
    bne  t3, trap_tval2, fail
#endif
    CLEAR_TRAPS
.endm

/* The trap was reported against the address in \reg. */
.macro EXPECT_EPC reg
    bne  trap_epc, \reg, fail
.endm

/* ... and the capability left in mepc had this tag (TRAP_HANDLER_PCC only). */
.macro EXPECT_EPC_TAG tag
    li   t3, \tag
    bne  t3, trap_epc_tag, fail
.endm

/* Shared prologue: record the trap, letting an S-mode ecall back to M-mode. */
.macro TRAP_RECORD_AND_LET_ECALL_THROUGH
    csrr trap_cause, CSR_MCAUSE
#ifdef CHERI_093
    csrr trap_tval2, CSR_MTVAL2
#endif
    li   t5, CAUSE_S_ECALL
    bne  t5, trap_cause, 8f
    li   t5, 0x1800              /* mstatus.MPP = M */
    csrs CSR_MSTATUS, t5
    csrw CSR_MEPC, m_continue
    mret
8:
    addi trap_count, trap_count, 1
    csrr trap_epc, CSR_MEPC
.endm

/*
 * Plain handler: no RVY instructions, so it keeps working for tests that
 * clear misa.Y. Writing an address to mepc leaves the rest of the capability
 * alone, so execution resumes in the mode that faulted.
 */
.macro TRAP_HANDLER
    .ifdef __rvy_used_resume_after_fault
      .error "RESUME_AFTER_FAULT needs TRAP_HANDLER_PCC, not TRAP_HANDLER"
    .endif
    .balign 4
trap_handler:
    TRAP_RECORD_AND_LET_ECALL_THROUGH
    addi t6, trap_epc, 4         /* step over the faulting instruction */
    csrw CSR_MEPC, t6
    mret
.endm

/*
 * Capability-aware handler, for tests where PCC itself faults: it records the
 * tag of the capability in mepc and honours RESUME_AFTER_FAULT, entering the
 * recovery point with a fresh PCC derived from mtvecc and the mode the
 * faulting code was running in.
 */
.macro TRAP_HANDLER_PCC
    .balign 4
trap_handler:
    TRAP_RECORD_AND_LET_ECALL_THROUGH
    YMODESWY                     /* so the xepc CSRs read back as capabilities */
    csrr trap_epc, CSR_MEPC
    YTAGR trap_epc_tag, trap_epc
    YMODER t5, trap_epc          /* resume in the mode that faulted */
    beqz resume_at, 9f
    csrr t6, CSR_MTVEC
    YADDRW t6, t6, resume_at
    li   resume_at, 0
    YMODEW t6, t6, t5
    csrw CSR_MEPC, t6
    mret
9:
    YADDI t6, trap_epc, 4        /* step over the faulting instruction */
    csrw CSR_MEPC, t6
    mret
.endm

/*
 * Everything above refers to the reserved registers by name, so from here on
 * the raw names are errors: a test that wants a scratch register has to pick
 * one that is not spoken for.
 */
#pragma GCC poison s3 s4 s5 s6 s8 s9 s10 s11

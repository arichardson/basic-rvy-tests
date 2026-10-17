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
 *     EXPECT_TVAL reg                      ... with this fault address in mtval
 *     EXPECT_EPC_TAG tag                   ... with a PCC of this tag
 *     EXPECT_TAG reg, tag                  capability in reg carries tag
 *     EXPECT_EQ r1, r2                     r1 == r2
 *     EXPECT_NE r1, r2                     r1 != r2
 *     EXPECT_ZERO reg                      reg == 0
 *     EXPECT_NONZERO reg                   reg != 0
 *
 * EXPECT_* checks record a failure for the current NEXT_TEST case (via
 * console_fail) and continue running so later cases still execute. Each has
 * a fatal ASSERT_* counterpart (ASSERT_NO_TRAP, ASSERT_TRAP, ASSERT_EQ, ...)
 * that branches to fail and stops the test immediately when subsequent cases
 * cannot safely run after a failure.
 *
 * EXPECT_TRAP and EXPECT_NO_TRAP consume trap_count, so each operation under
 * test is followed by one of them. EXPECT_EPC, EXPECT_TVAL and EXPECT_EPC_TAG
 * read the recorded state and may follow in any order.
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
#define CAUSE_MISALIGNED_FETCH     0
#define CAUSE_ILLEGAL_INSN         2
#define CAUSE_LOAD_ACCESS_FAULT    5
#define CAUSE_STORE_ACCESS_FAULT   7
#define CAUSE_S_ECALL              9
#define CAUSE_LOAD_PAGE_FAULT     13
#define CAUSE_STORE_PAGE_FAULT    15

/*
 * The kind of capability check that failed. RVY does not report it, but 0.9.3
 * puts it in xtval2, so tests name it either way and it is simply ignored on
 * RVY. The numbers are the 0.9.3 encoding.
 */
#define CAP_TAG                    0
#define CAP_SEAL                   1
#define CAP_PERM                   2
#define CAP_BOUNDS                 4

#ifdef CHERI_093
/*
 * 0.9.3 reports every capability fault as one cause and splits it by the
 * check that failed, in xtval2 together with the access type. RVY instead
 * gives each access type its own cause and does not report the check, so
 * expectations are written as TRAP_CAP_<access>(<check>) and each version
 * keeps the half it can see.
 */
#define CAUSE_CHERI_ANY         0x1c
#define CAP093_TYPE_INSN           0
#define CAP093_TYPE_DATA           1
#define CAP093_TYPE_BRANCH         2
#define TRAP_CAP_FETCH(check)   CAUSE_CHERI_ANY, ((check) | (CAP093_TYPE_INSN << 16))
#define TRAP_CAP_LOAD(check)    CAUSE_CHERI_ANY, ((check) | (CAP093_TYPE_DATA << 16))
#define TRAP_CAP_STORE(check)   CAUSE_CHERI_ANY, ((check) | (CAP093_TYPE_DATA << 16))
#define TRAP_CAP_BRANCH(check)  CAUSE_CHERI_ANY, ((check) | (CAP093_TYPE_BRANCH << 16))
/* 0.9.3 reports misaligned capability accesses as misaligned, not access, faults. */
#define CAUSE_CAP_MISALIGNED_LOAD  4
#define CAUSE_CAP_MISALIGNED_STORE 6
/* A missing ASR is a permission violation on the instruction fetch here. */
#define TRAP_ASR_DENIED         TRAP_CAP_FETCH(CAP_PERM)
#else
#define CAUSE_CHERI_INST          32
#define CAUSE_CHERI_LOAD          33
#define CAUSE_CHERI_STORE         34
#define CAUSE_CHERI_LOAD_CAP      35
#define CAUSE_CHERI_STORE_PAGE    36
#define TRAP_CAP_FETCH(check)   CAUSE_CHERI_INST
#define TRAP_CAP_LOAD(check)    CAUSE_CHERI_LOAD
#define TRAP_CAP_STORE(check)   CAUSE_CHERI_STORE
#define TRAP_CAP_BRANCH(check)  CAUSE_CHERI_INST
#define CAUSE_CAP_MISALIGNED_LOAD  CAUSE_LOAD_ACCESS_FAULT
#define CAUSE_CAP_MISALIGNED_STORE CAUSE_STORE_ACCESS_FAULT
/* RVY reports a missing ASR as an illegal instruction instead. */
#define TRAP_ASR_DENIED         CAUSE_ILLEGAL_INSN
#endif

/* State maintained by the handlers. */
#define trap_cause    s4         /* mcause of the most recent trap */
#define trap_epc_tag  s5         /* tag of the capability left in mepc */
#define trap_epc      s6         /* mepc of the most recent trap */
#define trap_tval2    s3         /* mtval2 of the most recent trap (0.9.3) */
#define resume_at     s8         /* recovery point, see RESUME_AFTER_FAULT */
#define m_continue    s9         /* where an ecall from S-mode returns to */

#include "target-info.h"

.macro SETUP_TRAPS
    ENABLE_CHERI
    call console_init            /* probes UART and target_info; needs its own handler */
    lla   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   trap_cause, 0
    li   trap_epc, 0
    li   trap_epc_tag, 0
    li   trap_tval2, 0
    li   resume_at, 0
    li   m_continue, 0
    li   trap_count, 0
.endm

/* Cases counted so far, at assembly time; see SKIPPABLE_BLOCK_BEGIN. */
.set __tap_cases, 0

/*
 * Start the next case; a failure from here on reports this id. \desc is what
 * the TAP stream calls the case, and is emitted into a table the linker keeps
 * in source order rather than being printed here: printing would mean
 * clobbering the argument registers, and tests set those up before NEXT_TEST
 * as often as after.
 *
 * test_id is loaded with the case's own source-order number rather than being
 * counted up at run time, so it names the same case whatever ran before it and
 * always indexes the right table entry. A counter would drift the moment a
 * case was skipped, and the names after it would then be wrong rather than
 * missing, which is not something the reader could spot.
 */
.macro NEXT_TEST desc=
    .set __tap_cases, __tap_cases + 1
    .if __tap_cases >= TAP_MAX_CASES
      .error "TAP_MAX_CASES exceeded"
    .endif
    li   test_id, __tap_cases
    .pushsection .rodata
.Ltap_name_\@: .asciz "\desc"   /* the quotes go here: the assembler strips the caller's */
    .popsection
    .pushsection .tapnames, "a"
    WORD_X .Ltap_name_\@
    .popsection
.endm

/*
 * A block of cases that only some machines can run at all. Bracket it with
 * these so the ones that cannot still appear, as TAP skips, rather than
 * vanishing: the case numbers and the plan then mean the same thing wherever
 * the suite runs, and the reason is reported rather than left to be guessed.
 *
 *     SKIPPABLE_BLOCK_BEGIN
 *     TRY_CLEAR_MISA_C 1f
 *     ... cases ...
 *     j 2f
 * 1:  SKIPPABLE_BLOCK_SKIPPED "why not here"
 * 2:
 *
 * The counting is done by the assembler, so the block does not have to say
 * how many cases it holds and cannot fall out of step with itself.
 */
.macro SKIPPABLE_BLOCK_BEGIN
    .set __tap_skip_from, __tap_cases + 1
.endm

.macro SKIPPABLE_BLOCK_SKIPPED reason
    .pushsection .rodata
.Lskip_str_\@: .asciz "\reason"
    .popsection
    lla   a0, .Lskip_str_\@
    li   a1, __tap_skip_from
    li   a2, __tap_cases
    call console_skip
.endm

/*
 * Mark the current case as an expected failure (TAP # TODO). Used when an
 * implementation has a known bug that the test can detect and recover from
 * without aborting the remaining cases. Clobbers a0-a1 and t0-t4.
 */
.macro MARK_XFAIL reason
    .pushsection .rodata
.Lxfail_str_\@: .asciz "\reason"
    .popsection
    lla   a0, .Lxfail_str_\@
    mv   a1, test_id
    call console_xfail
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
    lla   resume_at, \label
__rvy_used_resume_after_fault = 1
.endm

.macro EXPECT_FAIL
    YMV  t5, ra
    YMV  t6, a0
    YMV  trap_tval2, t0
    mv   a0, test_id
    call console_fail
    YMV  t0, trap_tval2
    YMV  a0, t6
    YMV  ra, t5
.endm

.macro ASSERT_FAIL
    j    fail
.endm

.macro EXPECT_NO_TRAP
    beqz trap_count, .Lexpect_ok_\@
    EXPECT_FAIL
    CLEAR_TRAPS
.Lexpect_ok_\@:
.endm

.macro ASSERT_NO_TRAP
    bnez trap_count, fail
.endm

/*
 * Exactly one trap since the last expectation, reporting \cause. \tval2 is
 * only checked in 0.9.3 builds, where the capability cause and access type
 * live there rather than in mcause.
 */
.macro EXPECT_TRAP cause, tval2=0
    li   t5, 1
    bne  t5, trap_count, .Lexpect_fail_\@
    li   t5, \cause
    bne  t5, trap_cause, .Lexpect_fail_\@
#ifdef CHERI_093
    li   t5, \tval2
    bne  t5, trap_tval2, .Lexpect_fail_\@
#endif
    j    .Lexpect_ok_\@
.Lexpect_fail_\@:
    EXPECT_FAIL
.Lexpect_ok_\@:
    CLEAR_TRAPS
.endm

.macro ASSERT_TRAP cause, tval2=0
    li   t5, 1
    bne  t5, trap_count, fail
    li   t5, \cause
    bne  t5, trap_cause, fail
#ifdef CHERI_093
    li   t5, \tval2
    bne  t5, trap_tval2, fail
#endif
    CLEAR_TRAPS
.endm

/*
 * The operation was not rejected: it either completed or faulted only over
 * where it touched memory, which is a property of the machine rather than of
 * the architecture. A CHERI fault means it was refused on capability grounds
 * and an illegal instruction means it never executed at all, so this is an
 * allow-list of the two access faults rather than a list of what to reject.
 */
.macro EXPECT_ONLY_MEMORY_FAULT
    beqz trap_count, .Lexpect_ok_\@
    li   t5, 1
    bne  t5, trap_count, .Lexpect_fail_\@
    li   t5, CAUSE_LOAD_ACCESS_FAULT
    beq  t5, trap_cause, .Lexpect_ok_\@
    li   t5, CAUSE_STORE_ACCESS_FAULT
    beq  t5, trap_cause, .Lexpect_ok_\@
.Lexpect_fail_\@:
    EXPECT_FAIL
.Lexpect_ok_\@:
    CLEAR_TRAPS
.endm

.macro ASSERT_ONLY_MEMORY_FAULT
    beqz trap_count, .Lexpect_ok_\@
    li   t5, 1
    bne  t5, trap_count, fail
    li   t5, CAUSE_LOAD_ACCESS_FAULT
    beq  t5, trap_cause, .Lexpect_ok_\@
    li   t5, CAUSE_STORE_ACCESS_FAULT
    beq  t5, trap_cause, .Lexpect_ok_\@
    j    fail
.Lexpect_ok_\@:
    CLEAR_TRAPS
.endm

/*
 * Whether misa.C can be cleared at all is implementation-defined (WARL): the
 * base ISA permits a hart to hard-wire it. Attempt the write, and skip to
 * \label if it did not take, rather than assuming either outcome.
 */
.macro TRY_CLEAR_MISA_C label
    csrr t5, CSR_MISA
    li   t6, MISA_C
    not  t6, t6
    and  t5, t5, t6
    csrw CSR_MISA, t5
    csrr t5, CSR_MISA
    andi t5, t5, MISA_C
    bnez t5, \label
.endm

/* The trap was reported against the address in \reg. */
.macro EXPECT_EPC reg
    sub  t5, trap_epc, \reg
    beqz t5, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_EPC reg
    sub  t5, trap_epc, \reg
    bnez t5, fail
.endm

/*
 * ... with this fault address in mtval (on 0.9.3 QEMU only populates mtval2
 * for CAUSE_CHERI_ANY, while standard RISC-V exceptions still write mtval).
 */
.macro EXPECT_TVAL reg
#ifdef CHERI_093
    li   t5, CAUSE_CHERI_ANY
    beq  t5, trap_cause, .Lexpect_ok_\@
#endif
    csrr t5, CSR_MTVAL
    sub  t5, t5, \reg
    beqz t5, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_TVAL reg
#ifdef CHERI_093
    li   t5, CAUSE_CHERI_ANY
    beq  t5, trap_cause, .Lexpect_ok_\@
#endif
    csrr t5, CSR_MTVAL
    sub  t5, t5, \reg
    bnez t5, fail
.Lexpect_ok_\@:
.endm

/* ... and the capability left in mepc had this tag (TRAP_HANDLER_PCC only). */
.macro EXPECT_EPC_TAG tag
    li   t5, \tag
    beq  t5, trap_epc_tag, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_EPC_TAG tag
    li   t5, \tag
    bne  t5, trap_epc_tag, fail
.endm

/* The capability in \reg carries \tag. */
.macro EXPECT_TAG reg, tag
    YTAGR t5, \reg
    li   t6, \tag
    beq  t6, t5, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_TAG reg, tag
    YTAGR t5, \reg
    li   t6, \tag
    bne  t6, t5, fail
.endm

/* Register value comparisons (safe in capability mode for any register pair). */
.macro EXPECT_EQ r1, r2
    sub  t5, \r1, \r2
    beqz t5, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_EQ r1, r2
    sub  t5, \r1, \r2
    bnez t5, fail
.endm

.macro EXPECT_NE r1, r2
    sub  t5, \r1, \r2
    bnez t5, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_NE r1, r2
    sub  t5, \r1, \r2
    beqz t5, fail
.endm

.macro EXPECT_ZERO reg
    beqz \reg, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_ZERO reg
    bnez \reg, fail
.endm

.macro EXPECT_NONZERO reg
    bnez \reg, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_NONZERO reg
    beqz \reg, fail
.endm

.macro EXPECT_CAP_EQ c1, c2
    YEQ  t5, \c1, \c2
    bnez t5, .Lexpect_ok_\@
    EXPECT_FAIL
.Lexpect_ok_\@:
.endm

.macro ASSERT_CAP_EQ c1, c2
    YEQ  t5, \c1, \c2
    beqz t5, fail
.endm

/*
 * Seed \reg with a poison capability pattern (both halves set to POISON_VAL)
 * before an operation that should fault, and check afterwards that the
 * faulting instruction left \reg unmodified.
 */
#define POISON_VAL 0x55555555

.macro POISON_REG reg
    li   \reg, POISON_VAL
    YHIW \reg, \reg, \reg
.endm

.macro CHECK_POISON_REG reg
    li   t6, POISON_VAL
    YHIW t6, t6, t6
    EXPECT_CAP_EQ \reg, t6
.endm

/* Shared prologue: record the trap, letting an S-mode ecall back to M-mode. */
.macro TRAP_RECORD_AND_LET_ECALL_THROUGH
    csrr t6, CSR_MCAUSE
    li   t5, CAUSE_S_ECALL
    bne  t5, t6, 8f
    li   t5, 0x1800              /* mstatus.MPP = M */
    csrs CSR_MSTATUS, t5
    csrw CSR_MEPC, m_continue
    mret
8:
    mv   trap_cause, t6
#ifdef CHERI_093
    csrr trap_tval2, CSR_MTVAL2
#else
    csrr trap_tval2, CSR_MTVAL
#endif
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
#pragma GCC poison s3 s4 s5 s6 s8 s9 s10 s11 t5 t6

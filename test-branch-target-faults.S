/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY takes control-flow capability faults at the target rather than at the
 * branch. JALR performs no tag, seal, execute-permission or bounds check of
 * its own: it installs the target PCC and jumps, and the fault is reported
 * when the target instruction is fetched. The JALR Operation listing in the
 * specification spells this out, its Sail having "the tag/seal/permission/
 * bounds checks removed (those are taken on fetch now)".
 *
 * mepc is what tells the two apart, and is what every case here checks:
 *
 *         jalr ra, a0, 0     <-- a fault taken at the branch reports THIS
 *         <next instruction>
 *     ...
 *     victim:                <-- a fault taken at the target reports THIS
 *
 * So each test puts the address it is about to jump to in expected_mepc,
 * performs a jump that must fault, and then requires the trap handler to
 * have seen exactly that address. Getting the old, fault-at-the-branch
 * behaviour makes trap_mepc the address of the JALR instead, which no test
 * below can accidentally match.
 */
#include "testmacros.h"

#define CAUSE_CHERI_INST 32

/* Named registers, so the bookkeeping reads clearly at the use sites. */
#define expected_mepc s3         /* address the jump should land on */
#define trap_cause    s4         /* mcause of the most recent trap */
#define trap_mepc_tag s5         /* tag of the capability left in mepc */
#define trap_mepc     s6         /* mepc of the most recent trap */
#define resume_at     s8         /* where the handler should resume */
#define test_id       s10
#define trap_count    s11

/*
 * Jump to \cap with offset \imm, expecting the fetch at the target to fault.
 * \target is the register holding the address the jump lands on, i.e. the
 * value mepc must report. The handler resumes at the instruction after the
 * jump with a PCC derived from mtvecc, whose mode need not be capability
 * mode, so re-enter it.
 */
.macro JALR_EXPECT_FAULT_AT cap, imm, target
    mv   expected_mepc, \target
    la   resume_at, 88f
    jalr ra, \cap, \imm
88: YMODESWY
.endm

/*
 * Exactly one trap since the last check, and it was a CHERI instruction
 * access fault reported against the jump target rather than the JALR.
 * \tag is the tag the capability left in mepc must have, which says which
 * check the target fetch tripped over: 0 for a fault on the tag itself,
 * 1 when the capability is valid but unusable as a PCC.
 */
.macro EXPECT_TARGET_FAULT tag
    li   t3, 1
    bne  t3, trap_count, fail            /* exactly one trap */
    li   trap_count, 0
    li   t3, CAUSE_CHERI_INST
    bne  t3, trap_cause, fail            /* CHERI instruction access fault */
    bne  trap_mepc, expected_mepc, fail  /* reported at the target */
    li   t3, \tag
    bne  t3, trap_mepc_tag, fail         /* ... with this PCC */
.endm

.option norvc
.section .text
.globl _start
_start:
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   trap_cause, 0
    li   trap_mepc, 0
    li   trap_mepc_tag, 0
    li   trap_count, 0

    YMODESWY                     /* capability mode: jalr takes a capability */

    /* Test 1: untagged target (PACKY builds a capability with tag = 0) */
    li   test_id, 1
    la   t0, victim
    PACKY a0, t0, x0
    JALR_EXPECT_FAULT_AT a0, 0, t0
    EXPECT_TARGET_FAULT 0

    /* Test 2: target without execute permission */
    li   test_id, 2
    auipc a0, 0                  /* the only executable capability available */
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, PERM_X
    YPERMC a0, a0, t1
    JALR_EXPECT_FAULT_AT a0, 0, t0
    EXPECT_TARGET_FAULT 1

    /*
     * Test 3: a sentry is only unsealed when the immediate is zero. With a
     * non-zero one it stays sealed, so applying the target address clears
     * the tag exactly as scaddr would, and the target takes a tag fault at
     * cs1.address + 8 rather than a seal fault at cs1.address.
     */
    li   test_id, 3
    auipc a0, 0
    la   t0, victim
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    addi t1, t0, 8
    JALR_EXPECT_FAULT_AT a0, 8, t1
    EXPECT_TARGET_FAULT 0

    /* Test 4: target outside the bounds of the authorizing capability */
    li   test_id, 4
    auipc a0, 0
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1            /* [victim, victim + 8) */
    addi t1, t0, 16              /* ... so +16 is past the top */
    JALR_EXPECT_FAULT_AT a0, 16, t1
    EXPECT_TARGET_FAULT 1

    /*
     * Test 5: the same sentry with a zero immediate is unsealed and runs, so
     * the checks above are not simply rejecting every sentry.
     */
    li   test_id, 5
    auipc a0, 0
    la   t0, good_target
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    jalr ra, a0, 0
    bnez trap_count, fail

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL_S10

/* Jumped to only if a fault was not raised; reaching it fails the test. */
.balign 8
victim:
    j    fail
    j    fail
    j    fail
    j    fail

/* Returns through the backward-edge sentry that jalr wrote to ra. */
.balign 8
good_target:
    ret

/*
 * Records the cause and PCC address of the most recent trap and counts traps
 * in trap_count. The faulting PCC cannot be resumed by writing an address to
 * mepc, so install a fresh PCC derived from mtvecc (a root code capability)
 * at the recovery point stashed in resume_at.
 */
.balign 4
trap_handler:
    YMODESWY                     /* so mepc reads back as a capability */
    csrr trap_cause, CSR_MCAUSE
    csrr trap_mepc, CSR_MEPC
    YTAGR trap_mepc_tag, trap_mepc
    addi trap_count, trap_count, 1
    csrr t5, CSR_MTVEC
    YADDRW t5, t5, resume_at
    csrw CSR_MEPC, t5
    mret

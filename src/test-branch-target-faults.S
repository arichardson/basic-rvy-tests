/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY takes control-flow capability faults at the target rather than at the
 * branch. JALR, JAL, and taken conditional branches perform no tag, seal,
 * execute-permission or bounds check of their own: they write any link
 * sentry to rd, install the target PCC and jump, and the fault is reported
 * when the target instruction is fetched. The JALR Operation listing in the
 * specification spells this out, its Sail having "the tag/seal/permission/
 * bounds checks removed (those are taken on fetch now)".
 *
 * mepc and the link register ra tell the two apart, and are what every case
 * here checks:
 *
 *         jalr ra, a0, 0     <-- a fault taken at the branch reports THIS
 *         <next instruction>
 *     ...
 *     victim:                <-- a fault taken at the target reports THIS
 *
 * So each test puts the address it is about to jump to in expected_epc,
 * clears ra, performs a jump that must fault, and then requires the trap
 * handler to have seen expected_epc and a tagged sentry in ra. Getting the
 * old, fault-at-the-branch behaviour reports the address of the branch and
 * leaves ra unmodified. The tag of the capability left in mepc says which
 * check the target fetch tripped over, which is what separates a target that
 * was detagged on the way from one that arrived intact but unusable.
 */
#define TEST_NAME "branch-target-faults"
#ifdef CHERI_093
#error "RVY v0.9.9 only: 0.9.3 checks the jump target at the branch instead"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define expected_epc s2          /* address the jump should land on */
#define expected_ra  s1          /* link address written before the target fetch faults */

/*
 * Jump to \cap with offset \imm, expecting the fetch at the target to fault.
 * \target is the register holding the address the jump lands on, i.e. the
 * value mepc must report. Clear ra beforehand so we can verify JALR wrote the
 * return sentry before the target fetch faulted.
 */
.macro JALR_EXPECT_FAULT_AT cap, imm, target
    mv   expected_epc, \target
    la   expected_ra, 77f
    mv   ra, x0
    RESUME_AFTER_FAULT 88f
    jalr ra, \cap, \imm
77:
    j    fail
88:
.endm

/*
 * One CHERI instruction access fault, at the target, with this PCC tag, and a
 * valid return sentry written to ra at the branch site.
 */
.macro EXPECT_TARGET_FAULT tag
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG \tag
    YTAGR t2, ra
    beqz t2, fail
    YTYPER t2, ra
    beqz t2, fail
    bne  expected_ra, ra, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: jalr takes a capability */

    /* Untagged target (PACKY builds a capability with tag = 0) */
    NEXT_TEST "an untagged target faults at the target and still writes the link sentry"
    la   t0, victim
    PACKY a0, t0, x0
    JALR_EXPECT_FAULT_AT a0, 0, t0
    EXPECT_TARGET_FAULT 0

    /* Target without execute permission */
    NEXT_TEST "a target without execute permission faults at the target"
    auipc a0, 0                  /* the only executable capability available */
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, PERM_X
    YPERMC a0, a0, t1
    JALR_EXPECT_FAULT_AT a0, 0, t0
    EXPECT_TARGET_FAULT 1

    /*
     * A sentry is only unsealed when the immediate is zero. With a
     * non-zero one it stays sealed, so applying the target address clears the
     * tag exactly as scaddr would, and the target takes a tag fault at
     * cs1.address + 8 rather than a seal fault at cs1.address.
     */
    NEXT_TEST "a sentry with a non-zero immediate stays sealed and detags"
    auipc a0, 0
    la   t0, victim
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    addi t1, t0, 8
    JALR_EXPECT_FAULT_AT a0, 8, t1
    EXPECT_TARGET_FAULT 0

    /* Target outside the bounds of the authorizing capability */
    NEXT_TEST "a target outside the bounds faults at the target"
    auipc a0, 0
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1            /* [victim, victim + 8) */
    addi t1, t0, 16              /* ... so +16 is past the top */
    JALR_EXPECT_FAULT_AT a0, 16, t1
    EXPECT_TARGET_FAULT 1

    /*
     * PC-relative JAL and conditional branch (BEQ) to a target outside PCC
     * bounds also complete the branch and fault on instruction fetch at the
     * target.
     */
    NEXT_TEST "a jal to an out-of-bounds target writes ra and faults at the target"
    auipc a0, 0
    la   t0, jal_trampoline
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1            /* covers jal_trampoline, excludes victim */
    la   expected_epc, victim
    la   expected_ra, jal_trampoline_link
    mv   ra, x0
    RESUME_AFTER_FAULT 1f
    jalr x0, a0, 0
1:
    EXPECT_TARGET_FAULT 1

    NEXT_TEST "a taken beq to an out-of-bounds target faults at the target"
    auipc a0, 0
    la   t0, beq_trampoline
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1            /* covers beq_trampoline, excludes victim */
    la   expected_epc, victim
    RESUME_AFTER_FAULT 2f
    jalr x0, a0, 0
2:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    /*
     * The same sentry with a zero immediate is unsealed and runs, so
     * the checks above are not simply rejecting every sentry.
     */
    NEXT_TEST "the same sentry with a zero immediate is unsealed and runs"
    auipc a0, 0
    la   t0, good_target
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    jalr ra, a0, 0
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

/* Jumped to only if a fault was not raised; reaching it fails the test. */
.balign 8
victim:
    j    fail
    j    fail
    j    fail
    j    fail

.balign 8
jal_trampoline:
    jal  ra, victim
jal_trampoline_link:
    j    fail

.balign 8
beq_trampoline:
    beq  x0, x0, victim
    j    fail

/* Returns through the backward-edge sentry that jalr wrote to ra. */
.balign 8
good_target:
    ret

TRAP_HANDLER_PCC

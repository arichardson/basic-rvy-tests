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
 * So each test puts the address it is about to jump to in expected_epc,
 * performs a jump that must fault, and then requires the trap handler to have
 * seen exactly that address. Getting the old, fault-at-the-branch behaviour
 * reports the address of the JALR instead, which no test below can
 * accidentally match. The tag of the capability left in mepc says which check
 * the target fetch tripped over, which is what separates a target that was
 * detagged on the way from one that arrived intact but unusable.
 */
#define TEST_NAME "branch-target-faults"
#ifdef CHERI_093
#error "RVY v0.9.9 only: 0.9.3 checks the jump target at the branch instead"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define expected_epc s2          /* address the jump should land on */

/*
 * Jump to \cap with offset \imm, expecting the fetch at the target to fault.
 * \target is the register holding the address the jump lands on, i.e. the
 * value mepc must report.
 */
.macro JALR_EXPECT_FAULT_AT cap, imm, target
    mv   expected_epc, \target
    RESUME_AFTER_FAULT 88f
    jalr ra, \cap, \imm
88:
.endm

/* One CHERI instruction access fault, at the target, with this PCC tag. */
.macro EXPECT_TARGET_FAULT tag
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG \tag
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: jalr takes a capability */

    /* Test 1: untagged target (PACKY builds a capability with tag = 0) */
    NEXT_TEST "an untagged target faults at the target not the branch"
    la   t0, victim
    PACKY a0, t0, x0
    JALR_EXPECT_FAULT_AT a0, 0, t0
    EXPECT_TARGET_FAULT 0

    /* Test 2: target without execute permission */
    NEXT_TEST "a target without execute permission faults at the target"
    auipc a0, 0                  /* the only executable capability available */
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, PERM_X
    YPERMC a0, a0, t1
    JALR_EXPECT_FAULT_AT a0, 0, t0
    EXPECT_TARGET_FAULT 1

    /*
     * Test 3: a sentry is only unsealed when the immediate is zero. With a
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

    /* Test 4: target outside the bounds of the authorizing capability */
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
     * Test 5: the same sentry with a zero immediate is unsealed and runs, so
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

/* Returns through the backward-edge sentry that jalr wrote to ra. */
.balign 8
good_target:
    ret

TRAP_HANDLER_PCC

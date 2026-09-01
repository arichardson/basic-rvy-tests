/* SPDX-License-Identifier: BSD-2-Clause
 *
 * MRET reads the full YLEN bits of mepc and unseals it if it is a sentry,
 * installing the result as PCC. Every test in this suite already relies on
 * this to resume after a fault, but always with mepc holding an ordinary
 * unsealed capability (whatever the trap handler wrote); nothing exercises
 * the sentry-unseal step itself, or what happens when the capability MRET
 * installs cannot execute.
 *
 * Sealing here always produces a sentry: RVY has no general-purpose sealing
 * instruction, only YSENTRY, so a sealed-but-not-a-sentry epcc cannot be
 * constructed and is not covered.
 *
 * SRET shares the same unseal logic (cheri_update_pcc_for_exc_return in
 * QEMU), but returning to S-mode bare-metal needs PMP or paging set up to
 * grant the target access, which is out of scope here; MRET already
 * exercises the shared code.
 */
#define TEST_NAME "xepc-return"
#ifdef CHERI_093
#error "RVY v0.9.9 only: 0.9.3 checks the mepc target at mret instead of the fetch"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define expected_epc s2               /* address the post-mret fetch should be at */

/* Set mepc to \cap and mret, expecting the fetch at \target to fault. */
.macro MRET_EXPECT_FAULT_AT cap, target
    mv   expected_epc, \target
    RESUME_AFTER_FAULT 88f
    csrw CSR_MEPC, \cap
    li   t5, 0x1800               /* mstatus.MPP = M, so mret returns to M-mode */
    csrs CSR_MSTATUS, t5
    mret
88:
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                      /* capability mode: mepc takes a capability */

    /*
     * Test 1: a sentry sealed over a plain callable capability unseals on
     * mret and resumes there, exactly like a JALR to the same sentry would.
     */
    NEXT_TEST
    auipc a0, 0
    la   t0, good_target
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    csrw CSR_MEPC, a0
    li   t5, 0x1800
    csrs CSR_MSTATUS, t5
    mret
    /* Falling through here (rather than to good_target) fails the test. */
    j    fail

good_target:
    /* Landed here running, so prove PCC itself came out unsealed. */
    auipc a0, 0
    YTYPER t0, a0
    bnez t0, fail
    YMODESWI
    NEXT_TEST

    /*
     * Test 2: a capability missing execute permission is not checked by mret
     * itself; mret installs it as PCC regardless, and the fault is reported
     * against the fetch at the target, same as a JALR to it would be.
     */
    YMODESWY
    auipc a0, 0
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, PERM_X
    YPERMC a0, a0, t1
    MRET_EXPECT_FAULT_AT a0, t0
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1               /* tagged but unusable: a permission fault */

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

/* Reached only if the missing-execute-permission capability ran anyway. */
.balign 8
victim:
    j    fail

TRAP_HANDLER_PCC
/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Exception priority, for the cases where an instruction trips two different
 * checks at once and the architecture says which one is reported. The order
 * is the one in the specification's synchronous exception priority table:
 * a PCC capability fault outranks an illegal instruction, which in turn
 * outranks the capability checks on an explicit memory access, which outrank
 * the misaligned-capability-access faults. Under IALIGN=32, a misaligned
 * branch or jump target is detected at the branch instruction before jumping
 * and fetching the target PCC.
 *
 * Each case comes in two halves, because "the expected exception was
 * reported" says nothing on its own if it was the only one possible. The
 * control half removes the higher-priority condition and requires the loser
 * to show up, so the pair together pins the order rather than the winner.
 */
#define TEST_NAME "exception-priority"
#ifdef CHERI_093
#error "RVY v0.9.9 only: 0.9.3 orders these differently and has one cause"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define CAUSE_MISALIGNED_FETCH 0
#define expected_epc s2          /* address the faulting fetch was at */

/* Jump to \cap, expecting the fetch at \target rather than the jump to fault. */
.macro JALR_EXPECT_FAULT_AT cap, target
    mv   expected_epc, \target
    RESUME_AFTER_FAULT 88f
    jalr ra, \cap, 0
88:
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /*
     * A PCC capability fault against an illegal instruction. The fetch is
     * what fails, so the encoding is never examined and the reserved
     * encoding at the target goes unnoticed.
     */
    NEXT_TEST "control: a reserved encoding in bounds is decoded and is illegal"
    .word 0xffffffff                      /* a reserved encoding */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "a pcc bounds fault outranks the illegal instruction at the target"
    YMODESWY
    auipc a0, 0
    la   t0, illegal_target
    YADDRW a0, a0, t0
    li   t1, 0
    YBNDSW a0, a0, t1            /* empty bounds: nothing is fetchable */
    JALR_EXPECT_FAULT_AT a0, t0
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    YMODESWI

    /*
     * A capability check against a misaligned capability access. Both apply
     * to the same load, and the capability check is reported.
     */
    la   a0, buf
    addi a1, a0, 4               /* never aligned enough for a capability */

    NEXT_TEST "control: an authorized misaligned capability load is misaligned"
    LY   t1, 0(a1)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD

    NEXT_TEST "a capability check outranks the misaligned capability load"
    YMODESWY                     /* capability mode: x0 is the NULL capability */
    LY   t1, 4(x0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    YMODESWI

    NEXT_TEST "control: an authorized misaligned capability store is misaligned"
    SY   x0, 0(a1)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE

    NEXT_TEST "a capability check outranks the misaligned capability store"
    YMODESWY
    SY   x0, 4(x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    YMODESWI

    /*
     * Under IALIGN=32, jumping to a 2-byte-aligned out-of-bounds target
     * faults at the branch with instruction address misaligned before
     * updating PCC and taking the target fetch capability fault.
     */
    SKIPPABLE_BLOCK_BEGIN
    li   t0, (1 << 2)
    csrrc x0, misa, t0
    csrr t1, misa
    and  t1, t1, t0
    bnez t1, 90f

    YMODESWY
    NEXT_TEST "control: an aligned jal out of PCC bounds faults at the target"
    auipc a0, 0
    la   t0, ialign_ctrl_tramp
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1
    la   expected_epc, illegal_target
    RESUME_AFTER_FAULT 1f
    jalr x0, a0, 0
1:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc

    NEXT_TEST "misaligned jalr under IALIGN=32 faults at the branch before target PCC bounds"
    auipc a0, 0
    la   t0, illegal_target
    addi t0, t0, 2
    YADDRW a0, a0, t0
    li   t1, 0
    YBNDSW a0, a0, t1
    la   expected_epc, 2f
    RESUME_AFTER_FAULT 3f
2:  jalr ra, a0, 0
3:
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC expected_epc

    NEXT_TEST "misaligned jal under IALIGN=32 faults at the branch before target PCC bounds"
    auipc a0, 0
    la   t0, ialign_jal_tramp
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1
    la   expected_epc, ialign_jal_tramp
    RESUME_AFTER_FAULT 4f
    jalr x0, a0, 0
4:
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC expected_epc

    NEXT_TEST "misaligned taken beq under IALIGN=32 faults at the branch before target PCC bounds"
    auipc a0, 0
    la   t0, ialign_beq_tramp
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1
    la   expected_epc, ialign_beq_tramp
    RESUME_AFTER_FAULT 5f
    jalr x0, a0, 0
5:
    EXPECT_TRAP CAUSE_MISALIGNED_FETCH
    EXPECT_EPC expected_epc
    YMODESWI

    li   t0, (1 << 2)
    csrrs x0, misa, t0
    j    91f
90: SKIPPABLE_BLOCK_SKIPPED "misa.C is not writable"
91:

    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

/* Reached only if a fetch that must fault did not; running it fails. */
.balign 8
illegal_target:
    .word 0xffffffff
    j    fail

.balign 8
ialign_ctrl_tramp:
    jal  ra, illegal_target
    j    fail

.balign 8
ialign_jal_tramp:
    jal  ra, illegal_target + 2
    j    fail

.balign 8
ialign_beq_tramp:
    beq  x0, x0, illegal_target + 2
    j    fail

TRAP_HANDLER_PCC

.section .bss
.balign 16
buf:
    .space 64

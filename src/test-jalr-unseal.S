/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability-mode JALR unseals a sentry capability in rs1 only when both
 * rs1.address[0] == 0 and the I-immediate offset is zero. Otherwise the target
 * capability remains sealed, JALR sets the target PCC address using YADDRW
 * semantics (which clears the tag because the capability is still sealed), and
 * the subsequent instruction fetch at the target address faults with
 * CAUSE_CHERI_INST and an untagged mepc.
 */
#define TEST_NAME "jalr-unseal"
#include "testmacros.h"
#include "exceptions.h"

.macro EXPECT_JALR_SENTRY_FAULT target_addr
    j       fail
88:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC \target_addr
    EXPECT_EPC_TAG 0
    YTYPER  t3, trap_epc
    beqz    t3, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY
    auipc   t2, 0

    NEXT_TEST "a sentry with an even address and zero offset is unsealed and runs"
    la      t1, good_target
    YADDRW  a0, t2, t1
    YSEALE  a0, a0
    jalr    ra, a0, 0
    EXPECT_NO_TRAP

    la      t1, target
    YADDRW  t2, t2, t1

    NEXT_TEST "a sentry with bit 0 set in its address is not unsealed on jalr with zero offset"
    YADDI   a0, t2, 1
    YSEALE  a0, a0
    RESUME_AFTER_FAULT 88f
    jalr    ra, a0, 0
    EXPECT_JALR_SENTRY_FAULT t1

    NEXT_TEST "a sentry with a non-zero aligned offset is not unsealed on jalr"
    YSEALE  a0, t2
    addi    t0, t1, 4
    RESUME_AFTER_FAULT 88f
    jalr    ra, a0, 4
    EXPECT_JALR_SENTRY_FAULT t0

    /*
     * Regression tests: the unseal check must test imm == 0 and
     * rs1.address[0] == 0 before adding the offset or masking bit 0 of the
     * target address. Masking bit 0 before comparing target_addr == rs1.address
     * wrongly unseals an even-addressed sentry when imm == 1, and checking only
     * whether (rs1.address + imm) is even wrongly unseals an odd-addressed
     * sentry when imm == -1.
     */
    NEXT_TEST "a sentry with offset 1 is not unsealed even though bit 0 is masked"
    YSEALE  a0, t2
    RESUME_AFTER_FAULT 88f
    jalr    ra, a0, 1
    EXPECT_JALR_SENTRY_FAULT t1

    NEXT_TEST "a sentry with bit 0 set and offset -1 is not unsealed"
    YADDI   a0, t2, 1
    YSEALE  a0, a0
    RESUME_AFTER_FAULT 88f
    jalr    ra, a0, -1
    EXPECT_JALR_SENTRY_FAULT t1

    /*
     * Regression tests (Sail 716106581bb5): if a failed sentry jalr updates
     * the sentry's address without detagging PCC via YADDRW semantics, mepc
     * holds a tagged, even-addressed sentry for the target address that mret
     * (which unseals sentry capabilities in mepc) would unseal and execute.
     */
    NEXT_TEST "mepc from jalr to an odd-LSB sentry is not a valid sentry for mret"
    auipc   a0, 0
    la      t1, target
    YADDRW  a0, a0, t1
    YADDI   a0, a0, 1
    YSEALE  a0, a0
    RESUME_AFTER_FAULT 1f
    jalr    ra, a0, 0
    j       fail
1:
    EXPECT_TRAP CAUSE_CHERI_INST
    YMV     a0, trap_epc
    RESUME_AFTER_FAULT 1f
    csrw    CSR_MEPC, a0
    li      t3, 0x1800            /* mstatus.MPP = M */
    csrs    CSR_MSTATUS, t3
    mret
1:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC t1
    EXPECT_EPC_TAG 0

    NEXT_TEST "mepc from jalr with a non-zero offset is not a valid sentry for mret"
    auipc   a0, 0
    la      t1, target
    YADDRW  a0, a0, t1
    YSEALE  a0, a0
    addi    t0, t1, 4
    RESUME_AFTER_FAULT 1f
    jalr    ra, a0, 4
    j       fail
1:
    EXPECT_TRAP CAUSE_CHERI_INST
    YMV     a0, trap_epc
    RESUME_AFTER_FAULT 1f
    csrw    CSR_MEPC, a0
    li      t3, 0x1800            /* mstatus.MPP = M */
    csrs    CSR_MSTATUS, t3
    mret
1:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC t0
    EXPECT_EPC_TAG 0

    YMODESWI
    TEST_PASS

fail:
    YMODESWI
    TEST_FAIL

.balign 8
target:
    j       fail
    j       fail

.balign 8
good_target:
    ret

TRAP_HANDLER_PCC

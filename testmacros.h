/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Helpers for the bare-metal RVY tests. Tests run on the virt machine with
 * -bios none and report their result through the sifive_test finisher
 * device: exit code 0 on success, the failing test id (from s10) otherwise.
 *
 * Register conventions:
 *   s9  - M-mode continuation address for ecalls from S-mode
 *   s10 - current test id (reported as the exit code on failure)
 *   s11 - trap counter maintained by the trap handler
 *   t5/t6 - clobbered by the trap handler and the exit macros
 *
 * NOTE: all conditional branches must use the canonical RVY operand order
 * (rs1 > rs2 by register number); the swapped forms are reserved encodings.
 */

#define FINISHER_ADDR 0x100000

/* CSR numbers (spelled numerically so any assembler accepts them) */
#define CSR_MSTATUS 0x300
#define CSR_MISA    0x301
#define CSR_MTVEC   0x305
#define CSR_MENVCFG 0x30A
#define CSR_MEPC    0x341
#define CSR_MCAUSE  0x342
#define CSR_PMPCFG0 0x3A0
#define CSR_PMPADDR0 0x3B0
#define CSR_DDC     0x416

#define MISA_Y      (1 << 24)
#define MENVCFG_CRE (1 << 9)

.macro TEST_PASS
    li   t6, 0x5555
    li   t5, FINISHER_ADDR
    sw   t6, 0(t5)
99: j    99b
.endm

/* Report failure with exit code = s10 (the current test id). */
.macro TEST_FAIL_S10
    slli t6, s10, 16
    li   t5, 0x3333
    or   t6, t6, t5
    li   t5, FINISHER_ADDR
    sw   t6, 0(t5)
99: j    99b
.endm

.macro SETUP_TRAP_HANDLER
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   s11, 0
.endm

/*
 * Trap handler: counts illegal-instruction exceptions in s11 and skips the
 * faulting (4-byte) instruction. An ecall from S-mode returns to M-mode at
 * the address in s9. Anything else is a test failure.
 */
.macro TRAP_HANDLER
    .balign 4
trap_handler:
    csrr t6, CSR_MCAUSE
    li   t5, 2                    /* illegal instruction */
    bne  t6, t5, 91f
    addi s11, s11, 1
    csrr t6, CSR_MEPC
    addi t6, t6, 4
    csrw CSR_MEPC, t6
    mret
91:
    li   t5, 9                    /* ecall from S-mode */
    bne  t6, t5, 92f
    li   t5, 0x1800               /* mstatus.MPP = M */
    csrs CSR_MSTATUS, t5
    csrw CSR_MEPC, s9
    mret
92:
    TEST_FAIL_S10
.endm

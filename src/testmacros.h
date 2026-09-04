/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Helpers for the bare-metal RVY tests. Tests run on the virt machine with
 * -bios none and report their result through the sifive_test finisher
 * device: exit code 0 on success, the failing test id (from s10) otherwise.
 *
 * Exception handling lives in exceptions.h, which every test includes after
 * this header; it also poisons the raw names of the registers reserved here
 * and there, so refer to them only as test_id, trap_count and friends.
 *
 * NOTE: all conditional branches must use the canonical RVY operand order
 * (rs1 > rs2 by register number); the swapped forms are reserved encodings.
 */

#include "console.h"
#include "rvy-insns.h"

/* Reserved registers shared by every test (see exceptions.h for the rest). */
#define test_id    s10           /* reported as the exit code on failure */
#define trap_count s11           /* traps since the last expectation */

/*
 * Make capability instructions usable in M-mode. RVY has misa.Y set at reset,
 * but 0.9.3 gates them on mseccfg.CRE, which resets to zero, so a test that
 * does not set it traps on its first capability instruction -- and then again
 * in the trap handler.
 */
.macro ENABLE_CHERI
#ifdef CHERI_093
    li   t0, MSECCFG_CRE
    csrs CSR_MSECCFG, t0
#endif
.endm

/*
 * The three BEQ/BNE encodings RVY reserves in capability mode, i.e. operands
 * in rs1 <= rs2 register number order. Spelled as .insn because an assembler
 * that knew about the reservation would refuse them, and arranged never to be
 * taken so control flow does not depend on whether they execute. Expects
 * t0 = 1, t1 = 1, t2 = 2, and branches to "fail" if one is ever taken.
 */
.macro RESERVED_ORDER_BRANCHES
    .insn b 0x63, 0, t0, t2, fail        /* beq x5, x7 (1 != 2) */
    .insn b 0x63, 1, t0, t1, fail        /* bne x5, x6 (1 == 1) */
    .insn b 0x63, 1, t0, t0, fail        /* bne x5, x5 (rs1 == rs2) */
.endm

/* The same comparisons in the canonical order, which are never reserved. */
.macro LEGAL_ORDER_BRANCHES
    .insn b 0x63, 0, t1, t0, 1f          /* beq x6, x5: taken */
    j    fail
1:
    .insn b 0x63, 1, t2, t0, 2f          /* bne x7, x5: taken */
    j    fail
2:
.endm

/*
 * Every test defines TEST_NAME so that the pass/fail line says which one it
 * was; without it a run of the whole suite is just a column of exit codes.
 */
#ifndef TEST_NAME
#error "each test must #define TEST_NAME before including this header"
#endif

/*
 * Report the result as TAP, so a run reports each case rather than just a
 * verdict: the plan, then one line per case up to the one that failed. The
 * name goes out as a TAP comment, which keeps the old human-readable line
 * without putting anything in the stream a parser would choke on.
 */
.macro TEST_PASS
    .pushsection .rodata
    .balign 4
94: .ascii "# PASS: "
    .ascii TEST_NAME
    .asciz "\n"
    .popsection
    la   a0, 94b
    call console_puts
    li   a0, __tap_cases         /* every case in the file, skips included */
    li   a1, 0
    call console_tap
    li   a0, 0
    call console_exit
.endm

/* Report failure with exit code = test_id. */
.macro TEST_FAIL
    .pushsection .rodata
    .balign 4
95: .ascii "# FAIL: "
    .ascii TEST_NAME
    .asciz " test "
    .popsection
    la   a0, 95b
    call console_puts
    mv   a0, test_id
    call console_put_dec
    .pushsection .rodata
96: .asciz "\n"
    .popsection
    la   a0, 96b
    call console_puts
    mv   a0, test_id             /* the last case reached is the one that failed */
    mv   a1, test_id
    call console_tap
    mv   a0, test_id
    call console_exit
.endm

/*
 * HTIF tohost/fromhost. QEMU picks these up from the ELF symbol table (both
 * symbols must exist and be 8 bytes) and overlays an MMIO region on them;
 * Sail does the same. On the virt machine they are just ordinary memory.
 */
.section .tohost, "aw", @progbits
.balign 8
.globl tohost
.type tohost, @object
.size tohost, 8
tohost:
    .dword 0
.balign 8
.globl fromhost
.type fromhost, @object
.size fromhost, 8
fromhost:
    .dword 0
.text


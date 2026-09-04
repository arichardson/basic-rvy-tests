/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Interface to the shared console and exit helpers in console.S.
 *
 * These are ordinary functions rather than macros because every test needs
 * them and none of them are performance sensitive, so there is no reason for
 * each one to carry its own copy.
 *
 * Either pointer mode will do for any of them: they switch to capability mode
 * themselves and put the caller's mode back on return, working it out from
 * whether the return address carries a tag. None of them touch the registers
 * exceptions.h reserves.
 *
 * These two are meant to be called from a test, and keep to a0-a3 and t0-t4
 * so that one can be dropped in for a diagnostic:
 *
 *   console_puts(a0 = pointer to a NUL-terminated string)
 *   console_put_dec(a0 = value)     print it in decimal
 *
 * The rest are called on the test's behalf, by SETUP_TRAPS,
 * SKIPPABLE_BLOCK_SKIPPED and TEST_PASS/TEST_FAIL, at points where nothing
 * the test was holding is still live, so they are freer with registers:
 *
 *   console_init()                                    clobbers a0-a5, t0-t4
 *   console_skip(a0 = reason, a1 = first, a2 = last)  clobbers t0-t4
 *   console_tap(a0 = cases, a1 = the failing one)     clobbers a0-a7, t0-t6
 *   console_exit(a0 = exit code)                      does not return
 *
 * console_init runs before the test has installed a handler and probes for
 * the UART, which means trapping where there is none, so it saves and
 * restores everything that disturbs.
 */
#pragma once

/* HTIF device 1, command 1: write the byte in the low bits to the console. */
#define HTIF_PUTCHAR 0x01010000

/* The sifive_test finisher, which is how the virt machine is stopped. */
#define FINISHER_ADDR 0x100000

/*
 * The 16550 UART the virt machine puts at 0x10000000. Nothing is mapped there
 * on the spike machine or under the Sail model, where a bare access faults,
 * so console_init probes for it rather than assuming either way.
 */
#define UART_ADDR     0x10000000
#define UART_THR      0          /* transmit holding register */
#define UART_LSR      5          /* line status; bit 5 = ready for a byte */
#define UART_LSR_THRE 0x20

/*
 * How many skipped blocks a test may have. Going over is reported rather than
 * dropped: a skip that went unrecorded would show up as a case that passed.
 */
#define TAP_MAX_SKIPS 8

/* Room for a 64-bit value in decimal, and the NUL. */
#define DEC_BUF_LEN 24

/*
 * The address the HTIF writes go to, held in memory rather than baked into
 * each store so that test-console can point it at a buffer and read back what
 * was actually emitted. It holds &tohost for every real run; that default is
 * what the harness relies on, so test-console checks it as well.
 */
#if __riscv_xlen == 64
#define LOAD_X  ld
#define STORE_X sd
#define WORD_X  .dword
#define PTR_SHIFT 3
#define PTR_BYTES 8
#else
#define LOAD_X  lw
#define STORE_X sw
#define WORD_X  .word
#define PTR_SHIFT 2
#define PTR_BYTES 4
#endif

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Interface to the shared console and exit helpers in console.S.
 *
 * These are ordinary functions rather than macros because every test needs
 * them and none of them are performance sensitive, so there is no reason for
 * each one to carry its own copy.
 *
 * Calling convention, which the tests depend on:
 *
 *  - Either pointer mode will do. They switch to capability mode themselves
 *    and put the caller's mode back on return, working it out from whether
 *    the return address carries a tag.
 *  - They clobber a0-a3 and t0-t4, and nothing else. In particular they leave
 *    the registers exceptions.h reserves alone, so a test can still report
 *    test_id after calling one.
 *
 *   console_puts(a0 = pointer to a NUL-terminated string)
 *   console_put_dec(a0 = value)     print it in decimal
 *   console_exit(a0 = exit code)    report the code and stop the machine
 *
 * console_init is the exception: SETUP_TRAPS calls it once before a test has
 * begun, and it also uses a4/a5. It probes for the UART, which means trapping
 * where there is none, so it saves and restores everything that disturbs.
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
#else
#define LOAD_X  lw
#define STORE_X sw
#define WORD_X  .word
#endif

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
 *  - Call them in integer pointer mode only. They use plain loads and stores,
 *    which in capability mode would take their base register as the
 *    authorizing capability rather than as an address.
 *  - They clobber a0-a3 and t0-t4, and nothing else. In particular they leave
 *    the registers exceptions.h reserves alone, so a test can still report
 *    test_id after calling one.
 *
 *   console_puts(a0 = pointer to a NUL-terminated string)
 *   console_put_dec(a0 = value)     print it in decimal
 *   console_exit(a0 = exit code)    report the code and stop the machine
 */
#pragma once

/* HTIF device 1, command 1: write the byte in the low bits to the console. */
#define HTIF_PUTCHAR 0x01010000

/* The sifive_test finisher, which is how the virt machine is stopped. */
#define FINISHER_ADDR 0x100000

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

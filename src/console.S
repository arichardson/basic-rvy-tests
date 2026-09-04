/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Console output and the exit sequence, shared by every test.
 *
 * These run in capability pointer mode whatever the caller was in, so that
 * the data accesses below have a capability to authorize them and a test does
 * not have to leave capability mode to report a result. The caller's mode is
 * recovered from the return address rather than from any flag: in capability
 * mode a call leaves a sentry in ra, so ra carries a tag, while in integer
 * pointer mode it leaves a plain address and ra does not. Where it does not,
 * the address is turned back into an executable capability derived from PCC
 * and marked to resume in integer pointer mode, which makes the ordinary
 * return at the end of each function land the caller back where and how it
 * was.
 *
 * Results are reported twice over, because the two harnesses stop the machine
 * differently: through the HTIF tohost register, which spike-like harnesses
 * and the Sail model understand, and through the sifive_test finisher that
 * the virt machine provides. Whichever one is not listening sees only an
 * ordinary memory write.
 *
 * tohost itself is defined by testmacros.h, in the test object, so that the
 * ELF has exactly one of it for the harness to find.
 */
#include "rvy-insns.h"
#include "console.h"

/*
 * Enter capability mode and make ra returnable from it. Clobbers t0-t2.
 */
.macro CONSOLE_ENTER
    YMODESWY
    YTAGR t0, ra
    bnez  t0, 88f                /* a sentry: the caller was in capability mode */
    auipc t1, 0                  /* PCC: executable, and covers the caller */
    YADDRW ra, t1, ra            /* ... redirected to the return address */
    li    t2, CHERI_MODE_INT
    YMODEW ra, ra, t2            /* ... resuming in integer pointer mode */
88:
.endm

/* \cd = a capability derived from ddc addressing \sym. Clobbers \tmp. */
.macro DDC_AT cd, sym, tmp
    csrrs \cd, CSR_DDC, x0
    la    \tmp, \sym
    YADDRW \cd, \cd, \tmp
.endm

.section .text

/*
 * Work out whether this machine has the virt UART, by reading one of its
 * registers behind a trap handler that just records that the access failed.
 * A bare read is the only way to ask: nothing distinguishes the machines
 * otherwise, and on the ones without it the address is simply not mapped.
 *
 * Called from SETUP_TRAPS, before the test installs its own handler.
 */
.globl console_init
console_init:
    CONSOLE_ENTER
    YMV  a1, ra                  /* kept across the probe */

    /*
     * Where there is no UART the probe below traps, and a trap rewrites mepcc
     * and mstatus. That has to leave no trace: a test writing an address to
     * mepc keeps the rest of the capability, so a stale mepcc from here would
     * silently hand it the mode this function runs in rather than its own.
     */
    csrr  a4, CSR_MSTATUS
    csrrs a5, CSR_MEPC, x0       /* the whole capability, not just the address */

    auipc t0, 0                  /* a handler capability, since mtvecc is one */
    la    t1, .Lprobe_failed
    YADDRW t0, t0, t1
    csrrw a2, CSR_MTVEC, t0      /* a2 = whatever was there before */

    li   a3, 1                   /* assume it is there ... */
    csrrs t0, CSR_DDC, x0
    li    t1, UART_ADDR
    YADDRW t0, t0, t1
    lbu   t2, UART_LSR(t0)       /* ... and find out here */
    j    .Lprobe_done

.balign 4
.Lprobe_failed:                  /* entered as a trap handler, and stays there */
    li   a3, 0
.Lprobe_done:
    csrw CSR_MTVEC, a2           /* put the previous handler back ... */
    csrw CSR_MEPC, a5            /* ... and everything the trap disturbed */
    csrw CSR_MSTATUS, a4
    csrrs t0, CSR_DDC, x0
    la    t1, console_uart
    YADDRW t1, t0, t1
    sw    a3, 0(t1)
    YMV  ra, a1
    ret

/*
 * Write the byte in a0 to every console this machine has. The HTIF write is
 * two stores because QEMU only acts on the write to the upper word, while
 * Sail takes either.
 */
.globl console_putc
console_putc:
    CONSOLE_ENTER
    csrrs t0, CSR_DDC, x0        /* kept for both sinks below */

    la    t1, console_target
    YADDRW t2, t0, t1
    LOAD_X t1, 0(t2)             /* where the writes go; &tohost in a real run */
    YADDRW t2, t0, t1
    sw    a0, 0(t2)
    li    t1, HTIF_PUTCHAR
    sw    t1, 4(t2)

    la    t1, console_uart
    YADDRW t2, t0, t1
    lw    t1, 0(t2)
    beqz  t1, 1f                 /* no UART on this machine */
    li    t1, UART_ADDR
    YADDRW t2, t0, t1
    sb    a0, UART_THR(t2)       /* the emulated UART never refuses a byte, so
                                  * this does not poll: spinning on the status
                                  * register would hang outright if the probe
                                  * ever said yes where there is nothing. */
1:  ret

/* Write the NUL-terminated string a0 points at. */
.globl console_puts
console_puts:
    CONSOLE_ENTER
    YMV  t3, ra                  /* console_putc leaves t3/t4 alone */
    csrrs t4, CSR_DDC, x0
    YADDRW t4, t4, a0
1:  lbu  a0, 0(t4)
    beqz a0, 2f
    jal  ra, console_putc
    YADDI t4, t4, 1
    j    1b
2:  YMV  ra, t3
    ret

/* Write the value in a0 in decimal. */
.globl console_put_dec
console_put_dec:
    CONSOLE_ENTER
    YMV  a1, ra
    mv   a2, a0                  /* the value, which is never a capability */
    csrrs a3, CSR_DDC, x0
    la   t0, dec_buf
    addi t0, t0, DEC_BUF_LEN - 1
    YADDRW a3, a3, t0
    sb   x0, 0(a3)               /* terminator; digits are filled backwards */
    li   t0, 10
1:  YADDI a3, a3, -1
    remu t1, a2, t0
    addi t1, t1, '0'
    sb   t1, 0(a3)
    divu a2, a2, t0
    bnez a2, 1b
    mv   a0, a3                  /* console_puts wants the address */
    YMV  ra, a1
    j    console_puts            /* tail call: it returns to our caller */

/*
 * Report a0 as the exit code and stop. The two encodings are what each
 * harness expects: HTIF takes (code << 1) | 1, and the finisher takes a
 * plain 0x5555 for success or the code alongside 0x3333 for failure.
 */
.globl console_exit
console_exit:
    CONSOLE_ENTER
    slli t1, a0, 1
    ori  t1, t1, 1
    DDC_AT t0, tohost, t2
    sw   t1, 0(t0)
    sw   x0, 4(t0)

    bnez a0, 1f
    li   t1, 0x5555              /* success */
    j    2f
1:  slli t1, a0, 16
    li   t2, 0x3333
    or   t1, t1, t2
2:  csrrs t0, CSR_DDC, x0
    li   t2, FINISHER_ADDR
    YADDRW t0, t0, t2
    sw   t1, 0(t0)
3:  j    3b                      /* the harness stops us before we get here */

.section .data
.balign 8
.globl console_target
console_target:
    WORD_X tohost

/* Set by console_init: non-zero where this machine has the virt UART. */
.globl console_uart
console_uart:
    .word 0

.section .bss
.balign 8
dec_buf:
    .space DEC_BUF_LEN

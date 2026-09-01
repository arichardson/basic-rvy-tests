/* SPDX-License-Identifier: BSD-2-Clause
 *
 * The shared console helpers in console.S, which every other test depends on
 * to report its result. If they are broken the rest of the suite cannot say
 * so, which is what makes them worth a test of their own.
 *
 * What "it printed something" means is checked directly rather than inferred
 * from the call returning: console_target holds the address the writes go to,
 * so pointing it at a buffer makes the bytes readable back. Each case then
 * requires the exact character and the HTIF command word that should have
 * accompanied it. The default value of console_target is checked too, since
 * that is the part a redirected run cannot exercise and the harness is what
 * otherwise depends on it.
 *
 * The helpers run in capability pointer mode whatever the caller was in, and
 * recover the caller's mode from the return address: a call made in
 * capability mode leaves a sentry in ra, so ra carries a tag, while one made
 * in integer pointer mode leaves a plain address and no tag.
 *
 * The mode a call returns in is checked by what a plain address is worth
 * afterwards, rather than by reading it back: an integer-mode auipc does not
 * produce a capability with execute permission, so YMODER reads zero from it
 * whatever the mode really is, and would report capability mode either way.
 * A load through the bare address is unambiguous instead. In integer pointer
 * mode ddc authorizes it and it goes through; in capability mode the same
 * register is an untagged capability and the load is refused.
 */
#define TEST_NAME "console"
#include "testmacros.h"
#include "exceptions.h"

/* Send the console at the buffer below, so its writes can be read back. */
.macro REDIRECT_CONSOLE
    la   t0, console_target
    la   t1, sink
    STORE_X t1, 0(t0)
.endm

.macro RESTORE_CONSOLE
    la   t0, console_target
    la   t1, tohost
    STORE_X t1, 0(t0)
.endm

.macro CLEAR_SINK
    la   t0, sink
    sw   x0, 0(t0)
    sw   x0, 4(t0)
.endm

/* The last byte written, and the HTIF command that should have gone with it. */
.macro EXPECT_EMITTED ch
    la   t0, sink
    lbu  t1, 0(t0)
    li   t2, \ch
    bne  t1, t2, fail
    lw   t1, 4(t0)
    li   t2, HTIF_PUTCHAR
    bne  t1, t2, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /*
     * The default target is what the harness reads, and a redirected run
     * cannot check it, so check it before redirecting anything.
     */
    NEXT_TEST
    la   t0, console_target
    LOAD_X t1, 0(t0)
    la   t2, tohost
    bne  t1, t2, fail

    REDIRECT_CONSOLE

    /* One character: the byte and the command word both have to appear. */
    NEXT_TEST
    CLEAR_SINK
    li   a0, 'X'
    call console_putc
    EXPECT_EMITTED 'X'

    /* A string: reaching its last character means the loop ran to the end. */
    NEXT_TEST
    CLEAR_SINK
    la   a0, msg_abc
    call console_puts
    EXPECT_EMITTED 'c'

    /* A number, whose last digit is emitted last. */
    NEXT_TEST
    CLEAR_SINK
    li   a0, 1234567890
    call console_put_dec
    EXPECT_EMITTED '0'

    /* The same from capability mode, which takes the other entry path. */
    NEXT_TEST
    CLEAR_SINK
    YMODESWY
    la   a0, msg_abc
    call console_puts
    YMODESWI
    EXPECT_EMITTED 'c'

    RESTORE_CONSOLE

    /* From integer pointer mode: the call comes back in integer mode. */
    NEXT_TEST
    la   a0, msg_int
    call console_puts
    la   t0, scratch
    lw   t1, 0(t0)
    EXPECT_NO_TRAP

    /*
     * From capability mode: the call comes back in capability mode, where
     * the bare address is an untagged capability and the load is refused.
     * That is what shows the mode was put back rather than left as the
     * helper ran in.
     */
    NEXT_TEST
    YMODESWY
    la   a0, msg_cap
    call console_puts
    la   t0, scratch
    lw   t1, 0(t0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    /* Still capability mode, so a real capability still works there. */
    NEXT_TEST
    csrrs t0, CSR_DDC, x0
    la   t1, scratch
    YADDRW t0, t0, t1
    lw   t2, 0(t0)
    EXPECT_NO_TRAP

    /*
     * The decimal printer, which makes a nested call to console_puts and so
     * has to keep its own return address across it.
     */
    NEXT_TEST
    li   a0, 1234567890
    call console_put_dec
    la   a0, msg_nl
    call console_puts
    la   t0, scratch
    lw   t1, 0(t0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    /* And back from integer pointer mode again, still in it afterwards. */
    NEXT_TEST
    YMODESWI
    la   a0, msg_int
    call console_puts
    la   t0, scratch
    lw   t1, 0(t0)
    EXPECT_NO_TRAP

    /* Reporting the result from capability mode has to work too. */
    YMODESWY
    TEST_PASS
fail:
    TEST_FAIL

TRAP_HANDLER

.section .rodata
msg_abc: .asciz "abc"
msg_int: .asciz "console: from integer mode\n"
msg_cap: .asciz "console: from capability mode, decimal "
msg_nl:  .asciz "\n"

.section .bss
.balign 8
sink:
    .space 8
scratch:
    .space 8

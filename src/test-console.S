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
 * accompanied it. The default value of console_target and the console_init
 * probes for the UART and the optional target_info payload at
 * TARGET_INFO_ADDR are checked too, since a redirected run cannot exercise
 * the first and the harness is what otherwise depends on them.
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

/*
 * Send the console at the buffer below, so its writes can be read back. The
 * UART is silenced for the duration as well: it is a separate sink that the
 * redirect does not cover, and anything it emitted here would land in the
 * middle of the run's real output.
 */
.macro REDIRECT_CONSOLE
    lla    t0, console_target
    lla    t1, sink
    STORE_X t1, 0(t0)
    lla    t0, console_putc_fn
    LY     s0, 0(t0)             /* remembered for RESTORE_CONSOLE */
    lla    t1, console_putc_htif
    YADDRW t1, s0, t1
    SY     t1, 0(t0)
.endm

.macro RESTORE_CONSOLE
    lla    t0, console_target
    lla    t1, tohost
    STORE_X t1, 0(t0)
    lla    t0, console_putc_fn
    SY     s0, 0(t0)
.endm

.macro CLEAR_SINK
    lla   t0, sink
    sw   x0, 0(t0)
    sw   x0, 4(t0)
.endm

/* The last byte written, and the HTIF command that should have gone with it. */
.macro EXPECT_EMITTED ch
    lla   t0, sink
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
    NEXT_TEST "console_target defaults to the address the harness reads"
    lla   t0, console_target
    LOAD_X t1, 0(t0)
    lla   t2, tohost
    bne  t1, t2, fail

    /*
     * Whether there is a UART is a property of the machine, so neither
     * answer can be asserted outright. What must hold is that console_init
     * agreed with reality: the register is readable exactly when it said so.
     */
    NEXT_TEST "console_init agreed with whether the UART is really there"
    lla   t0, console_putc_fn
    LY    s1, 0(t0)
    YTAGR t0, s1
    beqz  t0, fail
    lla   t0, console_putc_htif
    beq   s1, t0, 1f
    li   t0, UART_ADDR
    lbu  t1, UART_LSR(t0)
    EXPECT_NO_TRAP
    j    2f
1:  lla   t0, target_info
    lw   t1, TARGET_INFO_OFF_MAGIC(t0)
    bnez t1, 2f                  /* target_info disabled the UART without probing */
    li   t0, UART_ADDR
    lbu  t1, UART_LSR(t0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
2:

    /*
     * console_init sets console_putc_fn from target_info.uart_addr and
     * target_info.has_htif (populated either from TARGET_INFO_ADDR or by the
     * fallback UART probe).
     */
    NEXT_TEST "console_init selected console_putc_fn to match target_info"
    lla   t0, target_info
    LOAD_X t1, TARGET_INFO_OFF_UART_ADDR(t0)
    lbu  t2, TARGET_INFO_OFF_HAS_HTIF(t0)
    bnez t1, 1f
    beqz t2, fail
    lla   t0, console_putc_htif
    bne  s1, t0, fail
    j    3f
1:  bnez t2, 2f
    lla   t0, console_putc_uart
    bne  s1, t0, fail
    j    3f
2:  lla   t0, console_putc_both
    bne  s1, t0, fail
3:

    /*
     * Whether the harness loaded the target_info ELF at TARGET_INFO_ADDR is
     * also a property of the run: console_init must have copied it when the
     * magic word was readable there, and left the local copy zeroed otherwise.
     */
    NEXT_TEST "console_init agreed with whether the target_info payload is there"
    lla   t0, target_info
    lw   s1, TARGET_INFO_OFF_MAGIC(t0)
    lw   s2, TARGET_INFO_OFF_IMPL_ID(t0)
    li   t0, TARGET_INFO_ADDR
    lw   t1, TARGET_INFO_OFF_MAGIC(t0)
    bnez trap_count, 1f
    li   t2, TARGET_INFO_MAGIC
    bne  t2, t1, 1f
    bne  t2, s1, fail
    lw   t1, TARGET_INFO_OFF_IMPL_ID(t0)
    bne  s2, t1, fail
    j    2f
1:  li   trap_count, 0
    bnez s1, fail
    bnez s2, fail
2:

    REDIRECT_CONSOLE

    /*
     * If TARGET_INFO_ADDR traps (simulated by bounding pcc below it),
     * console_init catches the trap and leaves the local target_info zeroed.
     */
    NEXT_TEST "console_init leaves target_info zeroed when TARGET_INFO_ADDR traps"
    lla   t0, target_info
    LOAD_X a6, TARGET_INFO_OFF_UART_ADDR(t0)
    lbu  a7, TARGET_INFO_OFF_HAS_HTIF(t0)
    li   t1, TARGET_INFO_MAGIC
    sw   t1, TARGET_INFO_OFF_MAGIC(t0)
    YMODESWY
    auipc s7, 0
    li    t0, 0x80000000
    YADDRW t1, s7, t0
    li    t0, 0x100000
    YBNDSW t1, t1, t0
    lla   t0, 1f
    YADDRW t1, t1, t0
    jr    t1
1:  call  console_init
    lla   t0, 2f
    YADDRW s7, s7, t0
    jr    s7
2:  YMODESWI
    EXPECT_NO_TRAP
    lla   t0, target_info
    lw   t1, TARGET_INFO_OFF_MAGIC(t0)
    bnez t1, fail
    lw   t1, TARGET_INFO_OFF_IMPL_ID(t0)
    bnez t1, fail
    LOAD_X t1, TARGET_INFO_OFF_UART_ADDR(t0)
    bnez t1, fail
    lbu  t1, TARGET_INFO_OFF_HAS_HTIF(t0)
    beqz t1, fail
    sw   s1, TARGET_INFO_OFF_MAGIC(t0)
    sw   s2, TARGET_INFO_OFF_IMPL_ID(t0)
    STORE_X a6, TARGET_INFO_OFF_UART_ADDR(t0)
    sb   a7, TARGET_INFO_OFF_HAS_HTIF(t0)

    /*
     * Pointing target_info.uart_addr at sink and selecting console_putc_uart
     * exercises the UART sink directly on machines that have no hardware UART.
     */
    NEXT_TEST "console_putc_uart writes the byte to target_info.uart_addr"
    CLEAR_SINK
    lla   t0, target_info
    LOAD_X s1, TARGET_INFO_OFF_UART_ADDR(t0)
    lla   t1, sink
    STORE_X t1, TARGET_INFO_OFF_UART_ADDR(t0)
    lla   t0, console_putc_fn
    lla   t1, console_putc_uart
    YADDRW t1, s0, t1
    SY    t1, 0(t0)
    lla   a0, msg_abc
    call console_puts
    lla   t0, target_info
    STORE_X s1, TARGET_INFO_OFF_UART_ADDR(t0)
    lla   t0, console_putc_fn
    lla   t1, console_putc_htif
    YADDRW t1, s0, t1
    SY    t1, 0(t0)
    lla   t0, sink
    lbu  t1, 0(t0)
    li   t2, 'c'
    bne  t1, t2, fail
    lw   t1, 4(t0)
    bnez t1, fail

    /* One character: the byte and the command word both have to appear. */
    NEXT_TEST "console_putc emits the byte and the HTIF command word"
    CLEAR_SINK
    li   a0, 'X'
    call console_putc
    EXPECT_EMITTED 'X'

    /* A string: reaching its last character means the loop ran to the end. */
    NEXT_TEST "console_puts runs the string to its last character"
    CLEAR_SINK
    lla   a0, msg_abc
    call console_puts
    EXPECT_EMITTED 'c'

    /* A number, whose last digit is emitted last. */
    NEXT_TEST "console_put_dec emits the digits ending with the last"
    CLEAR_SINK
    li   a0, 1234567890
    call console_put_dec
    EXPECT_EMITTED '0'

    /* The same from capability mode, which takes the other entry path. */
    NEXT_TEST "console_puts from capability mode emits the same bytes"
    CLEAR_SINK
    YMODESWY
    lla   a0, msg_abc
    call console_puts
    YMODESWI
    EXPECT_EMITTED 'c'

    /* The console helpers do not rely on ddc or a writable caller pcc. */
    NEXT_TEST "console_puts works when ddc is cleared and pcc is read-only"
    CLEAR_SINK
    YMODESWY
    csrrw s7, CSR_DDC, x0
    auipc s1, 0
    li    t0, DROP_MASK(PERM_W)
    DROP_PERMS t1, s1, t0
    lla   t0, 1f
    YADDRW t1, t1, t0
    jr    t1
1:  lla   a0, msg_abc
    call  console_puts
    auipc t0, 0
    YPERMR t0, t0
    andi  t0, t0, PERM_W
    bnez  t0, fail               /* caller's read-only PCC was restored */
    lla   t0, 2f
    YADDRW s1, s1, t0
    jr    s1
2:  csrrw x0, CSR_DDC, s7
    YMODESWI
    EXPECT_NO_TRAP
    EXPECT_EMITTED 'c'

    /*
     * console_fail records the failing case in tap_failed and records the
     * first failing id in tap_fail_first; EXPECT_FAIL preserves ra, a0, and
     * t0-t4.
     */
    NEXT_TEST "console_fail records non-fatal failures and preserves caller state"
    mv    s1, test_id
    li    a0, 5
    call  console_fail
    YMODESWY
    li    ra, 0x1111
    li    a0, 0x2222
    li    t0, 0x3333
    li    t1, 0x4444
    li    test_id, 9
    EXPECT_FAIL
    YMODESWI
    mv    test_id, s1
    lla   a1, tap_fail_first
    LOAD_X a2, 0(a1)
    STORE_X x0, 0(a1)
    lla   a1, tap_failed
    lbu   a3, 5(a1)
    lbu   a4, 9(a1)
    sb    x0, 5(a1)
    sb    x0, 9(a1)
    li    a5, 5
    EXPECT_EQ a2, a5
    li    a5, 1
    EXPECT_EQ a3, a5
    EXPECT_EQ a4, a5
    li    a5, 0x1111
    EXPECT_EQ ra, a5
    li    a5, 0x2222
    EXPECT_EQ a0, a5
    li    a5, 0x3333
    EXPECT_EQ t0, a5
    li    a5, 0x4444
    EXPECT_EQ t1, a5

    RESTORE_CONSOLE

    /* From integer pointer mode: the call comes back in integer mode. */
    NEXT_TEST "a call made in integer mode returns in integer mode"
    lla   a0, msg_int
    call console_puts
    lla   t0, scratch
    lw   t1, 0(t0)
    EXPECT_NO_TRAP

    /*
     * From capability mode: the call comes back in capability mode, where
     * the bare address is an untagged capability and the load is refused.
     * That is what shows the mode was put back rather than left as the
     * helper ran in.
     */
    NEXT_TEST "a call made in capability mode returns in capability mode"
    YMODESWY
    lla   a0, msg_cap
    call console_puts
    lla   t0, scratch
    lw   t1, 0(t0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    /* Still capability mode, so a real capability still works there. */
    NEXT_TEST "a real capability still authorizes a load afterwards"
    csrrs t0, CSR_DDC, x0
    lla   t1, scratch
    YADDRW t0, t0, t1
    lw   t2, 0(t0)
    EXPECT_NO_TRAP

    /*
     * The decimal printer, which makes a nested call to console_puts and so
     * has to keep its own return address across it.
     */
    NEXT_TEST "console_put_dec keeps its return address across its nested call"
    li   a0, 1234567890
    call console_put_dec
    lla   a0, msg_nl
    call console_puts
    lla   t0, scratch
    lw   t1, 0(t0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    /* And back from integer pointer mode again, still in it afterwards. */
    NEXT_TEST "and integer mode is still restored after that"
    YMODESWI
    lla   a0, msg_int
    call console_puts
    lla   t0, scratch
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
msg_int: .asciz "# console: from integer mode\n"
msg_cap: .asciz "# console: from capability mode, decimal "
msg_nl:  .asciz "\n"

.section .bss
.balign 8
sink:
    .space 8
scratch:
    .space 8

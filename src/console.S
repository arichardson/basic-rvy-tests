/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Console output and the exit sequence, shared by every test.
 *
 * These run in capability pointer mode whatever mode the caller was in:
 * console_init seals the initial RWX PCC into a per-function sentry for each
 * entry point, so a test does not have to leave capability mode, keep PCC
 * writable, or restore ddc to report a result. The caller's mode and PCC are
 * recovered from the return address: in capability mode a call leaves a sentry
 * in ra, so ra carries a tag, while in integer pointer mode it leaves a plain
 * address and ra does not. Where it does not, the address is turned back into
 * an executable capability derived from the caller's PCC and marked to resume
 * in integer pointer mode.
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
#include "target-info.h"

/*
 * If the caller was in integer mode, ra holds an untagged address; wrap it in
 * \pcc_reg with integer execution mode so ret resumes in the caller's mode.
 */
.macro WRAP_INT_RA pcc_reg, tmp_reg
    YTAGR  \tmp_reg, ra
    bnez   \tmp_reg, 99f         /* cap-mode calls already leave a sentry in ra */
    YADDRW ra, \pcc_reg, ra
    li     \tmp_reg, CHERI_MODE_INT
    YMODEW ra, ra, \tmp_reg
99:
.endm

/*
 * Enter capability mode, make ra returnable to the caller's PCC and mode, and
 * jump through this function's saved RWX PCC sentry to .L\name\()_impl.
 * Clobbers t0-t2.
 */
.macro CONSOLE_ENTRY name
.globl \name
\name:
    YMODESWY
1:  auipc  t1, %pcrel_hi(.L\name\()_sentry)
    LY     t0, %pcrel_lo(1b)(t1)
    WRAP_INT_RA t1, t2
    jr     t0
    .pushsection .data.console_sentries, "aw", @progbits
    /* Replaced in-place with a sentry by console_init; must be YLEN-aligned. */
.balign YLEN_BYTES
.L\name\()_sentry:
    WORD_X .L\name\()_impl
    .space XBYTES
    .popsection
.endm

.section .data.console_sentries, "aw", @progbits
.balign YLEN_BYTES
.Lconsole_sentries_start:

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
    YMODESWY
    auipc  t0, 0
    WRAP_INT_RA t0, t1
    YMV    a1, ra                /* kept across the probe */

    /* Seal the initial RWX PCC into each helper's entry sentry on first call. */
    lla    t1, .Lconsole_sentries_start
    YADDRW t1, t0, t1
    LY     t2, 0(t1)
    YTAGR  t2, t2
    bnez   t2, 2f
    lla    t2, .Lconsole_sentries_end
    YADDRW t2, t0, t2
1:  LOAD_X t3, 0(t1)
    YADDRW t3, t0, t3
    YSEALE t3, t3
    SY     t3, 0(t1)
    YADDI  t1, t1, YLEN_BYTES
    bne    t2, t1, 1b
2:

    /*
     * Where there is no UART the probe below traps, and a trap rewrites mepcc
     * and mstatus. That has to leave no trace: a test writing an address to
     * mepc keeps the rest of the capability, so a stale mepcc from here would
     * silently hand it the mode this function runs in rather than its own.
     */
    csrr  a4, CSR_MSTATUS
    csrrs a5, CSR_MEPC, x0       /* the whole capability, not just the address */

    /*
     * Copy the per-emulator target_info payload from TARGET_INFO_ADDR if it
     * is mapped and starts with TARGET_INFO_MAGIC; otherwise leave the local
     * target_info all-zeroes for the default spec-compliant behaviour.
     */
    lla    t2, target_info
    YADDRW t2, t0, t2
    li    t3, TARGET_INFO_SIZE
1:  sb    x0, 0(t2)
    YADDI t2, t2, 1
    addi  t3, t3, -1
    bnez  t3, 1b

    auipc t1, 0                  /* a handler capability, since mtvecc is one */
    lla    t2, .Ltarget_info_done
    YADDRW t1, t1, t2
    csrrw a2, CSR_MTVEC, t1      /* a2 = whatever was there before */

    li    t1, TARGET_INFO_ADDR
    YADDRW t1, t0, t1
    lw    t2, TARGET_INFO_OFF_MAGIC(t1)
    li    t3, TARGET_INFO_MAGIC
    bne   t3, t2, .Ltarget_info_done

    lla    t2, target_info
    YADDRW t2, t0, t2
    li    t3, TARGET_INFO_SIZE
1:  lbu   t4, 0(t1)
    sb    t4, 0(t2)
    YADDI t1, t1, 1
    YADDI t2, t2, 1
    addi  t3, t3, -1
    bnez  t3, 1b

.balign 4
.Ltarget_info_done:
    lla    t1, target_info
    YADDRW t1, t0, t1
    LOAD_X a0, TARGET_INFO_OFF_UART_ADDR(t1)
    lbu   t2, TARGET_INFO_OFF_HAS_HTIF(t1)
    lla    a3, console_putc_htif
    bnez  a0, 1f
    bnez  t2, .Lprobe_done
    j     .Lprobe_uart
1:  lla    a3, console_putc_uart
    beqz  t2, .Lprobe_done
    lla    a3, console_putc_both
    j     .Lprobe_done

.Lprobe_uart:
    li     t2, 1
    sb     t2, TARGET_INFO_OFF_HAS_HTIF(t1)

    lla    t1, .Lprobe_failed
    YADDRW t1, t0, t1
    csrw   CSR_MTVEC, t1

    lla    a3, console_putc_both  /* assume the UART is there ... */
    li     t1, UART_ADDR
    YADDRW t2, t0, t1
    lbu    t2, UART_LSR(t2)       /* ... and find out here */
    STORE_X t1, target_info + TARGET_INFO_OFF_UART_ADDR, t2
    j      .Lprobe_done

.balign 4
.Lprobe_failed:                  /* entered as a trap handler, and stays there */
    lla   a3, console_putc_htif
.Lprobe_done:
    YADDRW a3, t0, a3
1:  auipc  t1, %pcrel_hi(console_putc_fn)
    SY     a3, %pcrel_lo(1b)(t1)

    csrw CSR_MTVEC, a2           /* put the previous handler back ... */
    csrw CSR_MEPC, a5            /* ... and everything the trap disturbed */
    csrw CSR_MSTATUS, a4

    /* The version line has to come first, so announce it before any test runs. */
    lla  a0, .Ltap_version
    YMV  ra, a1                  /* console_puts returns straight to our caller */
    j    .Lconsole_puts_impl

/*
 * Capability-mode character sinks selected by console_init and stored in
 * console_putc_fn, so console_putc and console_puts jump straight to the
 * active implementation without re-checking which sinks exist.
 *
 * The HTIF write is two stores because QEMU only acts on the write to the
 * upper word, while Sail takes either. The emulated UART never refuses a
 * byte, so console_putc_uart does not poll: spinning on the status register
 * would hang outright if the probe ever said yes where there is nothing.
 */
.globl console_putc_htif
console_putc_htif:
    LOAD_X t1, console_target    /* where the writes go; &tohost in a real run */
    YADDRW t2, t0, t1
    sw    a0, 0(t2)
    li    t1, HTIF_PUTCHAR
    sw    t1, 4(t2)
    ret

.globl console_putc_both
console_putc_both:
    LOAD_X t1, console_target
    YADDRW t2, t0, t1
    sw    a0, 0(t2)
    li    t1, HTIF_PUTCHAR
    sw    t1, 4(t2)
    /* fall through */
.globl console_putc_uart
console_putc_uart:
    LOAD_X t1, target_info + TARGET_INFO_OFF_UART_ADDR
    YADDRW t2, t0, t1
    sb    a0, UART_THR(t2)
    ret

/* Write the byte in a0 through the sink console_init selected. */
CONSOLE_ENTRY console_putc
.Lconsole_putc_impl:
1:  auipc  t0, %pcrel_hi(console_putc_fn)
    LY     t0, %pcrel_lo(1b)(t0)
    jr     t0

/* Write the NUL-terminated string a0 points at. */
CONSOLE_ENTRY console_puts
.Lconsole_puts_impl:
1:  auipc  t0, %pcrel_hi(console_putc_fn)
    LY     a1, %pcrel_lo(1b)(t0)
    YMV    t3, ra                 /* putc helpers leave t0, t3/t4 and a1 alone */
    YADDRW t4, t0, a0
2:  lbu    a0, 0(t4)
    beqz   a0, 3f
    jalr   ra, a1, 0
    YADDI  t4, t4, 1
    j      2b
3:  YMV    ra, t3
    ret

/* Write the value in a0 in decimal. */
CONSOLE_ENTRY console_put_dec
.Lconsole_put_dec_impl:
    auipc  t0, 0
    YMV    a1, ra
    mv     a2, a0                /* the value, which is never a capability */
    lla    t1, dec_buf + DEC_BUF_LEN - 1
    YADDRW a3, t0, t1
    sb     x0, 0(a3)             /* terminator; digits are filled backwards */
    li     t0, 10
1:  YADDI  a3, a3, -1
    remu   t1, a2, t0
    addi   t1, t1, '0'
    sb     t1, 0(a3)
    divu   a2, a2, t0
    bnez   a2, 1b
    mv     a0, a3                /* console_puts wants the address */
    YMV    ra, a1
    j      .Lconsole_puts_impl   /* tail call: it returns to our caller */

/*
 * Record that cases a1 through a2 could not run here, for the reason a0
 * names. Several blocks may each report their own, so these accumulate; going
 * over TAP_MAX_SKIPS sets a flag that console_tap reports, because a skip that
 * was quietly dropped would leave its cases looking like ones that passed.
 */
CONSOLE_ENTRY console_skip
.Lconsole_skip_impl:
    auipc  t0, 0
    lla    t1, tap_skip_count
    YADDRW t1, t0, t1
    LOAD_X t2, 0(t1)
    li   t3, TAP_MAX_SKIPS
    bge  t2, t3, 1f              /* no room: say so rather than lose it */

    slli t3, t2, PTR_SHIFT       /* slot = count * 3 pointers */
    slli t4, t2, PTR_SHIFT + 1
    add  t3, t3, t4
    lla   t4, tap_skips
    add  t3, t3, t4
    YADDRW t3, t0, t3
    STORE_X a1, 0(t3)
    STORE_X a2, XBYTES(t3)
    STORE_X a0, 2 * XBYTES(t3)
    addi t2, t2, 1
    STORE_X t2, 0(t1)
    ret

1:  lla   t1, tap_skip_overflow
    YADDRW t1, t0, t1
    li   t2, 1
    STORE_X t2, 0(t1)
    ret

/*
 * Record that case a1 is an expected failure (TAP # TODO), for the reason a0
 * names.
 */
CONSOLE_ENTRY console_xfail
.Lconsole_xfail_impl:
    auipc  t0, 0
    lla    t1, tap_xfail_count
    YADDRW t1, t0, t1
    LOAD_X t2, 0(t1)
    li   t3, TAP_MAX_XFAILS
    bge  t2, t3, 1b              /* no room: say so rather than lose it */

    slli t3, t2, PTR_SHIFT + 1   /* slot = count * 2 pointers */
    lla   t4, tap_xfails
    add  t3, t3, t4
    YADDRW t3, t0, t3
    STORE_X a1, 0(t3)
    STORE_X a0, XBYTES(t3)
    addi t2, t2, 1
    STORE_X t2, 0(t1)
    ret

/*
 * Emit the whole TAP stream: a0 = how many cases ran, a1 = which one failed
 * (0 if none). It is written out here at the end rather than a line at a time
 * as the cases run, because NEXT_TEST would then have to clobber the argument
 * registers, and tests set those up before it as often as after.
 *
 * Clobbers a0-a7 and t0-t4, which is more than the rest of this file, but the
 * only callers are TEST_PASS and TEST_FAIL and nothing runs after them.
 *
 * Note the operand order of the bne/beq below: RVY reserves BEQ/BNE with the
 * operands in rs1 <= rs2 register number order, and this runs in capability
 * mode where that reservation applies.
 */
CONSOLE_ENTRY console_tap
.Lconsole_tap_impl:
    auipc  t6, 0                 /* kept for the table loads below */
    YMV    a4, ra                /* none of the calls below touch a4-a7 */
    mv     a6, a0
    mv     a7, a1

    /*
     * Entry i of the table names case i: NEXT_TEST emits it and loads test_id
     * from the same assembly-time counter, so the two cannot disagree. t5 is
     * how many entries there are, which only bounds the loop below.
     */
    lla   t0, __tapnames_start
    lla   t1, __tapnames_end
    sub  t5, t1, t0
    srli t5, t5, PTR_SHIFT

    li   a5, 1
1:  blt  a6, a5, 2f              /* while i <= total */
    bne  a7, a5, 3f
5:  lla   a0, .Ltap_notok
    j    4f
3:  lla   t0, tap_xfail_count
    YADDRW t0, t6, t0
    LOAD_X t1, 0(t0)
    lla   t2, tap_xfails
    YADDRW t2, t6, t2
10: beqz t1, 11f
    LOAD_X t3, 0(t2)
    beq  t3, a5, 5b
    YADDI t2, t2, 2 * XBYTES
    addi t1, t1, -1
    j    10b
11: lla   a0, .Ltap_ok
4:  jal  ra, .Lconsole_puts_impl
    mv   a0, a5
    jal  ra, .Lconsole_put_dec_impl

    bltu t5, a5, 6f              /* past the end of the table */
    lla   t0, __tapnames_start
    addi t1, a5, -1
    slli t1, t1, PTR_SHIFT
    add  t0, t0, t1
    YADDRW t0, t6, t0
    LOAD_X a3, 0(t0)             /* the name, which survives console_puts */
    YADDRW t0, t6, a3
    lbu  t1, 0(t0)
    beqz t1, 6f                  /* this case was not given one */
    lla   a0, .Ltap_dash
    jal  ra, .Lconsole_puts_impl
    mv   a0, a3
    jal  ra, .Lconsole_puts_impl
    /* Was this case inside any of the blocks that could not run? */
6:  lla   t0, tap_skip_count
    YADDRW t0, t6, t0
    LOAD_X t1, 0(t0)             /* t1 = slots left to look at */
    lla   t2, tap_skips
    YADDRW t2, t6, t2            /* t2 = the slot being looked at */
8:  beqz t1, 12f
    LOAD_X t3, 0(t2)
    blt  a5, t3, 9f              /* before this range */
    LOAD_X t3, XBYTES(t2)
    blt  t3, a5, 9f              /* after it */
    LOAD_X a3, 2 * XBYTES(t2)    /* the reason; survives console_puts */
    lla   a0, .Ltap_skip
    jal  ra, .Lconsole_puts_impl
    mv   a0, a3
    jal  ra, .Lconsole_puts_impl
    j    7f
9:  YADDI t2, t2, 3 * XBYTES
    addi t1, t1, -1
    j    8b
    /* Was this case marked as an expected failure? */
12: lla   t0, tap_xfail_count
    YADDRW t0, t6, t0
    LOAD_X t1, 0(t0)
    lla   t2, tap_xfails
    YADDRW t2, t6, t2
13: beqz t1, 7f
    LOAD_X t3, 0(t2)
    bne  t3, a5, 14f
    LOAD_X a3, XBYTES(t2)
    lla   a0, .Ltap_todo
    jal  ra, .Lconsole_puts_impl
    mv   a0, a3
    jal  ra, .Lconsole_puts_impl
    j    7f
14: YADDI t2, t2, 2 * XBYTES
    addi t1, t1, -1
    j    13b
7:  lla   a0, .Ltap_nl
    jal  ra, .Lconsole_puts_impl
    addi a5, a5, 1
    j    1b
2:  lla   a0, .Ltap_plan          /* the plan trails the results, so a test does
                                  * not have to declare its count up front */
    jal  ra, .Lconsole_puts_impl
    mv   a0, a6
    jal  ra, .Lconsole_put_dec_impl
    lla   a0, .Ltap_nl
    jal  ra, .Lconsole_puts_impl
    YMV  ra, a4
    ret

.section .rodata
.Ltap_version: .asciz "TAP version 13\n"
.Ltap_plan:  .asciz "1.."
.Ltap_ok:    .asciz "ok "
.Ltap_notok: .asciz "not ok "
.Ltap_dash:  .asciz " - "
.Ltap_skip:  .asciz " # SKIP "
.Ltap_todo:  .asciz " # TODO "
.Ltap_nl:    .asciz "\n"

.section .text

/*
 * Report a0 as the exit code and stop. The two encodings are what each
 * harness expects: HTIF takes (code << 1) | 1, and the finisher takes a
 * plain 0x5555 for success or the code alongside 0x3333 for failure.
 */
CONSOLE_ENTRY console_exit
.Lconsole_exit_impl:
    auipc  t0, 0
    slli   t1, a0, 1
    ori    t1, t1, 1
    sw     t1, tohost, t2
    sw     x0, tohost + 4, t2

    bnez   a0, 1f
    li     t1, 0x5555            /* success */
    j      2f
1:  slli   t1, a0, 16
    li     t2, 0x3333
    or     t1, t1, t2
2:  li     t2, FINISHER_ADDR
    YADDRW t0, t0, t2
    sw     t1, 0(t0)
3:  j      3b                    /* the harness stops us before we get here */

.section .data.console_sentries, "aw", @progbits
.Lconsole_sentries_end:

.section .data
.balign 8
.globl console_target
console_target:
    WORD_X tohost

/* Set by console_skip: one {first, last, reason} per block that could not run. */
.globl tap_skip_count
tap_skip_count:
    WORD_X 0
.globl tap_skip_overflow
tap_skip_overflow:
    WORD_X 0
.globl tap_skips
tap_skips:
    .space 3 * XBYTES * TAP_MAX_SKIPS

/* Set by console_xfail: one {case_id, reason} per expected failure. */
.globl tap_xfail_count
tap_xfail_count:
    WORD_X 0
.globl tap_xfails
tap_xfails:
    .space 2 * XBYTES * TAP_MAX_XFAILS

/*
 * Resolved by console_init to a capability for console_putc_htif,
 * console_putc_uart, or console_putc_both.
 */
.balign YLEN_BYTES
.globl console_putc_fn
console_putc_fn:
    WORD_X console_putc_htif
    .space XBYTES

/*
 * Populated by console_init from the per-emulator ELF at TARGET_INFO_ADDR;
 * stays all-zeroes (the default spec-compliant configuration) when no second
 * ELF was loaded.
 */
.balign 8
.globl target_info
target_info:
    .space TARGET_INFO_SIZE

.section .bss
.balign 8
dec_buf:
    .space DEC_BUF_LEN

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Running off the end of PCC. Every byte of an instruction must be within
 * the PCC bounds, so an instruction is only fetchable when
 *
 *     pc + instruction_size <= pcc.top
 *
 * The interesting cases are the ones that straddle the top: a four-byte
 * instruction with 1, 2 or 3 of its bytes in bounds must fault just as one
 * that is entirely out of bounds does, and with compressed instructions
 * enabled a four-byte instruction can sit at a two-byte-aligned address, so
 * the fetch is split into two half-words and only the first of them may be
 * in bounds. The fault is reported against the address of the instruction
 * that could not be fetched.
 *
 * Each case bounds a PCC-derived capability to an exact prefix of a stub and
 * calls it. The stub's first instruction sets ran_marker, so the tests can
 * tell "faulted before running anything" from "ran the in-bounds part and
 * then faulted", and the positive cases prove that an instruction ending
 * exactly at pcc.top still executes.
 */
#include "testmacros.h"

#define CAUSE_CHERI_INST 32

/* Named registers, so the bookkeeping reads clearly at the use sites. */
#define expected_mepc s3         /* address of the instruction that faults */
#define trap_cause    s4         /* mcause of the most recent trap */
#define trap_mepc     s6         /* mepc of the most recent trap */
#define ran_marker    s7         /* set by the in-bounds part of a stub */
#define resume_at     s8         /* where the handler should resume */
#define test_id       s10
#define trap_count    s11

/*
 * a0 = an executable capability covering exactly [\stub, \stub + \len), and
 * t0 = \stub. YBNDSW clears the tag when the requested bounds are not
 * exactly representable, which would turn every later check into a tag fault
 * instead, so reject that here rather than misreporting it.
 */
.macro BOUNDED_CODE_CAP stub, len
    auipc a0, 0                  /* the only executable capability available */
    la   t0, \stub
    YADDRW a0, a0, t0
    li   t1, \len
    YBNDSW a0, a0, t1
    YTAGR t2, a0
    beqz t2, fail_inexact_bounds
.endm

/*
 * Call \stub with PCC bounded to \len bytes and require the fetch at
 * \stub + \fault_off to fault. \marker is the value ran_marker must hold
 * afterwards: 1 if the instruction before the boundary was expected to run,
 * 0 if the faulting instruction is the first one.
 */
.macro EXPECT_FETCH_FAULT stub, len, fault_off, marker
    li   ran_marker, 0
    li   trap_count, 0
    BOUNDED_CODE_CAP \stub, \len
    addi expected_mepc, t0, \fault_off
    la   resume_at, 88f
    jalr ra, a0, 0
88: YMODESWY                     /* the fresh PCC need not be in capmode */
    li   t3, 1
    bne  t3, trap_count, fail            /* exactly one trap */
    li   t3, CAUSE_CHERI_INST
    bne  t3, trap_cause, fail            /* CHERI instruction access fault */
    bne  trap_mepc, expected_mepc, fail  /* against the unfetchable insn */
    li   t3, \marker
    bne  t3, ran_marker, fail
.endm

/*
 * Call \stub with PCC bounded to \len bytes and require it to run to
 * completion: the last instruction ends exactly at pcc.top.
 */
.macro EXPECT_NO_FETCH_FAULT stub, len
    li   ran_marker, 0
    li   trap_count, 0
    BOUNDED_CODE_CAP \stub, \len
    jalr ra, a0, 0
    bnez trap_count, fail
    li   t3, 1
    bne  t3, ran_marker, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   trap_cause, 0
    li   trap_mepc, 0
    li   trap_count, 0

    YMODESWY                     /* capability mode: jalr takes a capability */

    /*
     * Four-byte instructions. stub32 sets the marker at +0 and returns at
     * +4, so a bound of 8 covers both and anything smaller cuts into the
     * return.
     */

    /* Test 1: the return is entirely out of bounds (0 of 4 bytes) */
    li   test_id, 1
    EXPECT_FETCH_FAULT stub32, 4, 4, 1

    /* Tests 2-4: the return has 1, 2 and 3 of its 4 bytes in bounds */
    li   test_id, 2
    EXPECT_FETCH_FAULT stub32, 5, 4, 1
    li   test_id, 3
    EXPECT_FETCH_FAULT stub32, 6, 4, 1
    li   test_id, 4
    EXPECT_FETCH_FAULT stub32, 7, 4, 1

    /* Test 5: all 4 bytes in bounds, ending exactly at the top: runs */
    li   test_id, 5
    EXPECT_NO_FETCH_FAULT stub32, 8

    /* Test 6: the very first instruction is out of bounds */
    li   test_id, 6
    EXPECT_FETCH_FAULT stub32, 0, 0, 0

    /*
     * Compressed instructions. stub16 sets the marker at +0 and returns at
     * +2, both two bytes wide.
     */

    /* Test 7: the compressed return has 1 of its 2 bytes in bounds */
    li   test_id, 7
    EXPECT_FETCH_FAULT stub16, 3, 2, 1

    /* Test 8: both compressed instructions fit exactly: runs */
    li   test_id, 8
    EXPECT_NO_FETCH_FAULT stub16, 4

    /*
     * A four-byte instruction at a two-byte-aligned address, which only
     * arises once compressed instructions are in play. The first half-word
     * is in bounds and decodes as a 32-bit encoding, so the check has to
     * cover the second half-word as well.
     */

    /* Test 9: 2 of the 4 bytes in bounds; the marker must not be set */
    li   test_id, 9
    EXPECT_FETCH_FAULT stub_mixed, 4, 2, 0

    /* Test 10: 3 of the 4 bytes in bounds */
    li   test_id, 10
    EXPECT_FETCH_FAULT stub_mixed, 5, 2, 0

    /*
     * Test 11: all 4 bytes in bounds, so it runs and sets the marker; the
     * fault moves to the following instruction at +6.
     */
    li   test_id, 11
    EXPECT_FETCH_FAULT stub_mixed, 6, 6, 1

    YMODESWI
    TEST_PASS

fail_inexact_bounds:
    li   test_id, 90             /* YBNDSW could not encode the bounds */
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL_S10

/*
 * Entered with PCC bounded to a prefix of the stub. Every instruction is
 * four bytes wide (.option norvc is in force).
 */
.balign 16
stub32:
    li   ran_marker, 1           /* +0 .. +3 */
    ret                          /* +4 .. +7 */

/* The same, with two-byte instructions. */
.balign 16
.option rvc
stub16:
    c.li ran_marker, 1           /* +0 .. +1 */
    c.jr ra                      /* +2 .. +3 */
.option norvc

/*
 * A four-byte instruction at a two-byte-aligned address. Both the marker
 * store and the return are written with .insn so that enabling compressed
 * instructions cannot shrink them and move the boundaries.
 */
.balign 16
.option rvc
stub_mixed:
    c.nop                        /* +0 .. +1 */
    .insn i 0x13, 0, ran_marker, x0, 1  /* +2 .. +5: li ran_marker, 1 */
    .insn i 0x67, 0, x0, ra, 0          /* +6 .. +9: ret */
.option norvc

/*
 * Records the cause and PCC address of the most recent trap and counts traps
 * in trap_count. The faulting PCC cannot be resumed by writing an address to
 * mepc, so install a fresh PCC derived from mtvecc (a root code capability)
 * at the recovery point stashed in resume_at.
 */
.balign 4
trap_handler:
    csrr trap_cause, CSR_MCAUSE
    csrr trap_mepc, CSR_MEPC
    addi trap_count, trap_count, 1
    YMODESWY
    csrr t5, CSR_MTVEC
    YADDRW t5, t5, resume_at
    csrw CSR_MEPC, t5
    mret

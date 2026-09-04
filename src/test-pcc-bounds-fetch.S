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
#define TEST_NAME "pcc-bounds-fetch"
#include "testmacros.h"
#include "exceptions.h"

#define expected_epc s2          /* address of the instruction that faults */
#define ran_marker   s7          /* set by the in-bounds part of a stub */

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
    CLEAR_TRAPS
    BOUNDED_CODE_CAP \stub, \len
    addi expected_epc, t0, \fault_off
    RESUME_AFTER_FAULT 88f
    jalr ra, a0, 0
88:
    EXPECT_TRAP TRAP_CAP_FETCH(CAP_BOUNDS)
    EXPECT_EPC expected_epc      /* against the unfetchable instruction */
    li   t3, \marker
    bne  t3, ran_marker, fail
.endm

/*
 * Call \stub with PCC bounded to \len bytes and require it to run to
 * completion: the last instruction ends exactly at pcc.top.
 */
.macro EXPECT_NO_FETCH_FAULT stub, len
    li   ran_marker, 0
    CLEAR_TRAPS
    BOUNDED_CODE_CAP \stub, \len
    jalr ra, a0, 0
    EXPECT_NO_TRAP
    li   t3, 1
    bne  t3, ran_marker, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: jalr takes a capability */

    /*
     * Four-byte instructions. stub32 sets the marker at +0 and returns at
     * +4, so a bound of 8 covers both and anything smaller cuts into the
     * return.
     */

    /* Test 1: the return is entirely out of bounds (0 of 4 bytes) */
    NEXT_TEST "a 4-byte return entirely out of bounds faults"
    EXPECT_FETCH_FAULT stub32, 4, 4, 1

    /* Tests 2-4: the return has 1, 2 and 3 of its 4 bytes in bounds */
    NEXT_TEST "a 4-byte return with 1 of its bytes in bounds faults"
    EXPECT_FETCH_FAULT stub32, 5, 4, 1
    NEXT_TEST "a 4-byte return with 2 of its bytes in bounds faults"
    EXPECT_FETCH_FAULT stub32, 6, 4, 1
    NEXT_TEST "a 4-byte return with 3 of its bytes in bounds faults"
    EXPECT_FETCH_FAULT stub32, 7, 4, 1

    /* Test 5: all 4 bytes in bounds, ending exactly at the top: runs */
    NEXT_TEST "a 4-byte return ending exactly at pcc.top runs"
    EXPECT_NO_FETCH_FAULT stub32, 8

#ifndef CHERI_093
    /*
     * Test 6: the very first instruction is out of bounds. 0.9.3 checks the
     * target of a jump at the branch rather than on fetch, so there this is
     * a branch fault at the jalr and belongs to a different test.
     */
    NEXT_TEST "the very first instruction being out of bounds faults there"
    EXPECT_FETCH_FAULT stub32, 0, 0, 0
#endif

    /*
     * Compressed instructions. stub16 sets the marker at +0 and returns at
     * +2, both two bytes wide.
     */

    /* Test 7: the compressed return has 1 of its 2 bytes in bounds */
    NEXT_TEST "a compressed return with 1 of its 2 bytes in bounds faults"
    EXPECT_FETCH_FAULT stub16, 3, 2, 1

    /* Test 8: both compressed instructions fit exactly: runs */
    NEXT_TEST "two compressed instructions fitting exactly both run"
    EXPECT_NO_FETCH_FAULT stub16, 4

    /*
     * A four-byte instruction at a two-byte-aligned address, which only
     * arises once compressed instructions are in play. The first half-word
     * is in bounds and decodes as a 32-bit encoding, so the check has to
     * cover the second half-word as well.
     */

    /* Test 9: 2 of the 4 bytes in bounds; the marker must not be set */
    NEXT_TEST "a 4-byte instruction at a 2-byte address with 2 bytes in bounds"
    EXPECT_FETCH_FAULT stub_mixed, 4, 2, 0

    /* Test 10: 3 of the 4 bytes in bounds */
    NEXT_TEST "a 4-byte instruction at a 2-byte address with 3 bytes in bounds"
    EXPECT_FETCH_FAULT stub_mixed, 5, 2, 0

    /*
     * Test 11: all 4 bytes in bounds, so it runs and sets the marker; the
     * fault moves to the following instruction at +6.
     */
    NEXT_TEST "all 4 bytes in bounds so the fault moves to the next instruction"
    EXPECT_FETCH_FAULT stub_mixed, 6, 6, 1

    YMODESWI
    TEST_PASS

fail_inexact_bounds:
    NEXT_TEST "ybndsw could not encode the bounds this case needs"
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

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

TRAP_HANDLER_PCC

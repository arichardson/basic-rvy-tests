/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Storing a capability must write out the bits the register holds, and that
 * includes the value reset left there, which software can store without
 * having put it there. An implementation that keeps a capability as decoded
 * fields has to reset those fields to a combination its own encoder can
 * reproduce, or the first store of an untouched register writes something
 * other than what the register held.
 *
 * The same applies to a capability loaded from memory and stored straight
 * back: any untagged bit pattern is a value a program can hold and move
 * around, so it has to survive for arbitrary patterns and not just for ones
 * that encode something meaningful.
 *
 * Everything is written and checked with integer accesses, so the test says
 * nothing about how a capability is encoded, and nothing here is tagged.
 */
#define TEST_NAME "cap-reset-regression"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define SX      sd
#define LX      ld
#define XBYTES  8
#else
#define SX      sw
#define LX      lw
#define XBYTES  4
#endif

/* Store \reg, load it back, store that, and compare the two memory images. */
.macro EXPECT_RESET_ROUNDTRIP reg
    NEXT_TEST "\reg holds bits it can store back untouched since reset"
    la   a0, src
    la   a1, dst
    SY   \reg, 0(a0)
    LY   a2, 0(a0)
    SY   a2, 0(a1)
    EXPECT_NO_TRAP
    LX   t0, 0(a0)
    LX   t1, 0(a1)
    bne  t0, t1, fail
    LX   t2, XBYTES(a0)
    LX   t3, XBYTES(a1)
    bne  t2, t3, fail
.endm

/*
 * Put \lo (the address half) and \hi (the metadata half) in memory, load the
 * capability they spell, store it back and require the same bits out.
 */
.macro EXPECT_BITS_ROUNDTRIP lo, hi
    NEXT_TEST "the bit pattern \lo / \hi survives a load and store back"
    la   a0, src
    la   a2, dst
    li   t0, \lo
    li   t1, \hi
    SX   t0, 0(a0)
    SX   t1, XBYTES(a0)
    LY   a1, 0(a0)               /* the bits, as a capability ... */
    SY   a1, 0(a2)               /* ... and straight back to memory */
    EXPECT_NO_TRAP
    LX   t2, 0(a2)
    bne  t2, t0, fail            /* the address half survived ... */
    LX   t3, XBYTES(a2)
    bne  t3, t1, fail            /* ... and so did the metadata half */
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /*
     * Registers untouched since reset. These come first, before anything
     * below has had a chance to write to them.
     */
    EXPECT_RESET_ROUNDTRIP a3
    EXPECT_RESET_ROUNDTRIP a4
    EXPECT_RESET_ROUNDTRIP a5
    EXPECT_RESET_ROUNDTRIP a6
    EXPECT_RESET_ROUNDTRIP a7
    EXPECT_RESET_ROUNDTRIP s0
    EXPECT_RESET_ROUNDTRIP s1
    EXPECT_RESET_ROUNDTRIP s2
    EXPECT_RESET_ROUNDTRIP s7

    EXPECT_BITS_ROUNDTRIP 0, 0
    EXPECT_BITS_ROUNDTRIP -1, -1
    EXPECT_BITS_ROUNDTRIP 0x55555555, 0x55555555
    EXPECT_BITS_ROUNDTRIP 0xaaaaaaaa, 0xaaaaaaaa
    EXPECT_BITS_ROUNDTRIP 0x80000000, 0
    EXPECT_BITS_ROUNDTRIP 0, 0x80000000
    EXPECT_BITS_ROUNDTRIP 0x12345678, 0x9abcdef0

    TEST_PASS
fail:
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 16
src:
    .space 32
dst:
    .space 32

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * A capability loaded from memory and stored straight back must write out
 * the bits it read. Any untagged bit pattern is a value a program can hold
 * and move around, so this has to hold for arbitrary ones, not just for
 * patterns that are the encoding of something meaningful.
 *
 * The patterns are written with integer stores and checked with integer
 * loads, so the test says nothing about how a capability is encoded. Nothing
 * here is tagged either.
 */
#define TEST_NAME "cap-roundtrip"
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

/*
 * Put \lo (the address half) and \hi (the metadata half) in memory, load the
 * capability they spell, store it back and require the same bits out.
 */
.macro EXPECT_BITS_ROUNDTRIP lo, hi
    NEXT_TEST
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

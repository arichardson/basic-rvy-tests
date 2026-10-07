/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify that integer atomics (the A extension: AMO*.W/.D, LR/SC) execute
 * and produce the architectural results when the CHERI checks pass:
 *
 *  - Integer pointer mode (authorized by the root DDC): every AMO returns
 *    the old memory value in rd and writes the combined value to memory;
 *    the .W forms sign-extend the 32-bit old value to XLEN and leave the
 *    neighbouring word untouched; min/max distinguish signed from unsigned.
 *  - LR.D followed by SC.D to the same address succeeds (rd = 0, memory
 *    updated); an SC.D without a live reservation fails (rd != 0, memory
 *    unchanged).
 *  - The .aq/.rl/.aqrl orderings are ordinary encodings that execute.
 *  - Capability mode: an AMO through a tagged, bounded capability granting
 *    R and W succeeds just like in integer mode.
 *  - An integer AMO is a data store, so it clears the tag of the
 *    capability-sized granule it writes, whichever half it touches.
 *
 * RV64-only: it exercises the .D forms and 16-byte capability granules.
 */
#define TEST_NAME "int-amo"
#include "testmacros.h"
#include "exceptions.h"

/*
 * Compare \reg against an immediate. t3 is x28, above every register
 * checked here, so the branch is always in the canonical RVY order.
 */
.macro CHECK reg, val
    li   t3, \val
    bne  t3, \reg, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    la   a0, buf                 /* scratch dword/word, 16-byte aligned */
    addi a4, a0, 16              /* granule reached via a capability */
    addi a5, a0, 32              /* granule used for tag clearing */

    /* ---------------------------------------- integer pointer mode --- */

    NEXT_TEST "integer mode: amoadd.w returns the old value and stores the sum"
    li   t0, 5
    sw   t0, 0(a0)
    li   t1, 3
    amoadd.w t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 5
    lw   t0, 0(a0)
    CHECK t0, 8

    NEXT_TEST "integer mode: amoadd.d returns the old value and stores the sum"
    li   t0, 0x100000000
    sd   t0, 0(a0)
    li   t1, 1
    amoadd.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0x100000000
    ld   t0, 0(a0)
    CHECK t0, 0x100000001

    NEXT_TEST "integer mode: amoswap.d"
    li   t0, 0x1111
    sd   t0, 0(a0)
    li   t1, 0x2222
    amoswap.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0x1111
    ld   t0, 0(a0)
    CHECK t0, 0x2222

    NEXT_TEST "integer mode: amoand.d"
    li   t0, 0xff00ff00ff00ff00
    sd   t0, 0(a0)
    li   t1, 0x0ff00ff00ff00ff0
    amoand.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0xff00ff00ff00ff00
    ld   t0, 0(a0)
    CHECK t0, 0x0f000f000f000f00

    NEXT_TEST "integer mode: amoor.d"
    li   t0, 0xf0
    sd   t0, 0(a0)
    li   t1, 0x0f
    amoor.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0xf0
    ld   t0, 0(a0)
    CHECK t0, 0xff

    NEXT_TEST "integer mode: amoxor.d"
    li   t0, 0xff
    sd   t0, 0(a0)
    li   t1, 0x0f
    amoxor.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0xff
    ld   t0, 0(a0)
    CHECK t0, 0xf0

    /*
     * Memory holds -2 and rs2 is 1 for every min/max: signed, -2 < 1;
     * unsigned, 0xff..fe > 1.
     */
    NEXT_TEST "integer mode: amomin.d is signed"
    li   t0, -2
    sd   t0, 0(a0)
    li   t1, 1
    amomin.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, -2
    ld   t0, 0(a0)
    CHECK t0, -2

    NEXT_TEST "integer mode: amomax.d is signed"
    li   t0, -2
    sd   t0, 0(a0)
    li   t1, 1
    amomax.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, -2
    ld   t0, 0(a0)
    CHECK t0, 1

    NEXT_TEST "integer mode: amominu.d is unsigned"
    li   t0, -2
    sd   t0, 0(a0)
    li   t1, 1
    amominu.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, -2
    ld   t0, 0(a0)
    CHECK t0, 1

    NEXT_TEST "integer mode: amomaxu.d is unsigned"
    li   t0, -2
    sd   t0, 0(a0)
    li   t1, 1
    amomaxu.d t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, -2
    ld   t0, 0(a0)
    CHECK t0, -2

    /*
     * .W forms: the old word has bit 31 set, so rd must be sign-extended;
     * the upper word of the dword must not be touched.
     */
    NEXT_TEST "integer mode: amoadd.w sign-extends the old value"
    li   t0, 0x1234567880000000
    sd   t0, 0(a0)
    li   t1, 1
    amoadd.w t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0xffffffff80000000
    ld   t0, 0(a0)
    CHECK t0, 0x1234567880000001

    NEXT_TEST "integer mode: amoswap.w sign-extends the old value"
    li   t0, 0x12345678fffffffe
    sd   t0, 0(a0)
    li   t1, 0x7fffffff
    amoswap.w t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, -2
    ld   t0, 0(a0)
    CHECK t0, 0x123456787fffffff

    NEXT_TEST "integer mode: amomaxu.w compares 32-bit unsigned values"
    li   t0, 0x80000000
    sw   t0, 0(a0)
    li   t1, 0x7fffffff
    amomaxu.w t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0xffffffff80000000
    lw   t0, 0(a0)
    CHECK t0, 0xffffffff80000000

    NEXT_TEST "integer mode: amomin.w compares 32-bit signed values"
    li   t0, 0x80000000
    sw   t0, 0(a0)
    li   t1, 0x7fffffff
    amomin.w t2, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 0xffffffff80000000
    lw   t0, 0(a0)
    CHECK t0, 0xffffffff80000000

    /* ----------------------------------------------------- LR / SC --- */

    NEXT_TEST "integer mode: lr.d then sc.d to the same address succeeds"
    li   t0, 7
    sd   t0, 0(a0)
    lr.d t2, (a0)
    li   t1, 9
    sc.d a1, t1, (a0)
    EXPECT_NO_TRAP
    CHECK t2, 7
    CHECK a1, 0
    ld   t0, 0(a0)
    CHECK t0, 9

    /* The successful sc.d above consumed the reservation. */
    NEXT_TEST "integer mode: sc.d without a reservation fails"
    li   t1, 11
    sc.d a1, t1, (a0)
    EXPECT_NO_TRAP
    beqz a1, fail
    ld   t0, 0(a0)
    CHECK t0, 9

    /* ------------------------------------------------ aq/rl forms --- */

    NEXT_TEST "integer mode: aq/rl orderings execute"
    li   t0, 1
    sd   t0, 0(a0)
    li   t1, 2
    amoadd.d.aqrl t2, t1, (a0)   /* mem 1 -> 3 */
    amoswap.d.aq  t2, t1, (a0)   /* mem 3 -> 2 */
    amoor.w.rl    t2, t1, (a0)   /* mem 2 -> 2 */
    lr.d.aq  t2, (a0)
    sc.d.rl  a1, t1, (a0)        /* mem 2 -> 2 */
    lr.d.aqrl t2, (a0)
    sc.d.aqrl a1, t0, (a0)       /* mem 2 -> 1 */
    EXPECT_NO_TRAP
    CHECK a1, 0
    ld   t0, 0(a0)
    CHECK t0, 1

    /* ------------------------------------------------ capability mode --- */

    /*
     * a2: a tagged capability for the 16-byte granule at a4, bounded to it,
     * holding R and W (X and ASR dropped).
     */
    csrrs t0, CSR_DDC, x0
    YADDRW a2, t0, a4
    YBNDSWI a2, a2, 16
    li   t2, DROP_MASK(PERM_X | PERM_ASR)
    DROP_PERMS a2, a2, t2

    NEXT_TEST "capability mode: amoadd.d through a bounded R+W capability"
    YTAGR t3, a2
    beqz t3, fail
    li   t0, 0x100000000
    sd   t0, 0(a4)
    li   t1, 1
    li   t2, 0
    YMODESWY
    amoadd.d t2, t1, (a2)
    YMODESWI
    EXPECT_NO_TRAP
    CHECK t2, 0x100000000
    ld   t0, 0(a4)
    CHECK t0, 0x100000001

    /* ----------------------------------------------------- tag clearing --- */

    /* a3: a tagged capability, stored into both granule slots below. */
    csrrs t0, CSR_DDC, x0
    YADDRW a3, t0, a5

    NEXT_TEST "an integer amoadd.d to the low half of a granule clears its tag"
    SY   a3, 0(a5)
    EXPECT_NO_TRAP
    LY   t1, 0(a5)
    YTAGR t3, t1
    beqz t3, fail                /* sanity: the stored capability is tagged */
    li   t1, 1
    amoadd.d t2, t1, (a5)
    EXPECT_NO_TRAP
    sub  t3, t2, a5
    bnez t3, fail                /* old value is the capability's address */
    LY   t1, 0(a5)
    YTAGR t3, t1
    bnez t3, fail                /* tag cleared */
    ld   t0, 0(a5)
    addi t0, t0, -1
    sub  t3, t0, a5
    bnez t3, fail                /* memory holds address + 1 */

    NEXT_TEST "an integer amoadd.d to the high half of a granule clears its tag"
    SY   a3, 0(a5)
    EXPECT_NO_TRAP
    LY   t1, 0(a5)
    YTAGR t3, t1
    beqz t3, fail
    ld   a6, 8(a5)               /* a6: high dword of the capability */
    addi a7, a5, 8
    li   t1, 1
    amoadd.d t2, t1, (a7)
    EXPECT_NO_TRAP
    sub  t3, t2, a6
    bnez t3, fail                /* old value is the stored high dword */
    ld   t0, 8(a5)
    addi t0, t0, -1
    sub  t3, t0, a6
    bnez t3, fail                /* memory holds high dword + 1 */
    LY   t1, 0(a5)
    YTAGR t3, t1
    bnez t3, fail                /* tag cleared */

    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 16
buf:
    .space 64

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * LR.Y and SC.Y reservation behaviour:
 *
 *  - An aligned LR.Y followed by SC.Y to the same address succeeds (rd == 0)
 *    and consumes the reservation.
 *  - A second consecutive SC.Y without an intervening LR.Y fails (rd != 0)
 *    and leaves memory unmodified.
 *  - An SC.Y to a different address than the preceding LR.Y fails (rd != 0),
 *    leaves that location unmodified, and cancels the reservation so a
 *    subsequent SC.Y to the originally reserved address also fails.
 */
#define TEST_NAME "lr-sc-reservation"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    lla   a0, buf
    csrrs s0, CSR_DDC, x0
    YADDRW a3, s0, a0
    YADDI  s7, a3, YLEN_BYTES
    SY   a3, 0(a0)

    /* Aligned LR.Y via root DDC succeeds (sanity/decode check) */
    NEXT_TEST "aligned lr.y through root ddc succeeds"
    LR_Y t1, a0
    EXPECT_NO_TRAP

    YMODESWY

    /*
     * LR.Y / SC.Y reservation behaviour in Capability Mode:
     *  - A second consecutive SC.Y without a new LR.Y fails (rd != 0) and
     *    leaves memory unmodified.
     *  - An SC.Y to a different address than the preceding LR.Y fails, leaves
     *    that target location unmodified, and cancels the reservation so a
     *    subsequent SC.Y to the originally reserved address also fails.
     */
    NEXT_TEST "a second consecutive sc.y without a new lr.y fails and leaves memory unmodified"
    SY   x0, 0(a3)
    LR_Y t1, a3
    SC_Y t2, a3, a3
    EXPECT_ZERO t2
    SC_Y t2, a3, x0
    EXPECT_NO_TRAP
    EXPECT_NONZERO t2            /* second SC.Y must report failure (rd != 0) */
    LY   t3, 0(a3)
    EXPECT_TAG t3, 1             /* tagged capability from first SC.Y stays intact */

    NEXT_TEST "sc.y to a different address than the preceding lr.y fails and cancels the reservation"
    SY   a3, 0(a3)
    SY   s7, 0(s7)
    LR_Y t1, a3
    SC_Y t2, s7, x0
    EXPECT_NO_TRAP
    EXPECT_NONZERO t2            /* address mismatch must fail */
    LY   t3, 0(s7)
    EXPECT_TAG t3, 1             /* s7 slot stays tagged */
    SC_Y t2, a3, x0
    EXPECT_NO_TRAP
    EXPECT_NONZERO t2            /* prior SC.Y cancelled the reservation on a3 */
    LY   t3, 0(a3)
    EXPECT_TAG t3, 1             /* a3 slot also stays tagged */

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 64

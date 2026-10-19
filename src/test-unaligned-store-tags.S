/* SPDX-License-Identifier: BSD-2-Clause
 *
 * An unaligned integer store straddling two adjacent capability-sized memory
 * slots invalidates the capability tags of both slots.
 */
#define TEST_NAME "unaligned-store-tags"
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

    YMODESWY

    /*
     * Unaligned integer store straddling two adjacent capability slots at
     * buf + 0 and buf + YLEN_BYTES must invalidate the tags of both slots.
     */
    NEXT_TEST "an unaligned integer store straddling two capabilities clears both tags"
    SY   a3, 0(a3)
    SY   s7, 0(s7)
    sw   x0, (YLEN_BYTES - 2)(a3)
    EXPECT_NO_TRAP
    LY   t1, 0(a3)
    EXPECT_TAG t1, 0
    LY   t3, 0(s7)
    EXPECT_TAG t3, 0

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

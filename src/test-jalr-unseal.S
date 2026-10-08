/* SPDX-License-Identifier: BSD-2-Clause
 *
 * RVY JALR semantic forbids unsealing when the sealed entry capability
 * has a non-zero offset LSB or the JALR immediate is non-zero.
 */
#define TEST_NAME "jalr-unseal"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY
    auipc   t2, 0
    la      t1, target
    YADDRW  t2, t2, t1

    NEXT_TEST "Test jalr with non-zero LSB in sealed entry"
    RESUME_AFTER_FAULT 1f
    YADDI   a0, t2, 1
    YSEALE  a0, a0
    jalr    ra, a0, 0
1:
    EXPECT_TRAP CAUSE_CHERI_INST

    NEXT_TEST "Test jalr with non-zero offset"
    RESUME_AFTER_FAULT 1f
    YSEALE  a0, t2
    jalr    ra, a0, 4
1:
    EXPECT_TRAP CAUSE_CHERI_INST

    YMODESWI
    TEST_PASS

fail:
    YMODESWI
    TEST_FAIL

.balign 8
target:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER_PCC

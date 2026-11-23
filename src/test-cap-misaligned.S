/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Misaligned capability loads, stores, and atomics raise access faults (not
 * misaligned faults) on RVY since they cannot be emulated in software: cause 5
 * for LY and LR.Y (plain load semantics per the spec's LR.Y page), cause 7 for
 * SY, SC.Y, and AMOSWAP.Y, in both integer and capability pointer modes, with
 * mtval holding the faulting virtual address and destination registers and
 * memory left unmodified. 0.9.3 predates that and reports them as misaligned
 * faults (causes 4 and 6).
 */
#define TEST_NAME "cap-misaligned"
#include "testmacros.h"
#include "exceptions.h"

.macro CHECK_BUF base_reg
    LY   t0, 0(\base_reg)
    EXPECT_CAP_EQ t0, a3
    LY   t0, YLEN_BYTES(\base_reg)
    EXPECT_CAP_EQ t0, s7
    SY   a3, 0(\base_reg)
    SY   s7, YLEN_BYTES(\base_reg)
.endm

/*
 * Check that all five misaligned capability operations at \addr_reg fault
 * with the expected cause, report a1 in mtval, and leave rd and buf untouched.
 */
.macro CHECK_MISALIGNED_SUITE prefix, addr_reg, buf_reg
    NEXT_TEST "\prefix\()misaligned ly raises a load fault"
    POISON_REG t1
    LY   t1, 0(\addr_reg)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    EXPECT_TVAL a1
    CHECK_POISON_REG t1

    NEXT_TEST "\prefix\()misaligned sy raises a store fault"
    SY   t2, 0(\addr_reg)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1
    CHECK_BUF \buf_reg

    NEXT_TEST "\prefix\()misaligned lr.y raises a load access fault"
    POISON_REG t1
    LR_Y t1, \addr_reg
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    EXPECT_TVAL a1
    CHECK_POISON_REG t1

    NEXT_TEST "\prefix\()misaligned sc.y raises a store fault"
    POISON_REG t1
    SC_Y t1, \addr_reg, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1
    CHECK_POISON_REG t1
    CHECK_BUF \buf_reg

    NEXT_TEST "\prefix\()misaligned amoswap.y raises a store fault"
    POISON_REG t1
    AMOSWAP_Y t1, \addr_reg, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    EXPECT_TVAL a1
    CHECK_POISON_REG t1
    CHECK_BUF \buf_reg
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    lla   a0, buf                 /* aligned to 64 bytes */
    addi  a1, a0, 4               /* misaligned for YLEN/8 on RV32 and RV64 */

    csrrs s0, CSR_DDC, x0
    YADDRW a3, s0, a0             /* a3: full-permission capability at buf */
    YADDRW a6, s0, a1             /* a6: full-permission capability at buf + 4 */
    YADDI  s7, a3, YLEN_BYTES     /* s7: full-permission capability at buf + YLEN_BYTES */
    SY   a3, 0(a0)
    SY   s7, YLEN_BYTES(a0)
    li   t0, 0xdeadbeef
    YADDRW t2, s0, t0             /* t2: distinct tagged store capability */

    CHECK_MISALIGNED_SUITE "", a1, a0

    YMODESWY
    CHECK_MISALIGNED_SUITE "capability-mode ", a6, a3

    TEST_PASS
fail:
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 128

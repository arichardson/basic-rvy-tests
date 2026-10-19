/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Single-precision (F) and double-precision (D) floating-point loads and
 * stores in capability and integer pointer modes:
 *
 *  - In capability mode, flw, fsw, fld, and fsd authorize the 4-byte or
 *    8-byte memory access through the capability in cs1, checking its tag,
 *    seal, permissions (R for loads, W for stores), and bounds [base, top).
 *  - In integer mode, flw, fsw, fld, fsd, and the compressed Zcf/Zcd
 *    floating-point loads and stores (c.flw, c.fsw, c.flwsp, c.fswsp on RV32;
 *    c.fld, c.fsd, c.fldsp, c.fsdsp on RV32 and RV64) authorize the access
 *    through ddc.
 *  - A floating-point store is a data store and clears the capability tag of
 *    the capability-sized granule it writes.
 */
#define TEST_NAME "fp-loadstore"
#include "testmacros.h"
#include "exceptions.h"

#define MSTATUS_FS_INITIAL (1 << 13)

#define root  s0                 /* ddc */
#define bufp  s1                 /* address of buf */
#define cap   s2                 /* [buf, buf + 16), RW capability */

.macro C_FP insn:vararg
    .option push
    .option rvc
    \insn
    c.nop
    .option pop
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    li   t0, MSTATUS_FS_INITIAL
    csrs CSR_MSTATUS, t0
    csrrs root, CSR_DDC, x0
    lla  bufp, buf
    YMODESWY

    /* cap = [buf, buf + 16), a0 = [buf, buf + 8). */
    YADDRW cap, root, bufp
    li   t0, 16
    YBNDSW cap, cap, t0
    li   t0, 8
    YBNDSW a0, cap, t0

    li   t1, 0x3f800000          /* 1.0f */
    fmv.w.x fa0, t1

    NEXT_TEST "capability mode: fsw and flw in bounds round-trip a 32-bit float"
    fsw  fa0, 4(a0)
    EXPECT_NO_TRAP
    flw  fa1, 4(a0)
    EXPECT_NO_TRAP
    fmv.x.w t2, fa1
    EXPECT_EQ t1, t2

    NEXT_TEST "capability mode: fsd and fld in bounds round-trip a 64-bit double"
    li   t0, 0x11223344
    sw   t0, 0(a0)
    li   t2, 0x55667788
    sw   t2, 4(a0)
    fld  fa2, 0(a0)
    EXPECT_NO_TRAP
    fsd  fa2, 8(cap)
    EXPECT_NO_TRAP
    lw   t3, 8(cap)
    EXPECT_EQ t0, t3
    lw   t3, 12(cap)
    EXPECT_EQ t2, t3

    NEXT_TEST "capability mode: flw and fsw past top or below base take bounds faults"
    flw  fa1, 8(a0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    fsw  fa0, 8(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    flw  fa1, -4(a0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    fsw  fa0, -4(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    NEXT_TEST "capability mode: fld and fsd straddling the top take bounds faults while flw/fsw succeed"
    fld  fa2, 4(a0)              /* [buf + 4, buf + 12) exceeds [buf, buf + 8) */
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    fsd  fa2, 4(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    flw  fa1, 4(a0)              /* control: [buf + 4, buf + 8) fits */
    EXPECT_NO_TRAP
    fsw  fa0, 4(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "capability mode: fsw and fsd without W take permission faults while flw and fld succeed"
    li   t0, DROP_MASK(PERM_W)
    DROP_PERMS a1, a0, t0
    fsw  fa0, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    fsd  fa2, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    flw  fa1, 0(a1)
    EXPECT_NO_TRAP
    fld  fa2, 0(a1)
    EXPECT_NO_TRAP

    NEXT_TEST "capability mode: flw and fld without R take permission faults"
    li   t0, DROP_MASK(PERM_R)
    DROP_PERMS a1, a0, t0
    flw  fa1, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    fld  fa2, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)

    NEXT_TEST "capability mode: flw, fsw, fld, and fsd through an untagged capability take tag faults"
    YADDRW a1, x0, bufp
    flw  fa1, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    fsw  fa0, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    fld  fa2, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    fsd  fa2, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    NEXT_TEST "capability mode: flw, fsw, fld, and fsd through a sealed capability take seal faults"
    YSEALE a1, a0
    flw  fa1, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    fsw  fa0, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    fld  fa2, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    fsd  fa2, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)

    NEXT_TEST "capability mode: fsw and fsd clear the capability tag in memory"
    SY   cap, 0(cap)
    LY   a2, 0(cap)
    EXPECT_TAG a2, 1
    fsw  fa0, 0(cap)
    LY   a2, 0(cap)
    EXPECT_TAG a2, 0
    SY   cap, 0(cap)
    fsd  fa2, (YLEN_BYTES - 8)(cap)
    LY   a2, 0(cap)
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP

    /* Switch to integer pointer mode: accesses are authorized by ddc. */
    YMODESWI

    NEXT_TEST "integer mode: fsw, flw, fsd, fld, and compressed FP loads/stores succeed under ddc"
    mv   a0, bufp
    mv   sp, bufp
    fsw  fa0, 0(a0)
    flw  fa1, 0(a0)
    fmv.x.w t2, fa1
    EXPECT_EQ t1, t2
    C_FP c.fsd fa2, 8(a0)
    C_FP c.fld fa3, 8(a0)
    C_FP c.fsdsp fa3, 16(sp)
    C_FP c.fldsp fa4, 16(sp)
    lw   t3, 16(a0)
    li   t0, 0x11223344
    EXPECT_EQ t0, t3
#if __riscv_xlen == 32
    C_FP c.fsw fa0, 4(a0)
    C_FP c.flw fa1, 4(a0)
    fmv.x.w t2, fa1
    EXPECT_EQ t1, t2
    C_FP c.fswsp fa0, 24(sp)
    C_FP c.flwsp fa1, 24(sp)
    fmv.x.w t2, fa1
    EXPECT_EQ t1, t2
#endif
    EXPECT_NO_TRAP

    NEXT_TEST "integer mode: fsw and c.fsd clear the capability tag in memory"
    SY   cap, 0(a0)
    LY   a2, 0(a0)
    EXPECT_TAG a2, 1
    fsw  fa0, 0(a0)
    LY   a2, 0(a0)
    EXPECT_TAG a2, 0
    SY   cap, 0(a0)
    C_FP c.fsd fa2, 0(a0)
    LY   a2, 0(a0)
    EXPECT_TAG a2, 0
    EXPECT_NO_TRAP

    NEXT_TEST "integer mode: FP loads and stores fault when ddc is out of bounds or lacks permissions"
    /* Restrict ddc to [buf, buf + 8) using cap Mode csrw, then test in integer mode. */
    YMODESWY
    YADDRW a1, cap, bufp
    li   t0, 8
    YBNDSW a1, a1, t0
    csrw CSR_DDC, a1
    YMODESWI
    flw  fa1, 8(a0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    fsw  fa0, 8(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    C_FP c.fld fa3, 8(a0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    C_FP c.fsd fa2, 8(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    flw  fa1, 0(a0)              /* control: [buf, buf + 4) is within ddc */
    EXPECT_NO_TRAP
    YMODESWY
    li   t0, DROP_MASK(PERM_W)
    DROP_PERMS a2, a1, t0
    csrw CSR_DDC, a2
    YMODESWI
    fsw  fa0, 0(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    flw  fa1, 0(a0)
    EXPECT_NO_TRAP
    YMODESWY
    csrw CSR_DDC, root
    YMODESWI

    TEST_PASS
fail:
    YMODESWY
    csrw CSR_DDC, root
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 64

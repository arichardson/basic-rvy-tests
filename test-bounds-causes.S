/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Check the exception reported for capability bounds violations: loads and
 * stores past the top of the authorizing capability, and running off the end
 * of a bounded PCC.
 *
 * RVY has a separate cause per access type (32 instruction, 33 load,
 * 34 store/AMO), whereas 0.9.3 reports every capability fault as cause 0x1c
 * and puts the capability cause and the access type in xtval2, so that is
 * what gets checked there.
 *
 * Register use: s4/s5 = mcause/mtval2 of the most recent trap, s9 = set when
 * the next trap needs a fresh PCC to resume, s10 = test id, s11 = traps since
 * the last check.
 */
#include "testmacros.h"

#ifdef CHERI_093
/* xtval2 = capability cause | TYPE << 16 (0 = instruction fetch, 1 = data) */
#define CAP093_BOUNDS       4
#define TRAP_INST_BOUNDS    0x1c, (CAP093_BOUNDS | (0 << 16))
#define TRAP_LOAD_BOUNDS    0x1c, (CAP093_BOUNDS | (1 << 16))
#define TRAP_STORE_BOUNDS   0x1c, (CAP093_BOUNDS | (1 << 16))
#else
#define TRAP_INST_BOUNDS    32, 0
#define TRAP_LOAD_BOUNDS    33, 0
#define TRAP_STORE_BOUNDS   34, 0
#endif

/* Exactly one trap since the last check, reporting the expected cause. */
.macro EXPECT_TRAP cause, tval2
    li   t3, 1
    bne  t3, s11, fail
    li   s11, 0
    li   t3, \cause
    bne  t3, s4, fail
#ifdef CHERI_093
    li   t3, \tval2
    bne  t3, s5, fail
#endif
.endm

.macro EXPECT_NO_TRAP
    bnez s11, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    la   t0, trap_handler
    csrw CSR_MTVEC, t0
    li   s4, 0
    li   s5, 0
    li   s9, 0                   /* mepc is enough to resume until test 5 */
    li   s11, 0

    /*
     * ddc is the only root data capability available to a bare-metal test,
     * so derive the bounded capabilities under test from it.
     */
    csrrs t0, CSR_DDC, x0
    la   t1, buf
    YADDRW a0, t0, t1
    li   t2, 8
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 8) */
    li   t2, 6
    YBNDSW a1, a0, t2            /* a1 = [buf, buf + 6) */

    YMODESWY                     /* capability mode: a0/a1 authorize accesses */

    /* Test 1: accesses inside the bounds must not trap */
    li   s10, 1
    lw   t2, 0(a0)
    lw   t2, 4(a0)
    sw   t2, 0(a0)
    EXPECT_NO_TRAP

    /* Test 2: load starting past the top */
    li   s10, 2
    lw   t2, 8(a0)
    EXPECT_TRAP TRAP_LOAD_BOUNDS

    /* Test 3: store starting past the top */
    li   s10, 3
    sw   t2, 8(a0)
    EXPECT_TRAP TRAP_STORE_BOUNDS

    /* Test 4: load straddling the top (a1 ends at buf + 6) */
    li   s10, 4
    lw   t2, 4(a1)
    EXPECT_TRAP TRAP_LOAD_BOUNDS

    /*
     * Test 5: running off the end of a function. auipc is the only way to
     * get hold of an executable capability, so bound a PCC-derived one to
     * the two instructions of the stub and call it.
     */
    li   s10, 5
    auipc a2, 0
    la   t1, off_end_stub
    YADDRW a2, a2, t1
    li   t2, 8
    YBNDSW a2, a2, t2
    li   s9, 1                   /* the fetch fault needs a fresh PCC */
    jalr ra, a2, 0
    EXPECT_TRAP TRAP_INST_BOUNDS

    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL_S10

/* Entered with PCC bounded to the two instructions below. */
.balign 8
off_end_stub:
    nop
    nop
    /*
     * Out of bounds from here on, so fetching the jump below must trap; the
     * handler resumes at the instruction after it with a fresh PCC. Reaching
     * the jump at all means the bounds were not enforced.
     */
    j    fail
    ret

/*
 * Records the cause (and, for 0.9.3, mtval2) of the most recent trap and
 * counts traps in s11, then resumes after the faulting (4-byte) instruction.
 */
.balign 4
trap_handler:
    csrr s4, CSR_MCAUSE
#ifdef CHERI_093
    csrr s5, CSR_MTVAL2
#endif
    addi s11, s11, 1
    csrr t6, CSR_MEPC
    addi t6, t6, 4
    beqz s9, 1f
    /*
     * Running off the end of PCC cannot be resumed by writing mepc, since
     * that only moves the address of the capability that faulted and the
     * fetch would trap again. Derive a new PCC from mtvecc (a root code
     * capability) instead -- both are only accessible as capabilities rather
     * than plain addresses while in capability mode.
     */
    li   s9, 0
    YMODESWY
    csrr t5, CSR_MTVEC
    YADDRW t5, t5, t6
    csrw CSR_MEPC, t5
    mret
1:
    csrw CSR_MEPC, t6
    mret

.section .bss
.balign 16
buf:
    .space 64

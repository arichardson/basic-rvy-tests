/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Check xtvec (mtvec and stvec) legalization on CLEN CSR writes and
 * same-block CSR write visibility before synchronous traps and returns:
 *
 *   - Writing an unsealed capability with direct (0) or vectored (1) mode
 *     whose 4-byte-aligned BASE and highest vector offset are representable
 *     preserves the tag and mode.
 *   - Because xtvec applies YADDRW semantics on write, writing a sealed
 *     sentry capability always clears its tag (while preserving CT=1), even
 *     when the low bits select direct or vectored mode.
 *   - Writing reserved modes 2 or 3 retains the previous xtvec.MODE while
 *     updating BASE.
 *   - Writing an unsealed capability at its lower representability boundary
 *     rep_base = (victim + 1) - REP_BELOW (whose low two bits are 0b01,
 *     selecting vectored mode) detags the capability when aligning BASE down
 *     to rep_base & ~3 crosses below rep_base.
 *   - Writing mtvec immediately before ecall, or mepc immediately before
 *     mret, takes effect within the same translation block.
 */

#define TEST_NAME "xtvec-detag"
#include "testmacros.h"
#include "exceptions.h"

#if __riscv_xlen == 64
#define REP_BELOW 0x1000
#else
#define REP_BELOW 0x100
#endif

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: csrw takes the full capability */

    csrrs s0, CSR_DDC, x0
    /* Save the active trap handler mtvec in s2. */
    csrrs s2, CSR_MTVEC, x0

    /* Construct an unsealed capability at victim (4-byte aligned, length 1024). */
    la   s1, victim
    YADDRW a0, s0, s1
    li   t0, 256
    YBNDSW a0, a0, t0            /* a0: [victim, victim+1024), E=0 */

    /* =========================================================================
     * mtvec legalization
     * ========================================================================= */

    NEXT_TEST "mtvec preserves tag and address for representable direct and vectored modes"
    csrw CSR_MTVEC, a0           /* mode 0 (direct) */
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2           /* restore handler immediately */
    YTAGR t0, a1
    beqz t0, fail
    bne  a1, s1, fail

    addi t1, s1, 1               /* mode 1 (vectored) */
    YADDRW a2, a0, t1
    csrw CSR_MTVEC, a2
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2
    YTAGR t0, a1
    beqz t0, fail
    bne  t1, a1, fail

    NEXT_TEST "mtvec detags a sealed sentry even when mode is direct or vectored"
    YSENTRY a2, a0               /* sentry at victim (mode 0) */
    csrw CSR_MTVEC, a2
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2
    YTAGR t0, a1
    bnez t0, fail
    YTYPER t0, a1
    beqz t0, fail
    bne  a1, s1, fail

    addi t1, s1, 1
    YADDRW a2, a0, t1
    YSENTRY a2, a2               /* sentry at victim + 1 (mode 1) */
    csrw CSR_MTVEC, a2
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2
    YTAGR t0, a1
    bnez t0, fail
    YTYPER t0, a1
    beqz t0, fail
    bne  t1, a1, fail

    NEXT_TEST "mtvec reserved modes 2 and 3 retain the prior mode while updating BASE"
    addi t1, s1, 1               /* first set mtvec to mode 1 (vectored) */
    YADDRW a2, a0, t1
    csrw CSR_MTVEC, a2
    addi t2, s1, 2               /* write mode 2 (reserved) */
    YADDRW a3, a0, t2
    csrw CSR_MTVEC, a3
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2
    YTAGR t0, a1
    beqz t0, fail
    bne  t1, a1, fail            /* mode 1 retained, BASE = victim */

    csrw CSR_MTVEC, a0           /* set mtvec to mode 0 (direct) */
    addi t2, s1, 3               /* write mode 3 (reserved) */
    YADDRW a3, a0, t2
    csrw CSR_MTVEC, a3
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2
    YTAGR t0, a1
    beqz t0, fail
    bne  a1, s1, fail            /* mode 0 retained, BASE = victim */

    NEXT_TEST "mtvec detags an unsealed capability when aligning BASE down crosses rep_base"
    addi t1, s1, 1               /* base = victim + 1 */
    YADDRW a2, s0, t1
    li   t0, 256
    YBNDSW a2, a2, t0            /* E=0; rep_base = (victim + 1) - REP_BELOW */
    li   t2, REP_BELOW
    sub  t1, t1, t2              /* cursor = rep_base (low bits 0b01: vectored) */
    YADDRW a2, a2, t1
    YTAGR t0, a2
    beqz t0, fail                /* tagged before CSR write */
    csrw CSR_MTVEC, a2
    csrrs a1, CSR_MTVEC, x0
    csrw CSR_MTVEC, s2
    YTAGR t0, a1
    bnez t0, fail                /* BASE = rep_base - 1 is unrepresentable */
    bne  t1, a1, fail            /* cursor remains rep_base (BASE | mode 1) */

    /* =========================================================================
     * stvec legalization
     * ========================================================================= */

    NEXT_TEST "stvec detags a sealed sentry even when mode is direct"
    YSENTRY a2, a0
    csrw CSR_STVEC, a2
    csrrs a1, CSR_STVEC, x0
    YTAGR t0, a1
    bnez t0, fail
    YTYPER t0, a1
    beqz t0, fail
    bne  a1, s1, fail

    NEXT_TEST "stvec detags an unsealed capability when aligning BASE down crosses rep_base"
    addi t1, s1, 1
    YADDRW a2, s0, t1
    li   t0, 256
    YBNDSW a2, a2, t0
    li   t2, REP_BELOW
    sub  t1, t1, t2
    YADDRW a2, a2, t1
    YTAGR t0, a2
    beqz t0, fail
    csrw CSR_STVEC, a2
    csrrs a1, CSR_STVEC, x0
    YTAGR t0, a1
    bnez t0, fail
    bne  t1, a1, fail

    /* =========================================================================
     * Same-block CSR write visibility before ecall and mret
     * ========================================================================= */

    NEXT_TEST "mtvec write immediately before ecall dispatches to the new handler"
    la   t0, alt_handler
    YADDRW a2, s0, t0
    li   a3, 0
    /* Write mtvec and trap in the same basic block. */
    csrw CSR_MTVEC, a2
    ecall
    csrw CSR_MTVEC, s2           /* restore normal trap handler */
    li   t0, 0x55aa
    bne  a3, t0, fail

    NEXT_TEST "mepc write immediately before mret returns to the new target"
    li   t0, (3 << 11)           /* mstatus.MPP = M */
    csrs mstatus, t0
    la   t0, mepc_target
    YADDRW a2, s0, t0
    /* Write mepc and return in the same basic block. */
    csrw CSR_MEPC, a2
    mret
    j    fail
mepc_target:

    TEST_PASS

fail:
    TEST_FAIL

    .balign 4
alt_handler:
    li   a3, 0x55aa
    csrrs t0, CSR_MEPC, x0
    addi t1, t0, 4
    YADDRW t0, t0, t1
    csrw CSR_MEPC, t0
    mret

TRAP_HANDLER

    .section .data
    .balign 4096
    .space  4096
victim:
    .space  1024

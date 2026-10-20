/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Same-block capability CSR write visibility before synchronous traps and
 * exception returns:
 *
 *   - Writing mtvec immediately before ecall dispatches the trap to the new
 *     handler within the same translation block.
 *   - Writing mepc immediately before mret returns to the new target within
 *     the same translation block.
 */

#define TEST_NAME "csr-same-block"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: csrw takes the full capability */

    csrrs s0, CSR_DDC, x0
    csrrs s2, CSR_MTVEC, x0

    NEXT_TEST "mtvec write immediately before ecall dispatches to the new handler"
    lla   t0, alt_handler
    YADDRW a2, s0, t0
    li   a3, 0
    /* Write mtvec and trap in the same basic block. */
    csrw CSR_MTVEC, a2
    ecall
    csrw CSR_MTVEC, s2           /* restore normal trap handler */
    li   t0, 0x55aa
    EXPECT_EQ a3, t0

    NEXT_TEST "mepc write immediately before mret returns to the new target"
    li   t0, (3 << 11)           /* mstatus.MPP = M */
    csrs mstatus, t0
    lla   t0, mepc_target
    YADDRW a2, s0, t0
    /* Write mepc and return in the same basic block. */
    csrw CSR_MEPC, a2
    mret
    j    fail
mepc_target:

    YMODESWI
    TEST_PASS

fail:
    YMODESWI
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

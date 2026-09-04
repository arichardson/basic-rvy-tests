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
 */
#define TEST_NAME "bounds-causes"
#include "testmacros.h"
#include "exceptions.h"


.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

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
    NEXT_TEST "accesses inside the bounds do not trap"
    lw   t2, 0(a0)
    lw   t2, 4(a0)
    sw   t2, 0(a0)
    EXPECT_NO_TRAP

    /* Test 2: load starting past the top */
    NEXT_TEST "load starting past the top"
    lw   t2, 8(a0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)

    /* Test 3: store starting past the top */
    NEXT_TEST "store starting past the top"
    sw   t2, 8(a0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    /* Test 4: load straddling the top (a1 ends at buf + 6) */
    NEXT_TEST "load straddling the top"
    lw   t2, 4(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)

    /*
     * Test 5: running off the end of a function. auipc is the only way to
     * get hold of an executable capability, so bound a PCC-derived one to
     * the two instructions of the stub and call it.
     */
    NEXT_TEST "running off the end of a bounded pcc"
    auipc a2, 0
    la   t1, off_end_stub
    YADDRW a2, a2, t1
    li   t2, 8
    YBNDSW a2, a2, t2
    RESUME_AFTER_FAULT 1f        /* the fetch fault needs a fresh PCC */
    jalr ra, a2, 0
1:
    EXPECT_TRAP TRAP_CAP_FETCH(CAP_BOUNDS)

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

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

TRAP_HANDLER_PCC

.section .bss
.balign 16
buf:
    .space 64

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * The four cache-block operations split into two different bounds rules:
 * CBO.ZERO and CBO.INVAL fault if *any* byte of the cache block is outside
 * the authorizing capability, while CBO.CLEAN and CBO.FLUSH only fault if
 * *every* byte is. A capability that covers the front of a block but not the
 * rest is therefore accepted by CLEAN/FLUSH and rejected by ZERO/INVAL, even
 * though all four target the same block through the same capability.
 *
 * The asymmetry exists because CLEAN/FLUSH only write memory back out (or
 * discard a clean copy), so partial coverage is still a legitimate thing to
 * ask for; ZERO and INVAL are destructive across the whole block, so any
 * byte outside the capability makes the whole operation unauthorized.
 *
 * 0.9.3 predates this refinement for INVAL specifically: there it shares
 * CLEAN/FLUSH's weaker rule instead, so that one case is version-dependent.
 */
#define TEST_NAME "cbo-bounds"
#include "testmacros.h"
#include "exceptions.h"

#define CBOM_LEN 64

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: the CBOs take a capability */

    /* A capability over the front third of the block, via DDC. */
    csrrs a0, CSR_DDC, x0
    la   t0, buf
    YADDRW a0, a0, t0
    li   t1, CBOM_LEN / 3
    YBNDSW a0, a0, t1            /* [buf, buf + CBOM_LEN/3) */

    /* CLEAN/FLUSH: some bytes of the block are covered, so this is allowed. */
    NEXT_TEST
    CBO_CLEAN a0
    EXPECT_NO_TRAP

    NEXT_TEST
    CBO_FLUSH a0
    EXPECT_NO_TRAP

    /* ZERO: the rest of the block is not covered, so this faults. */
    NEXT_TEST
    CBO_ZERO a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    /*
     * INVAL has the same rule under RVY, but 0.9.3 predates it and instead
     * shares CLEAN/FLUSH's weaker "all bytes out of bounds" check.
     */
    NEXT_TEST
    CBO_INVAL a0
#ifdef CHERI_093
    EXPECT_NO_TRAP
#else
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
#endif

    /*
     * A capability bounded well away from the block CBO.CLEAN's own address
     * selects: no byte is covered, so even CLEAN/FLUSH now fault. The 16-byte
     * bounds stay comfortably representable after the cursor moves back to
     * block 0, so the later fault is a genuine bounds violation rather than
     * an unrepresentable-address tag clear.
     */
    csrrs a0, CSR_DDC, x0
    la   t0, buf
    addi t0, t0, 3 * CBOM_LEN
    YADDRW a0, a0, t0
    li   t1, 16
    YBNDSW a0, a0, t1            /* [buf + 3*CBOM_LEN, buf + 3*CBOM_LEN + 16) */
    la   t0, buf
    YADDRW a0, a0, t0            /* move back to block 0; bounds stay put */

    NEXT_TEST
    CBO_CLEAN a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    NEXT_TEST
    CBO_FLUSH a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    /* A capability over the whole block passes every CBO (sanity/decode check). */
    csrrs a0, CSR_DDC, x0
    la   t0, buf
    YADDRW a0, a0, t0
    li   t1, CBOM_LEN
    YBNDSW a0, a0, t1

    NEXT_TEST
    CBO_ZERO a0
    EXPECT_NO_TRAP

    NEXT_TEST
    CBO_INVAL a0
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 4 * CBOM_LEN
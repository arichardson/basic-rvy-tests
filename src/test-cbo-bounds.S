/* SPDX-License-Identifier: BSD-2-Clause
 *
 * The four cache-block operations split into two different bounds rules and
 * require store permission on the authorizing capability:
 *
 *  - CBO.ZERO and CBO.INVAL fault if *any* byte of the cache block is outside
 *    the authorizing capability, while CBO.CLEAN and CBO.FLUSH only fault if
 *    *every* byte is. A capability that covers the front of a block but not
 *    the rest is therefore accepted by CLEAN/FLUSH and rejected by
 *    ZERO/INVAL, and a faulting CBO.ZERO leaves the cache block unmodified.
 *  - 0.9.3 predates this refinement for INVAL specifically: there it shares
 *    CLEAN/FLUSH's weaker rule instead, so that one case is version-dependent.
 *  - All four CBOs require W (store) permission on the authorizing capability
 *    (and R as well for CLEAN/FLUSH/INVAL), reporting a store capability
 *    permission fault when W is missing even if the whole block is in bounds.
 *  - CBO.ZERO clears the capability tag and data of every capability granule
 *    across the entire 64-byte cache block, including the middle granules at
 *    offsets +16 and +32.
 *  - In S-mode, CBO.ZERO, CBO.CLEAN/FLUSH, and CBO.INVAL are gated by
 *    menvcfg.CBZE, menvcfg.CBCFE, and menvcfg.CBIE respectively.
 */
#define TEST_NAME "cbo-bounds"
#include "testmacros.h"
#include "exceptions.h"

#define CBOM_LEN 64
#define MENVCFG_CBO_ALL 0xf0         /* CBIE (3 << 4) | CBCFE (1 << 6) | CBZE (1 << 7) */

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
    li   t1, 0x5a
    sb   t1, 0(a0)               /* sentinel byte to check CBO.ZERO atomicity */
    li   t1, CBOM_LEN / 3
    YBNDSW a0, a0, t1            /* [buf, buf + CBOM_LEN/3) */

    /* CLEAN/FLUSH: some bytes of the block are covered, so this is allowed. */
    NEXT_TEST "cbo.clean tolerates a block only partly in bounds"
    CBO_CLEAN a0
    EXPECT_NO_TRAP

    NEXT_TEST "cbo.flush tolerates a block only partly in bounds"
    CBO_FLUSH a0
    EXPECT_NO_TRAP

    /*
     * ZERO: the rest of the block is not covered, so this faults without
     * modifying the covered front of the block.
     */
    NEXT_TEST "cbo.zero faults when any byte of the block is out of bounds"
    CBO_ZERO a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0
    lbu  t2, 0(a0)
    li   t3, 0x5a
    bne  t3, t2, fail

    /*
     * INVAL has the same rule under RVY, but 0.9.3 predates it and instead
     * shares CLEAN/FLUSH's weaker "all bytes out of bounds" check.
     */
    NEXT_TEST "cbo.inval: any byte on RVY all bytes on 0.9.3"
    CBO_INVAL a0
#ifdef CHERI_093
    EXPECT_NO_TRAP
#else
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL t0
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

    NEXT_TEST "cbo.clean faults when every byte is out of bounds"
    CBO_CLEAN a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    NEXT_TEST "cbo.flush faults when every byte is out of bounds"
    CBO_FLUSH a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    /*
     * A capability over the whole 64-byte block passes every CBO, and CBO.ZERO
     * clears the capability tag and data of every granule across the block
     * (including the middle granules at +16 and +32).
     */
    csrrs a0, CSR_DDC, x0
    la   t0, buf
    YADDRW a0, a0, t0
    li   t1, CBOM_LEN
    YBNDSW a0, a0, t1

    NEXT_TEST "cbo.zero clears capability tags and data across the entire 64-byte block"
    SY   a0, 0(a0)
    SY   a0, 16(a0)
    SY   a0, 32(a0)
    SY   a0, 48(a0)
#if __riscv_xlen == 32
    SY   a0, 8(a0)
    SY   a0, 24(a0)
    SY   a0, 40(a0)
    SY   a0, 56(a0)
#endif
    CBO_ZERO a0
    EXPECT_NO_TRAP
    LY   t1, 0(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
    LY   t1, 16(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
    LY   t1, 32(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
    LY   t1, 48(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
#if __riscv_xlen == 32
    LY   t1, 8(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
    LY   t1, 24(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
    LY   t1, 40(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
    LY   t1, 56(a0)
    YTAGR t2, t1
    bnez t2, fail
    bnez t1, fail
#endif

    NEXT_TEST "cbo.inval passes when the whole block is in bounds"
    CBO_INVAL a0
    EXPECT_NO_TRAP

    /*
     * Dropping W (store permission) while keeping R and full-block bounds
     * causes all four CBOs to fault with a store permission violation.
     */
    li   t1, DROP_MASK(PERM_W)
    DROP_PERMS a1, a0, t1

    NEXT_TEST "cbo.zero faults on a read-only capability covering the whole block"
    CBO_ZERO a1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL t0

    NEXT_TEST "cbo.clean faults on a read-only capability covering the whole block"
    CBO_CLEAN a1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL t0

    NEXT_TEST "cbo.flush faults on a read-only capability covering the whole block"
    CBO_FLUSH a1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL t0

    NEXT_TEST "cbo.inval faults on a read-only capability covering the whole block"
    CBO_INVAL a1
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL t0

    /*
     * S-mode CBO gating via menvcfg.{CBZE,CBCFE,CBIE}: when clear (0), S-mode
     * CBOs raise illegal instruction; once set in menvcfg, S-mode CBOs
     * execute normally.
     */
    li   t1, -1
    csrw CSR_PMPADDR0, t1
    li   t1, 0x1f
    csrw CSR_PMPCFG0, t1
    li   t1, MENVCFG_CRE
    csrs CSR_MENVCFG, t1
    li   t1, MENVCFG_CBO_ALL
    csrc CSR_MENVCFG, t1

    li   t1, 0x1800
    csrc CSR_MSTATUS, t1
    li   t1, 0x0800
    csrs CSR_MSTATUS, t1
    auipc t2, 0
    la   t1, s_cbo_disabled
    YADDRW t2, t2, t1
    csrw CSR_MEPC, t2
    la   m_continue, s_cbo_disabled_done
    li   s2, 0
    mret

s_cbo_disabled:
    NEXT_TEST "S-mode CBOs fault with illegal instruction when menvcfg CBO bits are clear"
    CBO_ZERO a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    CBO_CLEAN a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    CBO_FLUSH a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    CBO_INVAL a0
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    ecall

s_cbo_disabled_done:
    li   t1, MENVCFG_CBO_ALL
    csrs CSR_MENVCFG, t1
    csrr t2, CSR_MENVCFG
    and  t2, t2, t1
    bne  t2, t1, fail            /* menvcfg CBO enable fields must be writable */

    li   t1, 0x1800
    csrc CSR_MSTATUS, t1
    li   t1, 0x0800
    csrs CSR_MSTATUS, t1
    auipc t2, 0
    la   t1, s_cbo_enabled
    YADDRW t2, t2, t1
    csrw CSR_MEPC, t2
    la   m_continue, s_cbo_enabled_done
    mret

s_cbo_enabled:
    NEXT_TEST "S-mode CBOs succeed once menvcfg CBZE, CBCFE, and CBIE are set"
    SY   a0, 16(a0)
    SY   a0, 32(a0)
    CBO_ZERO a0
    CBO_CLEAN a0
    CBO_FLUSH a0
    CBO_INVAL a0
    EXPECT_NO_TRAP
    LY   t1, 16(a0)
    YTAGR t2, t1
    bnez t2, s_cbo_fail
    LY   t1, 32(a0)
    YTAGR t2, t1
    bnez t2, s_cbo_fail
    ecall

s_cbo_fail:
    li   s2, 1
    ecall

s_cbo_enabled_done:
    bnez s2, fail

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
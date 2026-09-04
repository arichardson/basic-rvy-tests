/* SPDX-License-Identifier: BSD-2-Clause
 *
 * mepc and sepc are widened to capabilities, but their address field keeps
 * the base ISA's rule that bit 0 always reads as zero. Writing one with bit 0
 * set is therefore legalized by clearing that bit, and per the specification
 * a legalized write only clears the tag if either the result becomes
 * unrepresentable, or the capability being written is sealed. An unsealed
 * capability keeps its tag: the address silently rounds down, same as an
 * ordinary (non-CHERI) write to mepc/sepc always has.
 *
 * The sealed half matters because a sentry may legitimately be written here
 * (MRET/SRET unseal one on return): if a sentry's stored address had drifted
 * by a bit, unsealing it as-is would resume execution one byte off from
 * where it was sealed to run. Clearing the tag instead means the return
 * takes an ordinary tag violation rather than silently landing somewhere the
 * sentry never authorized.
 *
 * Both csrw (write) and csrrs ..., x0 (read) go through the full-capability
 * form here, per the RVY rule that any instruction writing an address back
 * to a register writes the full capability, not just its low bits.
 *
 * Bit 1 only matters with IALIGN=32 (misa.C cleared), and unlike bit 0 it is
 * legalized on read rather than on write, so a write with bit 1 set stores
 * it untouched and only a later read rounds it down and detags a sealed
 * capability the same way. mret takes the same masked address as its target,
 * so a sentry stored with bit 1 set mismatches its own rounded cursor on
 * mret exactly as it would a JALR to the wrong address, and mret leaves PCC
 * detagged rather than installing it -- even though the capability read out
 * of mepc at face value still carries a tag.
 *
 * Whether misa.C can be cleared at all is WARL, so this whole block is
 * skipped wherever the write does not take -- every QEMU target here, since
 * none of them support writing misa beyond the Y bit. It is reachable on the
 * Sail model, which needed a fix: Sail's read_CSR clause for mepcc/sepcc
 * returned the raw register, self-documented as needing legalisation for
 * writable-misa.C implementations, while get_mepc()/get_sepc() and the
 * mret/sret return path already applied it correctly. Fixed upstream by
 * giving reads of the full capability the same align_pc() treatment.
 */
#define TEST_NAME "xepc-detag"
#include "testmacros.h"
#include "exceptions.h"

/* Write \reg (tagged) to \csr, read it back, and require the given tag. */
.macro EXPECT_XEPC_TAG csr, reg, tag, desc
    NEXT_TEST "\desc"
    csrw \csr, \reg
    csrrs a2, \csr, x0
    YTAGR t1, a2
    li   t2, \tag
    bne  t1, t2, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: csrw takes the full capability */

    /*
     * A small, tightly-bounded capability: shifting its cursor by one byte
     * stays comfortably representable, so representability cannot be what
     * decides the outcome below -- only the seal state can.
     */
    csrrs a0, CSR_DDC, x0
    la   t0, victim
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1

    /* Aligned: the tag survives the round trip (sanity/decode check). */
    EXPECT_XEPC_TAG CSR_MEPC, a0, 1, "mepc keeps the tag of an aligned capability"
    EXPECT_XEPC_TAG CSR_SEPC, a0, 1, "sepc keeps the tag of an aligned capability"

    /* Misaligned but unsealed: the address rounds down, the tag survives. */
    csrrs a1, CSR_DDC, x0
    la   t0, victim
    addi t0, t0, 1
    YADDRW a1, a1, t0
    li   t1, 8
    YBNDSW a1, a1, t1
    EXPECT_XEPC_TAG CSR_MEPC, a1, 1, "mepc keeps the tag of a misaligned unsealed capability"
    EXPECT_XEPC_TAG CSR_SEPC, a1, 1, "sepc keeps the tag of a misaligned unsealed capability"

    /* And that round-down is a real write: it comes back on a plain read too. */
    NEXT_TEST "the address is rounded down on a plain read"
    csrw CSR_MEPC, a1
    csrrs a2, CSR_MEPC, x0
    andi t1, a2, 1
    bnez t1, fail

    /* The same capability sealed as a sentry: now the tag is cleared. */
    YSENTRY a1, a1
    EXPECT_XEPC_TAG CSR_MEPC, a1, 0, "mepc clears the tag of a misaligned sentry"
    EXPECT_XEPC_TAG CSR_SEPC, a1, 0, "sepc clears the tag of a misaligned sentry"

    /*
     * Bit 1 only matters with IALIGN=32, and only on read: legalizing it on
     * write would round a compressed-but-momentarily-C-disabled target down
     * to the wrong instruction, so the specification (and QEMU's read_xepcc)
     * defer it to whichever read observes the value. Whether misa.C can be
     * cleared at all is WARL, so this whole block is skipped where it holds
     * at 1 regardless -- currently every QEMU target, not the Sail model.
     */
    SKIPPABLE_BLOCK_BEGIN
    TRY_CLEAR_MISA_C skip_ialign32

    csrrs a0, CSR_DDC, x0
    la   t0, victim
    ori  t0, t0, 2                /* bit 1 set, bit 0 clear: "aligned" for IALIGN=16 */
    YADDRW a0, a0, t0
    li   t1, 8
    YBNDSW a0, a0, t1

    /* Unsealed: the tag survives a plain read despite bit 1 being set. */
    EXPECT_XEPC_TAG CSR_MEPC, a0, 1, "mepc keeps the tag of an unsealed capability with bit 1 set"
    EXPECT_XEPC_TAG CSR_SEPC, a0, 1, "sepc keeps the tag of an unsealed capability with bit 1 set"

    /* But the address is rounded down on read, same as bit 0 above. */
    NEXT_TEST "bit 1 is rounded down on read under IALIGN=32"
    csrw CSR_MEPC, a0
    csrrs a1, CSR_MEPC, x0
    andi t1, a1, 2
    bnez t1, fail

    /* The same capability sealed: reading now legalizes bit 1 and detags. */
    YSENTRY a0, a0
    EXPECT_XEPC_TAG CSR_MEPC, a0, 0, "mepc clears the tag of a sentry with bit 1 set"
    EXPECT_XEPC_TAG CSR_SEPC, a0, 0, "sepc clears the tag of a sentry with bit 1 set"

    /*
     * mret computes its target the same way: it masks bit 1 out of the
     * address it is about to install, so a sentry stored with bit 1 set
     * mismatches its own (now-rounded) cursor. That is the same "wrong
     * address" case JALR takes as a tag violation, so mret leaves PCC
     * detagged rather than installing a capability nothing authorized --
     * even though the value read out of mepc, taken at face value, still
     * carried a tag.
     */
    NEXT_TEST "mret detags a sentry whose stored address had bit 1 set"
    auipc a0, 0
    la   t0, victim
    ori  t0, t0, 2
    YADDRW a0, a0, t0
    YSENTRY a0, a0
    RESUME_AFTER_FAULT ialign32_recovered
    csrw CSR_MEPC, a0
    li   t0, 0x1800                /* mstatus.MPP = M, so mret returns to M-mode */
    csrs CSR_MSTATUS, t0
    mret
ialign32_recovered:
    EXPECT_TRAP TRAP_CAP_FETCH(CAP_TAG)
    EXPECT_EPC_TAG 0

    li   t0, MISA_C               /* leave misa.C as this test found it */
    csrs CSR_MISA, t0
    j    ialign32_done
skip_ialign32:
    SKIPPABLE_BLOCK_SKIPPED "misa.C is hard-wired here so IALIGN=32 is unreachable"
ialign32_done:

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER_PCC

.balign 8
victim:
    j    fail
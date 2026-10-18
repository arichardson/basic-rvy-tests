/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify that for every memory access instruction (lw, sw, fld, fsd, ly, sy,
 * lr.w, sc.w, amoswap.w, lr.y, sc.y, amoswap.y, cbo.zero, cbo.clean,
 * cbo.flush, cbo.inval), an encoding with base register x0 behaves according
 * to the current CHERI execution mode:
 *  - Integer pointer mode: rs1=x0 contributes 0, so the effective address
 *    is simply the immediate; the DDC-relative bounds check passes (DDC is
 *    root) and the access proceeds to the underlying memory system. No
 *    CHERI-specific exception may occur.
 *  - Capability mode: all memory access instruction encodings with cs1=x0 are
 *    reserved in RVY (since dereferencing NULL in y0 always faults) and raise
 *    CAUSE_ILLEGAL_INSN by default. When target_info.cap_mode_x0_tag_fault is
 *    set (such as on CHERI 0.9.3), cs1=x0 instead faults on the untagged NULL
 *    capability with TRAP_CAP_LOAD(CAP_TAG) for loads and
 *    TRAP_CAP_STORE(CAP_TAG) for stores, AMOs, and CBOs.
 *
 * The test target address (0x400) is deliberately unmapped on the virt
 * machine: nothing needs to be readable/writable there, since the assertions
 * only care about which class of exception occurs, not about round-tripping
 * a value through real memory. In integer mode the unmapped address still
 * faults, but with a generic RISC-V access fault rather than a CHERI
 * exception -- exactly the distinction this test checks for. All
 * instructions use a 16-byte-aligned offset so alignment requirements (up to
 * CHERI_CAP_SIZE on RV64) are satisfied.
 */
#define TEST_NAME "loadstore-x0"
#include "testmacros.h"
#include "exceptions.h"

#define TEST_ADDR 0x400

#define x0_tag_fault s7
#pragma GCC poison s7

.macro EXPECT_X0_LOAD_TRAP
    beqz x0_tag_fault, 1f
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    j    2f
1:  EXPECT_TRAP CAUSE_ILLEGAL_INSN
2:
.endm

.macro EXPECT_X0_STORE_TRAP
    beqz x0_tag_fault, 1f
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    j    2f
1:  EXPECT_TRAP CAUSE_ILLEGAL_INSN
2:
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    LOAD_TARGET_FLAG x0_tag_fault, TARGET_INFO_OFF_CAP_MODE_X0_TAG_FAULT

    /* Enable the FPU (mstatus.FS = Initial) so fld/fsd do not trap. */
    li   t0, 1 << 13
    csrs CSR_MSTATUS, t0

    /*
     * Give the registers the stores use a defined value: what gets written
     * is not what is under test, and storing whatever reset left behind
     * makes the test depend on it.
     */
    li   t1, 0
    li   t2, 0

    /*
     * Integer pointer mode (the default at reset): rs1=x0 contributes 0, so
     * these are ordinary accesses to a low address. None may be refused on
     * capability grounds or rejected as an illegal instruction; whether that
     * address is readable at all is up to the machine.
     */
    NEXT_TEST "integer mode: lw through x0 is an ordinary access"
    lw   t1, TEST_ADDR(x0)
    EXPECT_ONLY_MEMORY_FAULT

    NEXT_TEST "integer mode: sw through x0 is an ordinary access"
    sw   t1, TEST_ADDR(x0)
    EXPECT_ONLY_MEMORY_FAULT

    NEXT_TEST "integer mode: fld through x0 is an ordinary access"
    fld  ft1, TEST_ADDR(x0)
    EXPECT_ONLY_MEMORY_FAULT

    NEXT_TEST "integer mode: fsd through x0 is an ordinary access"
    fsd  ft1, TEST_ADDR(x0)
    EXPECT_ONLY_MEMORY_FAULT

    NEXT_TEST "integer mode: ly through x0 is an ordinary access"
    LY   t1, TEST_ADDR(x0)
    EXPECT_ONLY_MEMORY_FAULT

    NEXT_TEST "integer mode: sy through x0 is an ordinary access"
    SY   t2, TEST_ADDR(x0)
    EXPECT_ONLY_MEMORY_FAULT

    /*
     * Capability mode: cs1=x0 is reserved (raising CAUSE_ILLEGAL_INSN by
     * default, or a tag fault when target_info.cap_mode_x0_tag_fault is set).
     */
    YMODESWY

    NEXT_TEST "capability mode: lw with cs1=x0 faults"
    lw   t1, TEST_ADDR(x0)
    EXPECT_X0_LOAD_TRAP

    NEXT_TEST "capability mode: sw with cs1=x0 faults"
    sw   t1, TEST_ADDR(x0)
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: fld with cs1=x0 faults"
    fld  ft1, TEST_ADDR(x0)
    EXPECT_X0_LOAD_TRAP

    NEXT_TEST "capability mode: fsd with cs1=x0 faults"
    fsd  ft1, TEST_ADDR(x0)
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: ly with cs1=x0 faults"
    LY   t1, TEST_ADDR(x0)
    EXPECT_X0_LOAD_TRAP

    NEXT_TEST "capability mode: sy with cs1=x0 faults"
    SY   t2, TEST_ADDR(x0)
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: lr.w with cs1=x0 faults"
    lr.w t1, (x0)
    EXPECT_X0_LOAD_TRAP

    NEXT_TEST "capability mode: sc.w with cs1=x0 faults"
    sc.w t1, t2, (x0)
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: amoswap.w with cs1=x0 faults"
    amoswap.w t1, t2, (x0)
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: lr.y with cs1=x0 faults"
    LR_Y t1, x0
    EXPECT_X0_LOAD_TRAP

    NEXT_TEST "capability mode: sc.y with cs1=x0 faults"
    SC_Y t1, x0, t2
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: amoswap.y with cs1=x0 faults"
    AMOSWAP_Y t1, x0, t2
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: cbo.zero with cs1=x0 faults"
    CBO_ZERO x0
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: cbo.clean with cs1=x0 faults"
    CBO_CLEAN x0
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: cbo.flush with cs1=x0 faults"
    CBO_FLUSH x0
    EXPECT_X0_STORE_TRAP

    NEXT_TEST "capability mode: cbo.inval with cs1=x0 faults"
    CBO_INVAL x0
    EXPECT_X0_STORE_TRAP

    YMODESWI                     /* back to int mode */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

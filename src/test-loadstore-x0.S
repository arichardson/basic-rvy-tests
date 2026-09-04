/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify that for every load/store (lw, sw, fld, fsd, ly, sy), an encoding
 * with base register x0 behaves according to the current CHERI execution
 * mode:
 *  - Integer pointer mode: rs1=x0 contributes 0, so the effective address
 *    is simply the immediate; the DDC-relative bounds check passes (DDC is
 *    root) and the access proceeds to the underlying memory system. No
 *    CHERI-specific exception may occur.
 *  - Capability mode: cs1=x0 selects capability register c0, which is the
 *    NULL capability (untagged); this must be rejected with a CHERI tag
 *    violation before any memory access is attempted. Loads must report
 *    CHERI Load Access Fault and stores CHERI Store/AMO Access Fault: the
 *    cause is selected by the access type, not by the failing check (a tag
 *    violation is not a load-only fault).
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

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

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
     * Capability mode: cs1=x0 is the NULL capability, so every access is
     * rejected by the tag check before the memory system sees it.
     */
    YMODESWY

    NEXT_TEST "capability mode: lw through the NULL capability is a tag fault"
    lw   t1, TEST_ADDR(x0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    NEXT_TEST "capability mode: sw through the NULL capability is a tag fault"
    sw   t1, TEST_ADDR(x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    NEXT_TEST "capability mode: fld through the NULL capability is a tag fault"
    fld  ft1, TEST_ADDR(x0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    NEXT_TEST "capability mode: fsd through the NULL capability is a tag fault"
    fsd  ft1, TEST_ADDR(x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    NEXT_TEST "capability mode: ly through the NULL capability is a tag fault"
    LY   t1, TEST_ADDR(x0)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    NEXT_TEST "capability mode: sy through the NULL capability is a tag fault"
    SY   t2, TEST_ADDR(x0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)

    YMODESWI                     /* back to int mode */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

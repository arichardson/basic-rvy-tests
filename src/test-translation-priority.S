/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Faults raised by the page table walk for an explicit memory access, and
 * where they sit relative to the capability checks, per the synchronous
 * exception priority table. Every case is run for each instruction that can
 * reach the walk (ly, sy, lr.y, sc.y and amoswap.y) and verifies that a
 * faulting operation neither overwrites cd (poisoned beforehand) nor modifies
 * the tagged capabilities stored in buf.
 *
 * The walk can fail for the ordinary reasons the base ISA already has (an
 * invalid PTE, missing read or write permission, an unset accessed or dirty
 * bit) and for the two CHERI ones the pte.rvy field adds. Table
 * "Synchronous exception priority in decreasing priority order for RVY"
 * (exception-priority-cheri in the Smy chapter) and Section "Virtual Address
 * Translation Process" (sv32algorithm_rvy in the Svyrg chapter, and
 * sv32algorithm in the Supervisor chapter) place them as follows:
 *
 *  - Capability checks happen *prior to* address translation
 *    (exception-priority-cheri: "Prior to address translation for an explicit
 *    memory access: CHERI Load Access Fault (33), CHERI Store/AMO Access
 *    Fault (34) due to capability checks"), so a capability that fails one
 *    reports its own fault whatever the walk would have done with the address
 *    it names.
 *  - A misaligned capability access sits between the capability checks and
 *    address translation in exception-priority-cheri, and reports an access
 *    fault (5/7) rather than a misaligned fault (4/6) since it cannot be
 *    emulated in software.
 *  - During address translation, CHERI Store/AMO Page Fault (36), standard
 *    page faults (13/15), and PTW access faults (5/7) share a single row in
 *    exception-priority-cheri ("First encountered CHERI Store/AMO Page Fault,
 *    page fault or access fault"). In the Virtual Address Translation Process
 *    (sv32algorithm_rvy / sv32algorithm), a PTE is checked in step order:
 *      * Step 3: pte.v=0 or reserved encoding -> page fault (13/15)
 *      * Step 5: misaligned superpage -> page fault (13/15)
 *      * Step 6: pte.u (privilege mode / sstatus.SUM / mstatus.MXR) -> page
 *        fault (13/15), outranking Step 7 (36) and post-translation (35)
 *      * Step 7: pte.rvy capability store check (pte.yw=0 when YRGE=1, or
 *        pte.y=0 when YRGE=0, with to-be-stored tag=1 per
 *        pte_rvy_store_summary) -> CHERI Store/AMO Page Fault (36),
 *        outranking Step 9 (15)
 *      * Step 8: Shadow Stack (Zicfiss) pte.r/w/x rules -> access fault (5/7)
 *      * Step 9: pte.r, pte.w, and pte.x -> page fault (13/15), outranking
 *        post-translation (35)
 *      * Step 10: pte.a=0, pte.d=0, or pte.yd=0 with to-be-stored tag=1
 *  - A CHERI Load Capability Fault (35) is the *lowest* priority entry in
 *    exception-priority-cheri (below all translation faults 36/13/15/5/7,
 *    physical access faults 5/7, and misaligned faults 4/6), even when an
 *    implementation traps conservatively without checking the loaded tag.
 *
 * The sections below follow the algorithm steps in order, and within each
 * step check both the fault on its own and its priority over later steps.
 *
 * Each ordering is paired with a control that removes the higher-priority
 * condition and requires the lower-priority one to appear on its own.
 * Without it "the expected exception was reported" would also pass on an
 * implementation where the loser was never possible to begin with.
 *
 * Whether an unset accessed or dirty bit faults at all is a property of the
 * implementation, not the architecture: Svade makes the walk fault so that
 * software sets the bit, Svadu sets it in hardware and the access proceeds.
 * Neither is assumed. The A/D behaviour is probed once at run time and the
 * cases below expect whichever it turns out to be. The pte is rewritten
 * before every such case, because a hardware update makes the next attempt
 * succeed and would otherwise mask a difference.
 *
 * A store cannot raise 35 (it loads no tag), so the 35 cases cover only the
 * three instructions that read one. The remaining table row involving
 * translation, CHERI Store/AMO Page Fault (36) against 35 for an AMO, is
 * already covered by test-svyrg.
 *
 * sc.y can only be driven as far as the walk when it has a valid
 * reservation, since an sc.* whose reservation is not valid may fail without
 * performing the memory access at all. Where a page permits the lr.y but
 * refuses the sc.y it is paired with one; where the lr.y itself faults, sc.y
 * cannot reach the walk and only the checks that outrank the reservation are
 * asserted for it.
 */
#define TEST_NAME "translation-priority"
#ifdef CHERI_093
#error "Requires RVY >= 0.9.7 for the pte.rvy field and the RVY exception priority order"
#endif
#include "testmacros.h"
#include "exceptions.h"

/* Leaf PTE permission and status bits. */
#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_U 0x10
#define PTE_A 0x40
#define PTE_D 0x80

#define PTE_YR_BIT  (1 << 55)
#define PTE_YRG_BIT (1 << 56)
#define PTE_YW_BIT  (1 << 57)
#define PTE_YD_BIT  (1 << 58)

#define SSTATUS_SUM  (1 << 18)
#define SSTATUS_YRGE (1 << 59)
#define SSTATUS_SYRG (1 << 60)
#define SSTATUS_UYRG (1 << 61)

/*
 * yrg=1 matches sstatus.SYRG and sstatus.UYRG below, so loads are normal;
 * yw|yd allow capability stores. Every page except the CHERI-faulting ones
 * carries this, so that only the base ISA bits decide what happens.
 */
#define RVY_NORMAL (PTE_YRG_BIT | PTE_YW_BIT | PTE_YD_BIT)

/* The pages, by root table index; all of them alias PA 0x80000000. */
#define IDX_CODE          2      /* VA 0x0_80000000: code and data */
#define IDX_OK            3      /* VA 0x0_C0000000: everything permitted */
#define IDX_INVALID       4      /* VA 0x1_00000000: Step 3: V=0 */
#define IDX_USER_NOYW     5      /* VA 0x1_40000000: Step 6 vs Step 7: U-page + yw=0 */
#define IDX_USER          6      /* VA 0x1_80000000: Step 6 vs 35: U-page + yr=1/yrg=0 */
#define IDX_NOYW          7      /* VA 0x1_C0000000: Step 7: yw=0, raises 36 */
#define IDX_NOREAD_NOYW   8      /* VA 0x2_00000000: Step 7 vs Step 9: execute only + yw=0 */
#define IDX_NOWRITE_NOYW  9      /* VA 0x2_40000000: Step 7 vs Step 9: read only + yw=0 */
#define IDX_NOREAD       10      /* VA 0x2_80000000: Step 9: execute only */
#define IDX_NOWRITE      11      /* VA 0x2_C0000000: Step 9: read only */
#define IDX_NOREAD_YRG   12      /* VA 0x3_00000000: Step 9 vs 35: execute only + yr=1/yrg=0 */
#define IDX_NOWRITE_YRG  13      /* VA 0x3_40000000: Step 9 vs 35: read only + yr=1/yrg=0 */
#define IDX_NOACCESS     14      /* VA 0x3_80000000: Step 10: A=0 */
#define IDX_NODIRTY      15      /* VA 0x3_C0000000: Step 10: D=0 */
#define IDX_YRG          16      /* VA 0x4_00000000: Lowest: yr=1/yrg=0, raises 35 */

#define VA_OF(idx) ((idx) << 30)
/* buf is linked into the code page, so an alias of it is this far along. */
#define ALIAS_OFF(idx) (((idx) - IDX_CODE) << 30)

#define PTE_NOACCESS (PTE_V | PTE_R | PTE_W | PTE_D | RVY_NORMAL)
#define PTE_NODIRTY  (PTE_V | PTE_R | PTE_W | PTE_A | RVY_NORMAL)

/* s7 records the probe result: 1 if A/D are updated in hardware (Svadu). */
#define ad_in_hardware s7

/* Write the leaf pte for \idx and flush. Integer pointer mode only. */
.macro SET_PTE idx, bits
    lla   t0, pagetable
    li   t3, 0x80000 << 10
    li   t4, \bits
    or   t4, t4, t3
    sd   t4, (\idx * 8)(t0)
    sfence.vma
.endm

/*
 * The same from capability mode, where the pagetable store would otherwise
 * take t0 as the authorizing capability rather than as an address. Used to
 * put an A/D case back the way it started, since a hardware update leaves
 * the bit set and the next attempt would then not fault.
 */
.macro RESET_PTE idx, bits
    YMODESWI
    SET_PTE \idx, \bits
    YMODESWY
.endm

/* Derive \cd from the root ddc, naming buf through the \idx alias. */
.macro CAP_TO_ALIAS cd, idx
    csrrs \cd, CSR_DDC, x0
    lla   t0, buf
    li   t1, ALIAS_OFF(\idx)
    add  t0, t0, t1
    YADDRW \cd, \cd, t0
.endm

.macro CHECK_BUF
    LY   t0, 0(a5)
    EXPECT_CAP_EQ t0, s2
    LY   t0, YLEN_BYTES(a5)
    EXPECT_CAP_EQ t0, s2
    SY   s2, 0(a5)
    SY   s2, YLEN_BYTES(a5)
.endm

/*
 * \cause where the implementation faults so software can set the A/D bit,
 * nothing at all where it sets the bit in hardware.
 */
.macro EXPECT_AD_LOAD_FAULT cause
    beqz ad_in_hardware, 70f
    EXPECT_NO_TRAP
    j    71f
70: EXPECT_TRAP \cause
    CHECK_POISON_REG t1
71:
.endm

.macro EXPECT_AD_STORE_FAULT cause
    beqz ad_in_hardware, 70f
    EXPECT_NO_TRAP
    SY   s2, 0(a5)
    j    71f
70: EXPECT_TRAP \cause
    CHECK_BUF
71:
.endm

.macro EXPECT_AD_AMO_FAULT cause
    beqz ad_in_hardware, 70f
    EXPECT_NO_TRAP
    SY   s2, 0(a5)
    j    71f
70: EXPECT_TRAP \cause
    CHECK_POISON_REG t1
    CHECK_BUF
71:
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* A tagged root capability, which the stores below write out. */
    csrrs s2, CSR_DDC, x0

    /* PMP entry 0: allow everything (required for S-mode accesses). */
    li   t0, -1
    csrw CSR_PMPADDR0, t0
    li   t0, 0x1f
    csrw CSR_PMPCFG0, t0

    li   t0, MENVCFG_CRE
    csrs CSR_MENVCFG, t0

    /*
     * Svyrg on, and both SYRG and UYRG set so any S-page or U-page with yrg=0
     * is a generation mismatch. SUM stays clear: the U-page priority cases
     * need a U-page S-mode may not reach unless SUM is temporarily set for the
     * control.
     */
    li   t0, SSTATUS_YRGE | SSTATUS_SYRG | SSTATUS_UYRG
    csrs CSR_MSTATUS, t0

    /*
     * Sv39 root table: gigapage leaves all mapping PA 0x80000000, so every
     * alias names the same buffer through a different set of PTE bits.
     */
    SET_PTE IDX_CODE, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_OK, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | RVY_NORMAL
    /* IDX_INVALID is left as the zero the .bss gives it: V=0. */
    SET_PTE IDX_USER_NOYW, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_U \
                           | PTE_YRG_BIT
    SET_PTE IDX_USER, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_U \
                      | PTE_YR_BIT | PTE_YW_BIT | PTE_YD_BIT
    SET_PTE IDX_NOYW, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_YRG_BIT
    SET_PTE IDX_NOREAD_NOYW, PTE_V | PTE_X | PTE_A | PTE_D | PTE_YRG_BIT
    SET_PTE IDX_NOWRITE_NOYW, PTE_V | PTE_R | PTE_A | PTE_D | PTE_YRG_BIT
    SET_PTE IDX_NOREAD, PTE_V | PTE_X | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_NOWRITE, PTE_V | PTE_R | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_NOREAD_YRG, PTE_V | PTE_X | PTE_A | PTE_D | PTE_YR_BIT \
                            | PTE_YW_BIT | PTE_YD_BIT
    SET_PTE IDX_NOWRITE_YRG, PTE_V | PTE_R | PTE_A | PTE_D | PTE_YR_BIT \
                             | PTE_YW_BIT | PTE_YD_BIT
    SET_PTE IDX_NOACCESS, PTE_NOACCESS
    SET_PTE IDX_NODIRTY, PTE_NODIRTY
    SET_PTE IDX_YRG, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_YR_BIT \
                     | PTE_YW_BIT | PTE_YD_BIT

    /* satp = Sv39 | PPN(pagetable) */
    lla   t0, pagetable
    srli t0, t0, 12
    li   t1, 8 << 60
    or   t0, t0, t1
    csrw 0x180, t0               /* satp */
    sfence.vma

    /* Enter S-mode */
    li   t0, 0x1800
    csrc CSR_MSTATUS, t0
    li   t0, 0x0800
    csrs CSR_MSTATUS, t0
    lla   t0, s_entry
    csrw CSR_MEPC, t0
    mret

s_entry:
    YMODESWY                     /* capability mode: these all take a capability */

    /* a0 = a valid root-derived capability naming buf on the invalid page. */
    CAP_TO_ALIAS a0, IDX_INVALID

    /* a1 = the same address, untagged: the capability check fails first. */
    YUNSEALS a1, x0, a0

    /* a2 = the same page, misaligned for a capability access. */
    YADDI a2, a0, 4

    CAP_TO_ALIAS a5, IDX_OK      /* everything permitted: the well-formed control */
    CAP_TO_ALIAS s0, IDX_NOACCESS

    li   t0, 0xdeadbeef
    YADDRW t2, s2, t0            /* distinct tagged store source for faulting stores/AMOs */
    SY   s2, 0(a5)
    SY   s2, YLEN_BYTES(a5)

    /*
     * Probe how the implementation handles an unset accessed bit: Svade
     * faults so software can set it, Svadu sets it in hardware and the load
     * completes. Everything A/D below expects whichever this finds.
     */
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    li   ad_in_hardware, 1
    mv   t4, trap_count
    LY   t1, 0(s0)
    beq  t4, trap_count, 1f
    li   ad_in_hardware, 0
1:
    CLEAR_TRAPS

    /* ---- Pre-walk: capability checks (33/34) outrank the walk ---------- */

    NEXT_TEST "an untagged capability outranks the page fault for ly"
    POISON_REG t1
    LY   t1, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    CHECK_POISON_REG t1
    NEXT_TEST "control: the same address tagged takes the page fault"
    POISON_REG t1
    LY   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "an untagged capability outranks the page fault for sy"
    SY   t2, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_BUF
    NEXT_TEST "control: the same address tagged takes the store page fault"
    SY   t2, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF

    NEXT_TEST "an untagged capability outranks the page fault for lr.y"
    POISON_REG t1
    LR_Y t1, a1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    CHECK_POISON_REG t1
    NEXT_TEST "control: the same address tagged takes the page fault"
    POISON_REG t1
    LR_Y t1, a0
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "an untagged capability outranks the page fault for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a1, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: the same address tagged takes the store page fault"
    POISON_REG t1
    AMOSWAP_Y t1, a0, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    NEXT_TEST "an untagged capability outranks the reservation check for sc.y"
    POISON_REG t1
    SC_Y t1, a1, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: a well formed sc.y raises no capability fault"
    POISON_REG t1
    SC_Y t1, a5, t2
    EXPECT_NO_TRAP
    EXPECT_NONZERO t1
    CHECK_BUF

    /* ---- Pre-walk: misaligned capability accesses (5/7) outrank walk --- */

    NEXT_TEST "a misaligned ly outranks the page fault"
    POISON_REG t1
    LY   t1, 0(a2)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    CHECK_POISON_REG t1
    NEXT_TEST "control: the aligned ly takes the page fault"
    POISON_REG t1
    LY   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "a misaligned sy outranks the store page fault"
    SY   t2, 0(a2)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    CHECK_BUF
    NEXT_TEST "control: the aligned sy takes the store page fault"
    SY   t2, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF

    NEXT_TEST "a misaligned lr.y outranks the page fault"
    POISON_REG t1
    LR_Y t1, a2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    CHECK_POISON_REG t1
    NEXT_TEST "control: the aligned lr.y takes the page fault"
    POISON_REG t1
    LR_Y t1, a0
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1

    NEXT_TEST "a misaligned amoswap.y outranks the store page fault"
    POISON_REG t1
    AMOSWAP_Y t1, a2, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: the aligned amoswap.y takes the store page fault"
    POISON_REG t1
    AMOSWAP_Y t1, a0, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    NEXT_TEST "a misaligned sc.y outranks the reservation check"
    POISON_REG t1
    SC_Y t1, a2, t2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: an aligned sc.y raises no misaligned fault"
    POISON_REG t1
    SC_Y t1, a5, t2
    EXPECT_NO_TRAP
    EXPECT_NONZERO t1
    CHECK_BUF

    /* ---- Walk Step 3: invalid PTE (pte.v=0 -> 13/15) ------------------- */

    NEXT_TEST "an invalid pte faults an ly"
    POISON_REG t1
    LY   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    NEXT_TEST "an invalid pte faults an sy"
    SY   t2, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF
    NEXT_TEST "an invalid pte faults an lr.y"
    POISON_REG t1
    LR_Y t1, a0
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    NEXT_TEST "an invalid pte faults an amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a0, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    /* ---- Walk Step 6: user page check (pte.u=1, SUM=0 -> 13/15) -------- */

    /*
     * In sv32algorithm_rvy, Step 6 checks pte.u (given privilege mode and
     * sstatus.SUM) before Step 7 checks pte.rvy for capability stores (36) and
     * before the post-translation CHERI Load Capability Fault (35). Each
     * ordering is paired with a control that sets sstatus.SUM=1 so Step 6
     * passes and the lower-priority fault is reported.
     */
    CAP_TO_ALIAS a3, IDX_USER_NOYW    /* U-page + yw=0: Step 6 vs Step 7 (36) */
    CAP_TO_ALIAS a4, IDX_USER         /* U-page + yr=1/yrg=0: Step 6 vs 35 */

    NEXT_TEST "a user page fault at step 6 outranks the store capability page fault at step 7 for sy"
    SY   t2, 0(a3)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF
    li   t0, SSTATUS_SUM
    csrs sstatus, t0
    NEXT_TEST "control: with sstatus.SUM set, the user page with yw=0 faults at step 7 for sy"
    SY   t2, 0(a3)
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF
    li   t0, SSTATUS_SUM
    csrc sstatus, t0

    NEXT_TEST "a user page fault at step 6 outranks the store capability page fault at step 7 for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a3, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF
    li   t0, SSTATUS_SUM
    csrs sstatus, t0
    NEXT_TEST "control: with sstatus.SUM set, the user page with yw=0 faults at step 7 for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a3, t2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF
    li   t0, SSTATUS_SUM
    csrc sstatus, t0

    NEXT_TEST "a user page fault at step 6 outranks the load capability fault for ly"
    POISON_REG t1
    LY   t1, 0(a4)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    li   t0, SSTATUS_SUM
    csrs sstatus, t0
    NEXT_TEST "control: with sstatus.SUM set, the user mismatching page raises a load capability fault for ly"
    POISON_REG t1
    LY   t1, 0(a4)
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    li   t0, SSTATUS_SUM
    csrc sstatus, t0

    NEXT_TEST "a user page fault at step 6 outranks the load capability fault for lr.y"
    POISON_REG t1
    LR_Y t1, a4
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    li   t0, SSTATUS_SUM
    csrs sstatus, t0
    NEXT_TEST "control: with sstatus.SUM set, the user mismatching page raises a load capability fault for lr.y"
    POISON_REG t1
    LR_Y t1, a4
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    li   t0, SSTATUS_SUM
    csrc sstatus, t0

    NEXT_TEST "a user page fault at step 6 outranks the load capability fault for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a4, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF
    li   t0, SSTATUS_SUM
    csrs sstatus, t0
    NEXT_TEST "control: with sstatus.SUM set, the user mismatching page raises a load capability fault for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a4, t2
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    CHECK_BUF
    li   t0, SSTATUS_SUM
    csrc sstatus, t0

    /* ---- Walk Step 7: capability store check (pte.yw=0, tag=1 -> 36) --- */

    /*
     * Step 7 checks pte.rvy for capability stores (raising 36 when pte.yw=0
     * and the to-be-stored capability tag is 1 per pte_rvy_store_summary)
     * before Step 9 checks pte.r, pte.w, and pte.x (15). Each Step 7 vs Step 9
     * case is paired with an untagged store (x0, tag=0) that passes Step 7 and
     * faults at Step 9.
     */
    CAP_TO_ALIAS a3, IDX_NOYW         /* yw=0: raises 36 on its own */
    CAP_TO_ALIAS a4, IDX_NOREAD_NOYW  /* X-only + yw=0: Step 7 vs Step 9 (R=0) */
    CAP_TO_ALIAS a6, IDX_NOWRITE_NOYW /* R-only + yw=0: Step 7 vs Step 9 (W=0) */

    NEXT_TEST "a page with yw=0 raises a store capability page fault on its own for sy"
    SY   t2, 0(a3)
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF
    NEXT_TEST "a page with yw=0 raises a store capability page fault on its own for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a3, t2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "a page with yw=0 permits the lr.y that reserves the address"
    LR_Y t1, a3
    EXPECT_NO_TRAP
    NEXT_TEST "and raises a store capability page fault on the sc.y"
    POISON_REG t1
    SC_Y t1, a3, t2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF

    NEXT_TEST "the store capability page fault at step 7 outranks missing write permission at step 9 for sy"
    SY   t2, 0(a6)
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_BUF
    NEXT_TEST "control: an untagged sy on the same W=0, yw=0 page passes step 7 and faults at step 9"
    SY   x0, 0(a6)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF

    NEXT_TEST "the store capability page fault at step 7 outranks missing read permission at step 9 for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a4, t2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: an untagged amoswap.y on the same R=0, yw=0 page passes step 7 and faults at step 9"
    POISON_REG t1
    AMOSWAP_Y t1, a4, x0
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    NEXT_TEST "the store capability page fault at step 7 outranks missing write permission at step 9 for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a6, t2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: an untagged amoswap.y on the same W=0, yw=0 page passes step 7 and faults at step 9"
    POISON_REG t1
    AMOSWAP_Y t1, a6, x0
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    NEXT_TEST "a read-only page with yw=0 also permits the lr.y that reserves the address"
    LR_Y t1, a6
    EXPECT_NO_TRAP
    NEXT_TEST "and the store capability page fault at step 7 outranks missing write permission at step 9 on sc.y"
    POISON_REG t1
    SC_Y t1, a6, t2
    EXPECT_TRAP CAUSE_CHERI_STORE_PAGE
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "control: an untagged sc.y on the same W=0, yw=0 page passes step 7 and faults at step 9"
    LR_Y t1, a6
    EXPECT_NO_TRAP
    POISON_REG t1
    SC_Y t1, a6, x0
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    /* ---- Walk Step 9: leaf pte.r / pte.w checks (13/15) ---------------- */

    CAP_TO_ALIAS a3, IDX_NOREAD       /* execute-only (R=0, W=0) */
    CAP_TO_ALIAS a4, IDX_NOWRITE      /* read-only (W=0) */
    CAP_TO_ALIAS a6, IDX_NOREAD_YRG   /* execute-only + yr=1/yrg=0 */
    CAP_TO_ALIAS a7, IDX_NOWRITE_YRG  /* read-only + yr=1/yrg=0 */

    /*
     * No read permission (an execute-only page). An AMO needs to read as
     * well as write, so it is refused here too, as a store/AMO fault.
     */
    NEXT_TEST "an execute-only page refuses an ly"
    POISON_REG t1
    LY   t1, 0(a3)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    NEXT_TEST "an execute-only page refuses an lr.y"
    POISON_REG t1
    LR_Y t1, a3
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    NEXT_TEST "an execute-only page refuses an sy"
    SY   t2, 0(a3)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF
    NEXT_TEST "an execute-only page refuses an amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a3, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    /*
     * No write permission (a read-only page). Loads go through, so the lr.y
     * also gives the sc.y below a valid reservation to be refused with.
     */
    NEXT_TEST "a read-only page still permits an ly"
    LY   t1, 0(a4)
    EXPECT_NO_TRAP
    NEXT_TEST "a read-only page refuses an sy"
    SY   t2, 0(a4)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_BUF
    NEXT_TEST "a read-only page refuses an amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a4, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "a read-only page permits the lr.y that reserves the address"
    LR_Y t1, a4                  /* permitted, and reserves the address */
    EXPECT_NO_TRAP
    NEXT_TEST "and refuses the sc.y that reservation lets reach the walk"
    POISON_REG t1
    SC_Y t1, a4, t2              /* ... so this reaches the walk and is refused */
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    /*
     * Step 9 page faults (13/15) outrank the post-translation CHERI Load
     * Capability Fault (35); the Lowest section below confirms that the same
     * yr=1/yrg=0 PTE with R=1 and W=1 raises 35.
     */
    NEXT_TEST "missing read permission at step 9 outranks the load capability fault for ly"
    POISON_REG t1
    LY   t1, 0(a6)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    NEXT_TEST "missing read permission at step 9 outranks the load capability fault for lr.y"
    POISON_REG t1
    LR_Y t1, a6
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    CHECK_POISON_REG t1
    NEXT_TEST "missing read permission at step 9 outranks the load capability fault for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a6, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF
    NEXT_TEST "missing write permission at step 9 outranks the load capability fault for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a7, t2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    CHECK_POISON_REG t1
    CHECK_BUF

    /* ---- Walk Step 10: accessed and dirty bits (pte.a=0, pte.d=0) ------ */

    CAP_TO_ALIAS s0, IDX_NOACCESS
    CAP_TO_ALIAS s1, IDX_NODIRTY

    /*
     * An unset accessed bit, which affects reads and writes alike. The pte
     * is rewritten before each case so a hardware update does not leave the
     * bit set for the next one.
     */
    NEXT_TEST "an unset accessed bit and an ly"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    POISON_REG t1
    LY   t1, 0(s0)
    EXPECT_AD_LOAD_FAULT CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an unset accessed bit and an sy"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    SY   t2, 0(s0)
    EXPECT_AD_STORE_FAULT CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an unset accessed bit and an lr.y"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    POISON_REG t1
    LR_Y t1, s0
    EXPECT_AD_LOAD_FAULT CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an unset accessed bit and an amoswap.y"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    POISON_REG t1
    AMOSWAP_Y t1, s0, t2
    EXPECT_AD_AMO_FAULT CAUSE_STORE_PAGE_FAULT

    /*
     * An unset dirty bit, which only writes care about: the load is
     * unaffected either way, and also reserves the address for the sc.y.
     */
    NEXT_TEST "an unset dirty bit does not affect an ly"
    RESET_PTE IDX_NODIRTY, PTE_NODIRTY
    LY   t1, 0(s1)
    EXPECT_NO_TRAP
    NEXT_TEST "an unset dirty bit and an sy"
    RESET_PTE IDX_NODIRTY, PTE_NODIRTY
    SY   t2, 0(s1)
    EXPECT_AD_STORE_FAULT CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an unset dirty bit and an amoswap.y"
    RESET_PTE IDX_NODIRTY, PTE_NODIRTY
    POISON_REG t1
    AMOSWAP_Y t1, s1, t2
    EXPECT_AD_AMO_FAULT CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an unset dirty bit permits the lr.y that reserves the address"
    RESET_PTE IDX_NODIRTY, PTE_NODIRTY
    LR_Y t1, s1
    EXPECT_NO_TRAP
    NEXT_TEST "and the sc.y that reservation lets reach the walk"
    POISON_REG t1
    SC_Y t1, s1, t2
    EXPECT_AD_AMO_FAULT CAUSE_STORE_PAGE_FAULT

    /* ---- Lowest: CHERI Load Capability Fault (35) ---------------------- */

    /*
     * Per exception-priority-cheri, CHERI Load Capability Fault (35) sits at
     * the very bottom of the synchronous exception priority table, after the
     * walk and memory read have completed; these also serve as the controls
     * for the Step 9 vs 35 cases above.
     */
    CAP_TO_ALIAS a3, IDX_YRG          /* yr=1/yrg=0: raises 35 on its own */

    NEXT_TEST "the mismatching page raises a load capability fault on its own for ly"
    POISON_REG t1
    LY   t1, 0(a3)
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    NEXT_TEST "the mismatching page raises a load capability fault on its own for lr.y"
    POISON_REG t1
    LR_Y t1, a3
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    NEXT_TEST "the mismatching page raises a load capability fault on its own for amoswap.y"
    POISON_REG t1
    AMOSWAP_Y t1, a3, t2
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    CHECK_POISON_REG t1
    CHECK_BUF

    YMODESWI
    lla   m_continue, m_done
    ecall
m_done:
    TEST_PASS
fail:
    /*
     * S-mode with paging on cannot reach the finisher device, so report from
     * M-mode.
     */
    YMODESWI
    lla   m_continue, m_fail
    ecall
m_fail:
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
pagetable:
    .space 4096
.balign 16
buf:
    .space 64

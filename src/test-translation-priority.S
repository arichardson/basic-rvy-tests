/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Faults raised by the page table walk for an explicit memory access, and
 * where they sit relative to the capability checks, per the synchronous
 * exception priority table. Every case is run for each instruction that can
 * reach the walk: ly, sy, lr.y, sc.y and amoswap.y.
 *
 * The walk can fail for the ordinary reasons the base ISA already has (an
 * invalid PTE, missing read or write permission, an unset accessed or dirty
 * bit) and for the two CHERI ones the pte.rvy field adds. The priority table
 * places them as follows, and each ordering below is one entry of it:
 *
 *  1. Capability checks happen *prior to* address translation, so a
 *     capability that fails one reports its own fault (33/34) whatever the
 *     walk would have done with the address it names.
 *  2. A misaligned capability access also outranks the walk, and reports an
 *     access fault rather than a misaligned fault, since it cannot be
 *     emulated in software.
 *  3. A CHERI Load Capability Fault (35) is the *lowest* priority entry in
 *     the entire table, below even the page faults produced by the same walk
 *     that decided it.
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
 * A store cannot raise 35 (it loads no tag), so ordering 3 covers only the
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
#error "RVY v0.9.9 only: the pte.rvy field and its faults are a v0.9.9 addition"
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

/*
 * yrg=1 matches sstatus.SYRG below, so loads are normal; yw|yd allow
 * capability stores. Every page except the two CHERI ones carries this, so
 * that only the base ISA bits decide what happens.
 */
#define RVY_NORMAL (PTE_YRG_BIT | PTE_YW_BIT | PTE_YD_BIT)

/* The pages, by root table index; all of them alias PA 0x80000000. */
#define IDX_CODE      2          /* VA 0x0_80000000: code and data */
#define IDX_OK        3          /* VA 0x0_C0000000: everything permitted */
#define IDX_YRG       4          /* VA 0x1_00000000: yr=1/yrg=0, raises 35 */
#define IDX_USER      5          /* VA 0x1_40000000: the same, but a U-page */
#define IDX_INVALID   6          /* VA 0x1_80000000: V=0 */
#define IDX_NOREAD    7          /* VA 0x1_C0000000: execute only */
#define IDX_NOWRITE   8          /* VA 0x2_00000000: read only */
#define IDX_NOACCESS  9          /* VA 0x2_40000000: A=0 */
#define IDX_NODIRTY  10          /* VA 0x2_80000000: D=0 */

#define VA_OF(idx) ((idx) << 30)
/* buf is linked into the code page, so an alias of it is this far along. */
#define ALIAS_OFF(idx) (((idx) - IDX_CODE) << 30)

#define PTE_NOACCESS (PTE_V | PTE_R | PTE_W | PTE_D | RVY_NORMAL)
#define PTE_NODIRTY  (PTE_V | PTE_R | PTE_W | PTE_A | RVY_NORMAL)

/* s7 records the probe result: 1 if A/D are updated in hardware (Svadu). */
#define ad_in_hardware s7

/* Write the leaf pte for \idx and flush. Integer pointer mode only. */
.macro SET_PTE idx, bits
    la   t0, pagetable
    li   t1, 0x80000 << 10
    li   t2, \bits
    or   t2, t2, t1
    sd   t2, (\idx * 8)(t0)
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
    la   t0, buf
    li   t1, ALIAS_OFF(\idx)
    add  t0, t0, t1
    YADDRW \cd, \cd, t0
.endm

/*
 * \cause where the implementation faults so software can set the A/D bit,
 * nothing at all where it sets the bit in hardware.
 */
.macro EXPECT_AD_FAULT cause
    beqz ad_in_hardware, 70f
    EXPECT_NO_TRAP
    j    71f
70: EXPECT_TRAP \cause
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
     * Svyrg on, and SYRG set so a page with yrg=0 is the mismatching one.
     * SUM stays clear: ordering 3 needs a U-page S-mode may not reach.
     */
    li   t0, SSTATUS_YRGE | SSTATUS_SYRG
    csrs CSR_MSTATUS, t0

    /*
     * Sv39 root table: gigapage leaves all mapping PA 0x80000000, so every
     * alias names the same buffer through a different set of PTE bits.
     */
    SET_PTE IDX_CODE, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_OK, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_YRG, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_YR_BIT \
                     | PTE_YW_BIT | PTE_YD_BIT
    SET_PTE IDX_USER, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_U \
                      | PTE_YR_BIT | PTE_YW_BIT | PTE_YD_BIT
    /* IDX_INVALID is left as the zero the .bss gives it: V=0. */
    SET_PTE IDX_NOREAD, PTE_V | PTE_X | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_NOWRITE, PTE_V | PTE_R | PTE_A | PTE_D | RVY_NORMAL
    SET_PTE IDX_NOACCESS, PTE_NOACCESS
    SET_PTE IDX_NODIRTY, PTE_NODIRTY

    /* satp = Sv39 | PPN(pagetable) */
    la   t0, pagetable
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
    la   t0, s_entry
    csrw CSR_MEPC, t0
    mret

s_entry:
    YMODESWY                     /* capability mode: these all take a capability */

    /* a0 = a valid root-derived capability naming the invalid page. */
    csrrs a0, CSR_DDC, x0
    li   t0, VA_OF(IDX_INVALID)
    YADDRW a0, a0, t0

    /* a1 = the same address, untagged: the capability check fails first. */
    YSUNSEAL a1, x0, a0

    /* a2 = the same page, misaligned for a capability access. */
    li   t0, VA_OF(IDX_INVALID) + 4
    YADDRW a2, a0, t0

    CAP_TO_ALIAS a5, IDX_OK      /* everything permitted: the well-formed control */
    CAP_TO_ALIAS a6, IDX_NOREAD
    CAP_TO_ALIAS a7, IDX_NOWRITE
    CAP_TO_ALIAS s0, IDX_NOACCESS
    CAP_TO_ALIAS s1, IDX_NODIRTY

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

    /* ---- Ordering 1: a capability check outranks the walk ------------- */

    NEXT_TEST "an untagged capability outranks the page fault for ly"
    LY   t1, 0(a1)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    NEXT_TEST "control: the same address tagged takes the page fault"
    LY   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    NEXT_TEST "an untagged capability outranks the page fault for sy"
    SY   s2, 0(a1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    NEXT_TEST "control: the same address tagged takes the store page fault"
    SY   s2, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    NEXT_TEST "an untagged capability outranks the page fault for lr.y"
    LR_Y t1, a1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    NEXT_TEST "control: the same address tagged takes the page fault"
    LR_Y t1, a0
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    NEXT_TEST "an untagged capability outranks the page fault for amoswap.y"
    AMOSWAP_Y t1, a1, s2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    NEXT_TEST "control: the same address tagged takes the store page fault"
    AMOSWAP_Y t1, a0, s2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    NEXT_TEST "an untagged capability outranks the reservation check for sc.y"
    SC_Y t1, a1, s2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    NEXT_TEST "control: a well formed sc.y raises no capability fault"
    SC_Y t1, a5, s2
    EXPECT_NO_TRAP

    /* ---- Ordering 2: a misaligned capability access outranks it too --- */

    NEXT_TEST "a misaligned ly outranks the page fault"
    LY   t1, 0(a2)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    NEXT_TEST "control: the aligned ly takes the page fault"
    LY   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    NEXT_TEST "a misaligned sy outranks the store page fault"
    SY   s2, 0(a2)
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    NEXT_TEST "control: the aligned sy takes the store page fault"
    SY   s2, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    NEXT_TEST "a misaligned lr.y outranks the page fault"
    LR_Y t1, a2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_LOAD
    NEXT_TEST "control: the aligned lr.y takes the page fault"
    LR_Y t1, a0
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    NEXT_TEST "a misaligned amoswap.y outranks the store page fault"
    AMOSWAP_Y t1, a2, s2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    NEXT_TEST "control: the aligned amoswap.y takes the store page fault"
    AMOSWAP_Y t1, a0, s2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    NEXT_TEST "a misaligned sc.y outranks the reservation check"
    SC_Y t1, a2, s2
    EXPECT_TRAP CAUSE_CAP_MISALIGNED_STORE
    NEXT_TEST "control: an aligned sc.y raises no misaligned fault"
    SC_Y t1, a5, s2
    EXPECT_NO_TRAP

    /* ---- The walk's own faults, per reason and per instruction -------- */

    /* An invalid PTE: nothing may go through it. */
    NEXT_TEST "an invalid pte faults an ly"
    LY   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an invalid pte faults an sy"
    SY   s2, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an invalid pte faults an lr.y"
    LR_Y t1, a0
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an invalid pte faults an amoswap.y"
    AMOSWAP_Y t1, a0, s2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    /*
     * No read permission (an execute-only page). An AMO needs to read as
     * well as write, so it is refused here too, as a store/AMO fault.
     */
    NEXT_TEST "an execute-only page refuses an ly"
    LY   t1, 0(a6)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an execute-only page refuses an lr.y"
    LR_Y t1, a6
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an execute-only page refuses an sy"
    SY   s2, 0(a6)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an execute-only page refuses an amoswap.y"
    AMOSWAP_Y t1, a6, s2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    /*
     * No write permission (a read-only page). Loads go through, so the lr.y
     * also gives the sc.y below a valid reservation to be refused with.
     */
    NEXT_TEST "a read-only page still permits an ly"
    LY   t1, 0(a7)
    EXPECT_NO_TRAP
    NEXT_TEST "a read-only page refuses an sy"
    SY   s2, 0(a7)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "a read-only page refuses an amoswap.y"
    AMOSWAP_Y t1, a7, s2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "a read-only page permits the lr.y that reserves the address"
    LR_Y t1, a7                  /* permitted, and reserves the address */
    EXPECT_NO_TRAP
    NEXT_TEST "and refuses the sc.y that reservation lets reach the walk"
    SC_Y t1, a7, s2              /* ... so this reaches the walk and is refused */
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    /*
     * An unset accessed bit, which affects reads and writes alike. The pte
     * is rewritten before each case so a hardware update does not leave the
     * bit set for the next one.
     */
    NEXT_TEST "an unset accessed bit and an ly"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    LY   t1, 0(s0)
    EXPECT_AD_FAULT CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an unset accessed bit and an sy"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    SY   s2, 0(s0)
    EXPECT_AD_FAULT CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an unset accessed bit and an lr.y"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    LR_Y t1, s0
    EXPECT_AD_FAULT CAUSE_LOAD_PAGE_FAULT
    NEXT_TEST "an unset accessed bit and an amoswap.y"
    RESET_PTE IDX_NOACCESS, PTE_NOACCESS
    AMOSWAP_Y t1, s0, s2
    EXPECT_AD_FAULT CAUSE_STORE_PAGE_FAULT

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
    SY   s2, 0(s1)
    EXPECT_AD_FAULT CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an unset dirty bit and an amoswap.y"
    RESET_PTE IDX_NODIRTY, PTE_NODIRTY
    AMOSWAP_Y t1, s1, s2
    EXPECT_AD_FAULT CAUSE_STORE_PAGE_FAULT
    NEXT_TEST "an unset dirty bit permits the lr.y that reserves the address"
    RESET_PTE IDX_NODIRTY, PTE_NODIRTY
    LR_Y t1, s1
    EXPECT_NO_TRAP
    NEXT_TEST "and the sc.y that reservation lets reach the walk"
    SC_Y t1, s1, s2
    EXPECT_AD_FAULT CAUSE_STORE_PAGE_FAULT

    /* ---- Ordering 3: a CHERI Load Capability Fault is the lowest ------ */

    CAP_TO_ALIAS a3, IDX_YRG     /* the mismatching page, which raises 35 */
    CAP_TO_ALIAS a4, IDX_USER    /* the same, but S-mode may not reach it */

    /* 35 only fires for a set tag, so put one in the buffer first. */
    NEXT_TEST "put a tagged capability in the buffer for the loads below"
    SY   s2, 0(a5)
    EXPECT_NO_TRAP

    /* The mismatching page really does raise 35 on its own ... */
    NEXT_TEST "the mismatching page raises a load capability fault on its own"
    LY   t1, 0(a3)
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    /* ... and the page fault from the same walk still outranks it. */
    NEXT_TEST "but a page fault on the same walk outranks it"
    LY   t1, 0(a4)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    NEXT_TEST "the mismatching page raises it for lr.y too"
    LR_Y t1, a3
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    NEXT_TEST "and the page fault still outranks it"
    LR_Y t1, a4
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT

    NEXT_TEST "the mismatching page raises it for amoswap.y too"
    AMOSWAP_Y t1, a3, s2
    EXPECT_TRAP CAUSE_CHERI_LOAD_CAP
    NEXT_TEST "and the store page fault still outranks it"
    AMOSWAP_Y t1, a4, s2
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT

    YMODESWI
    la   m_continue, m_done
    ecall
m_done:
    TEST_PASS
fail:
    /*
     * S-mode with paging on cannot reach the finisher device, so report from
     * M-mode.
     */
    YMODESWI
    la   m_continue, m_fail
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

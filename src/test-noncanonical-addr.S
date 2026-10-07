/* SPDX-License-Identifier: BSD-2-Clause
 *
 * A capability CSR may hold an address that is not canonical for the
 * current translation mode, and keeps its tag when it does. Golden Sail
 * treats every address as valid for storage: validAddr is always true and
 * convertInvalidAddr is the identity (sail-cheri-riscv
 * sail-riscv/model/riscv_convert_invalid_addr.sail:4-16), so
 * convertInvalidAddrCap and setCapCSRAddr never clear the tag on its account
 * (src/cheri_regs.sail:107-137), and every mtvec, mepc and ddc write, of the
 * whole capability or of its address alone, goes through one of the two
 * (src/cheri_sys_regs_access.sail:38-119). Being non-canonical only matters
 * when the address is translated: an Sv39 access to it fails the walk before
 * any pte is read and is reported as a page fault
 * (sail-riscv/model/riscv_vmem.sail:349-351).
 *
 * So satp is set to Sv39 throughout, which makes 1 << 38 (bit 38 set, bits
 * 63:39 clear) non-canonical, and a finite capability at that address is
 * written to each CSR from M-mode, where nothing is translated. Each write is
 * done twice: once with the whole capability, and once as an address-only
 * write that moves the cursor within the bounds of the capability already
 * there. Finite bounds matter: a capability with infinite bounds keeps its
 * tag whatever the address. Finally S-mode, which is translated, uses the
 * same capability and takes the page faults.
 */
#define TEST_NAME "noncanonical-addr"
#ifdef CHERI_093
#error "RVY v0.9.9 only: this follows the v0.9.9 Sail invalid-address rules"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define CSR_SATP     0x180
#define SATP_SV39    (8 << 60)

/* Leaf PTE bits. */
#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_A 0x40
#define PTE_D 0x80

/* Not sign-extended from bit 38, so not an Sv39 address. */
#define NONCANON     (1 << 38)
#define MOVE         0x40        /* address-only writes go here: in bounds */

#define root_ddc     s0          /* the reset ddc, put back after each case */
#define saved_mepc   s1
#define saved_mtvec  s2

/*
 * Read \csr into a1, put \saved back, then require the tag to be set and the
 * address to be \addr. The CSR is restored before checking, so that reaching
 * fail never runs with a trap vector or a ddc the finisher cannot use.
 */
.macro EXPECT_KEPT csr, saved, addr
    csrrs a1, \csr, x0
    csrw \csr, \saved
    YTAGR t0, a1
    beqz t0, fail
    li   t2, \addr
    bne  a1, t2, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /* PMP entry 0: allow everything (required for S-mode accesses). */
    li   t0, -1
    csrw CSR_PMPADDR0, t0
    li   t0, 0x1f
    csrw CSR_PMPCFG0, t0

    li   t0, MENVCFG_CRE
    csrs CSR_MENVCFG, t0

    /* Sv39 root table: one gigapage mapping the image at 0x80000000. */
    la   t0, pagetable
    li   t1, (0x80000 << 10) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    sd   t1, (2 * 8)(t0)
    srli t0, t0, 12
    li   t1, SATP_SV39
    or   t0, t0, t1
    csrw CSR_SATP, t0
    sfence.vma

    YMODESWY                     /* so csrw writes the whole capability */

    csrrs root_ddc, CSR_DDC, x0
    csrrs saved_mepc, CSR_MEPC, x0
    csrrs saved_mtvec, CSR_MTVEC, x0

    /* a0 = [NONCANON, NONCANON + 256), tagged: finite and exact. */
    li   t0, NONCANON
    YADDRW a0, root_ddc, t0
    li   t1, 256
    YBNDSW a0, a0, t1
    YTAGR t0, a0
    beqz t0, fail

    NEXT_TEST "mtvec keeps the tag of a non-canonical capability"
    csrw CSR_MTVEC, a0
    EXPECT_KEPT CSR_MTVEC, saved_mtvec, NONCANON

    NEXT_TEST "mtvec keeps the tag after an address-only non-canonical write"
    csrw CSR_MTVEC, a0
    li   t0, NONCANON + MOVE
    YMODESWI                     /* so csrw writes only the address */
    csrw CSR_MTVEC, t0
    YMODESWY
    EXPECT_KEPT CSR_MTVEC, saved_mtvec, NONCANON + MOVE

    NEXT_TEST "mepc keeps the tag of a non-canonical capability"
    csrw CSR_MEPC, a0
    EXPECT_KEPT CSR_MEPC, saved_mepc, NONCANON

    NEXT_TEST "mepc keeps the tag after an address-only non-canonical write"
    csrw CSR_MEPC, a0
    li   t0, NONCANON + MOVE
    YMODESWI
    csrw CSR_MEPC, t0
    YMODESWY
    EXPECT_KEPT CSR_MEPC, saved_mepc, NONCANON + MOVE

    NEXT_TEST "ddc keeps the tag of a non-canonical capability"
    csrw CSR_DDC, a0
    EXPECT_KEPT CSR_DDC, root_ddc, NONCANON

    /*
     * csrrw always writes the whole of ddc, in either pointer mode, so the
     * address-only write has to be a csrrs (src/cheri_csr_op.sail:133-148).
     */
    NEXT_TEST "ddc keeps the tag after an address-only non-canonical write"
    csrw CSR_DDC, a0
    li   t0, MOVE
    csrrs x0, CSR_DDC, t0
    EXPECT_KEPT CSR_DDC, root_ddc, NONCANON + MOVE

    /* Enter S-mode, still in capability mode, with mepc a full capability. */
    YMODESWI
    li   t0, 0x1800
    csrc CSR_MSTATUS, t0
    li   t0, 0x0800              /* mstatus.MPP = S */
    csrs CSR_MSTATUS, t0
    YMODESWY
    la   t0, s_entry
    auipc t1, 0
    YADDRW t1, t1, t0
    csrw CSR_MEPC, t1
    mret

s_entry:
    /*
     * The capability allows the access, so what remains is the walk, which
     * rejects the address before reading any pte. mtval cannot be read from
     * S-mode, but the handler records it (as trap_tval2 on RVY).
     */
    NEXT_TEST "an S-mode load from the non-canonical address page-faults"
    li   t2, NONCANON
    ld   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_PAGE_FAULT
    bne  trap_tval2, t2, fail    /* against the untranslatable address */

    NEXT_TEST "an S-mode store to the non-canonical address page-faults"
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_PAGE_FAULT
    bne  trap_tval2, t2, fail

    YMODESWI
    la   m_continue, m_done
    ecall
m_done:
    TEST_PASS
fail:
    /*
     * S-mode with paging on cannot reach the finisher device, so report from
     * M-mode. From M-mode the ecall is just stepped over.
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

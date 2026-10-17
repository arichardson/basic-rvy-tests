/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Instruction-fetch exception priority and direct-jump translation chaining.
 *
 * On RVY >= 0.9.6, branches, JAL, JALR, and xRET update PCC without checking
 * the target at the branch, and fault on instruction fetch at the target.
 * Per the synchronous exception priority table, PCC tag, seal, permission,
 * and bounds checks on instruction fetch (CAUSE_CHERI_INST, 32) take
 * precedence over instruction page faults (CAUSE_FETCH_PAGE_FAULT, 12) and
 * access faults (CAUSE_FETCH_ACCESS_FAULT, 1).
 *
 * A binary translator that defers PCC checks to the start of the target TB
 * or emits bounds checks after fetching instruction parcels during
 * translation will probe the target page or upper parcel at translation time
 * and take the page or access fault before the generated PCC check runs.
 * Likewise, chaining a direct JAL with goto_tb must not bypass the target
 * TB's PCC check on subsequent runs.
 */
#define TEST_NAME "ifetch-exception-priority"
#ifdef CHERI_093
#error "Requires RVY >= 0.9.6 (0.9.3 checks jump targets at the branch instead of fetch)"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define CAUSE_FETCH_ACCESS_FAULT 1
#define CAUSE_FETCH_PAGE_FAULT   12

#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_A 0x40
#define PTE_D 0x80
#define PTE_LEAF_RWX (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
#define PTE_LEAF_RW  (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

/*
 * S-mode virtual alias windows at 0x40000000 (l0_pt[0..2] with PTE.V=0 in the
 * middle) and 0x40003000 (l0_pt[3..5] with PTE.X=0 in the middle).
 */
#define VA_EXEC_BEFORE_UNMAPPED 0x40000000
#define VA_EXEC_BEFORE_NOEXEC   0x40003000

#if __riscv_xlen == 32
#define ROOT_IDX_ALIAS 256
#define ROOT_IDX_CODE  512
#define SATP_MODE      (1 << 31)
#else
#define ROOT_IDX_ALIAS 1
#define ROOT_IDX_CODE  2
#define SATP_MODE      (8 << 60)
#endif

/* Offsets within the 3-page window [exec_base, exec_base + 0x3000). */
#define OFF_EDGE_BEQ       (4096 - 32)
#define OFF_EDGE_JAL_REP   (4096 - 24)
#define OFF_STRADDLE_PAD   (4096 - 4)
#define OFF_STRADDLE_INSN  (4096 - 2)
#define OFF_FAULT_PAGE     (4096 + 4)
#define OFF_EDGE_JAL_UNREP (8192 + 32)

#define exec_base    s1          /* base of the 4 KiB executable page */
#define expected_epc s2          /* address the faulting fetch was at */
#define root_cap     s7          /* root executable capability */

/* Derive an 8-byte capability at \tramp in a0 and jump to it, faulting at \target. */
.macro JUMP_FROM_8B_PCC tramp, target
    lla   t0, \tramp
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    lla   expected_epc, \target
    RESUME_AFTER_FAULT 99f
    jalr  x0, a0, 0
99:
.endm

/*
 * Check PCC fetch priority against \mem_cause across the page boundary at
 * exec_base + 4096, paired with controls where PCC is valid and in bounds.
 */
.macro CHECK_IFETCH_PRIORITY mem_cause, label
    NEXT_TEST "control: valid capability jump to \label raises fetch fault"
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    YADDRW a0, root_cap, expected_epc
    RESUME_AFTER_FAULT 90f
    jalr  x0, a0, 0
90:
    EXPECT_TRAP \mem_cause
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    NEXT_TEST "taken beq out of PCC bounds to \label raises a PCC fault"
    mv    s0, x0
    li    t0, OFF_EDGE_BEQ
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    RESUME_AFTER_FAULT 91f
    jalr  x0, a0, 0
91:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    NEXT_TEST "jal out of PCC bounds to \label raises a PCC fault"
    li    t0, OFF_EDGE_JAL_REP
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    RESUME_AFTER_FAULT 92f
    jalr  x0, a0, 0
92:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    NEXT_TEST "unrepresentable jal to \label detags PCC and raises a PCC fault"
    li    t0, OFF_EDGE_JAL_UNREP
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    RESUME_AFTER_FAULT 93f
    jalr  x0, a0, 0
93:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    NEXT_TEST "jalr to untagged capability on \label raises a PCC fault"
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    YHIW  a0, expected_epc, x0
    RESUME_AFTER_FAULT 94f
    jalr  x0, a0, 0
94:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    NEXT_TEST "jalr to sentry with non-zero offset on \label raises a PCC fault"
    li    t0, OFF_FAULT_PAGE
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    YSEALE a0, a0
    addi  expected_epc, t0, 8
    RESUME_AFTER_FAULT 95f
    jalr  x0, a0, 8
95:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    NEXT_TEST "jalr to non-executable capability on \label raises a PCC fault"
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    YADDRW a0, root_cap, expected_epc
    li    t1, PERM_X
    YPERMC a0, a0, t1
    RESUME_AFTER_FAULT 96f
    jalr  x0, a0, 0
96:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    NEXT_TEST "jalr to out-of-bounds capability on \label raises a PCC fault"
    li    t0, OFF_EDGE_BEQ
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    YADDRW a0, a0, expected_epc
    RESUME_AFTER_FAULT 97f
    jalr  x0, a0, 0
97:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    /*
     * 4-byte instruction at +0xffe straddling into +0x1000: 8-byte bounds
     * [0xffc, 0x1004) are in bounds and take \mem_cause; 4-byte bounds
     * [0xffc, 0x1000) fault on pcc.top before \mem_cause on the high parcel.
     */
    NEXT_TEST "control: in-bounds 4-byte instruction straddling into \label raises fetch fault"
    li    t0, OFF_STRADDLE_PAD
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    addi  expected_epc, t0, 2
    YADDRW a0, a0, expected_epc
    RESUME_AFTER_FAULT 98f
    jalr  ra, a0, 0
98:
    EXPECT_TRAP \mem_cause
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    NEXT_TEST "4-byte instruction straddling pcc.top and \label raises a PCC fault"
    li    t0, OFF_STRADDLE_PAD
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 4
    YBNDSW a0, a0, t1
    addi  expected_epc, t0, 2
    YADDRW a0, a0, expected_epc
    RESUME_AFTER_FAULT 89f
    jalr  ra, a0, 0
89:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1
.endm

.macro CHECK_SRET_PRIORITY label
    NEXT_TEST "sret to untagged sepc on \label raises a PCC fault"
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    YHIW  a0, expected_epc, x0
    csrw  CSR_SEPC, a0
    li    t0, 0x0100             /* sstatus.SPP = S */
    csrs  0x100, t0
    RESUME_AFTER_FAULT 87f
    sret
87:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    NEXT_TEST "sret to out-of-bounds sepc on \label raises a PCC fault"
    li    t0, OFF_EDGE_BEQ
    add   t0, exec_base, t0
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    li    t0, OFF_FAULT_PAGE
    add   expected_epc, exec_base, t0
    YADDRW a0, a0, expected_epc
    csrw  CSR_SEPC, a0
    li    t0, 0x0100             /* sstatus.SPP = S */
    csrs  0x100, t0
    RESUME_AFTER_FAULT 88f
    sret
88:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    /*
     * PMP0: locked R|W (X=0) over noexec_page so M-mode fetch faults with
     * CAUSE_FETCH_ACCESS_FAULT. PMP1: R|W|X catch-all for S-mode.
     */
    lla   t0, noexec_page
    addi  t0, t0, 2047
    srli  t0, t0, 2
    csrw  CSR_PMPADDR0, t0
    li    t0, -1
    csrw  CSR_PMPADDR0 + 1, t0
    li    t0, 0x1f9b
    csrw  CSR_PMPCFG0, t0

    li    t0, MENVCFG_CRE
    csrs  CSR_MENVCFG, t0

    /* Sv32/Sv39 page tables: identity-map 0x80000000 R|W|X and map l0_pt at 0x40000000. */
    lla   t0, root_pt
    li    t1, (0x80000 << 10) | PTE_LEAF_RWX
    li    t2, ROOT_IDX_CODE * XBYTES
    add   t2, t0, t2
    SX    t1, 0(t2)

#if __riscv_xlen == 32
    lla   t1, l0_pt
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t1, t1, PTE_V
    li    t2, ROOT_IDX_ALIAS * XBYTES
    add   t2, t0, t2
    SX    t1, 0(t2)
#else
    lla   t1, l1_pt
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t1, t1, PTE_V
    li    t2, ROOT_IDX_ALIAS * XBYTES
    add   t2, t0, t2
    SX    t1, 0(t2)

    lla   t0, l1_pt
    lla   t1, l0_pt
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t1, t1, PTE_V
    SX    t1, 0(t0)
#endif

    lla   t0, l0_pt
    lla   t1, exec_page
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t2, t1, PTE_LEAF_RWX
    SX    t2, (0 * XBYTES)(t0)   /* 0x40000000: R|W|X before unmapped 0x40001000 */
    /* l0_pt[1] (0x40001000) stays 0: PTE.V = 0 */
    SX    t2, (3 * XBYTES)(t0)   /* 0x40003000: R|W|X before non-exec 0x40004000 */
    ori   t2, t1, PTE_LEAF_RW
    SX    t2, (4 * XBYTES)(t0)   /* 0x40004000: PTE.X = 0 */

    lla   t1, after_noexec_page
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t2, t1, PTE_LEAF_RWX
    SX    t2, (2 * XBYTES)(t0)   /* 0x40002000: R|W|X after unmapped 0x40001000 */
    SX    t2, (5 * XBYTES)(t0)   /* 0x40005000: R|W|X after non-exec 0x40004000 */

    lla   t0, root_pt
    srli  t0, t0, 12
    li    t1, SATP_MODE
    or    t0, t0, t1
    csrw  0x180, t0              /* satp */
    sfence.vma

    YMODESWY
    auipc root_cap, 0

    /* Execute each out-of-bounds direct JAL twice to test goto_tb chaining. */
    NEXT_TEST "same-page out-of-bounds jal faults on first execution"
    JUMP_FROM_8B_PCC same_page_jal_tramp, same_page_jal_victim
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
#if __riscv_xlen == 32
    EXPECT_EPC_TAG 0
#else
    EXPECT_EPC_TAG 1
#endif

    NEXT_TEST "same-page out-of-bounds jal still faults on second execution"
    RESUME_AFTER_FAULT 1f
    jalr  x0, a0, 0
1:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
#if __riscv_xlen == 32
    EXPECT_EPC_TAG 0
#else
    EXPECT_EPC_TAG 1
#endif

    NEXT_TEST "unrepresentable jal detags PCC and faults on first execution"
    JUMP_FROM_8B_PCC unrep_jal_tramp, same_page_jal_tramp
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    NEXT_TEST "unrepresentable jal still faults on second execution"
    RESUME_AFTER_FAULT 2f
    jalr  x0, a0, 0
2:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    /* M-mode: PCC fault vs PMP fetch access fault (cause 1). */
    lla   exec_base, exec_page
    CHECK_IFETCH_PRIORITY CAUSE_FETCH_ACCESS_FAULT, "non-executable PMP page"

    NEXT_TEST "mret to untagged mepc on non-executable PMP page raises a PCC fault"
    lla   expected_epc, noexec_target
    YHIW  a0, expected_epc, x0
    csrw  CSR_MEPC, a0
    li    t0, 0x1800             /* mstatus.MPP = M */
    csrs  CSR_MSTATUS, t0
    RESUME_AFTER_FAULT 3f
    mret
3:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 0

    NEXT_TEST "mret to out-of-bounds mepc on non-executable PMP page raises a PCC fault"
    lla   t0, edge_beq
    YADDRW a0, root_cap, t0
    li    t1, 8
    YBNDSW a0, a0, t1
    lla   expected_epc, noexec_target
    YADDRW a0, a0, expected_epc
    csrw  CSR_MEPC, a0
    li    t0, 0x1800             /* mstatus.MPP = M */
    csrs  CSR_MSTATUS, t0
    RESUME_AFTER_FAULT 4f
    mret
4:
    EXPECT_TRAP CAUSE_CHERI_INST
    EXPECT_EPC expected_epc
    EXPECT_EPC_TAG 1

    /* S-mode: PCC fault vs fetch page fault (cause 12) for PTE.V=0 and PTE.X=0. */
    YMODESWI
    lla   m_continue, m_fail
    li    t0, 0x1800
    csrc  CSR_MSTATUS, t0
    li    t0, 0x0800             /* mstatus.MPP = S */
    csrs  CSR_MSTATUS, t0
    lla   t0, s_entry
    csrw  CSR_MEPC, t0
    mret

s_entry:
    YMODESWY

    /* Unmapped page (PTE.V = 0) at 0x40001000. */
    li    exec_base, VA_EXEC_BEFORE_UNMAPPED
    CHECK_IFETCH_PRIORITY CAUSE_FETCH_PAGE_FAULT, "unmapped page"
    CHECK_SRET_PRIORITY "unmapped page"

    /* Non-executable PTE page (PTE.X = 0) at 0x40004000. */
    li    exec_base, VA_EXEC_BEFORE_NOEXEC
    CHECK_IFETCH_PRIORITY CAUSE_FETCH_PAGE_FAULT, "non-executable PTE page"
    CHECK_SRET_PRIORITY "non-executable PTE page"

    YMODESWI
    lla   m_continue, m_done
    ecall
m_done:
    TEST_PASS
fail:
    YMODESWI
    beqz  m_continue, m_fail
    ecall
m_fail:
    TEST_FAIL

/* Direct JAL targets on an executable page (+2048 same-page, -4128 unrepresentable). */
.balign 4096
same_page_jal_tramp:
    jal   x0, same_page_jal_victim
    j     fail
    .space 2048 - 8
same_page_jal_victim:
    j     fail
    .space 2048 - 4 + 32
unrep_jal_tramp:
    jal   x0, same_page_jal_tramp
    j     fail

/*
 * Three-page window: exec_page (+0x0000, executable), noexec_page (+0x1000,
 * PMP X=0 / aliased PTE.V=0 and PTE.X=0), and after_noexec_page (+0x2000).
 */
.balign 4096
exec_page:
    .space OFF_EDGE_BEQ
edge_beq:
    beq   s0, x0, noexec_target
    j     fail
edge_jal_rep:
    jal   x0, noexec_target
    j     fail
    .space OFF_STRADDLE_PAD - (OFF_EDGE_JAL_REP + 8)
.option rvc
straddle_before_noexec:
    c.nop                               /* +0xffc .. +0xffd */
.option norvc
straddle_insn:
    .half 0x8067                        /* +0xffe .. +0xfff: low half of ret */
noexec_page:
    .half 0x0000                        /* +0x1000 .. +0x1001: high half of ret */
    .half 0x0000
noexec_target:
    j     fail
    .space 4096 - 8
after_noexec_page:
    .space 32
edge_jal_unrep:
    jal   x0, noexec_target
    j     fail

TRAP_HANDLER_PCC

.section .bss
.balign 4096
root_pt:
    .space 4096
#if __riscv_xlen == 64
.balign 4096
l1_pt:
    .space 4096
#endif
.balign 4096
l0_pt:
    .space 4096

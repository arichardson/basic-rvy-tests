/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Physical memory protection, as golden Sail checks it (sail-cheri-riscv
 * sail-riscv/model/riscv_pmp_control.sail, riscv_pmp_regs.sail), with the
 * Sail C emulator's platform: G = 0, so NA4 is selectable
 * (c_emulator/riscv_platform_impl.cpp:7), and 16 entries (--pmp-count 16).
 *
 *  - pmpCheck (riscv_pmp_control.sail:109-122) scans the entries in order and
 *    the lowest-numbered one that matches any byte decides: a full match
 *    checks R/W/X, a partial match fails outright (:85-95). With no match
 *    M-mode is allowed and S/U-mode denied. Faults are load 5, store/AMO 7
 *    and fetch 1 (accessToFault, :98-107).
 *  - A locked entry applies to M-mode as well (:89) and ignores pmpcfg
 *    writes (riscv_pmp_regs.sail:101); a locked TOR entry also freezes the
 *    pmpaddr below it (:150-157, :159-168).
 *  - pmpcfg legalizes R=0,W=1 to R=W=X=0 and reads bits 6:5 as zero
 *    (riscv_pmp_regs.sail:104-109).
 *  - Data accesses use the effective privilege, so MPRV=1 with MPP=S checks
 *    M-mode loads and stores against S (riscv_mem.sail mem_read_meta).
 *  - The CHERI checks come before translation and PMP: a capability fault
 *    wins over a PMP fault for data (src/cheri_insts.sail:812-899) and for
 *    fetch (sail-riscv/model/riscv_fetch.sail:18, src/cheri_addr_checks.sail
 *    :39-64). amoswap.y reads before it writes (src/cheri_insts.sail
 *    :991-996), so a region it can neither read nor write reports the load.
 *  - cbo.clean/flush fault only when PMP refuses both the read and the
 *    write, and always as a store fault; they use the current privilege,
 *    not MPRV (sail-riscv/model/riscv_insts_zicbom.sail process_clean_inval).
 *    cbo.zero needs W and does follow MPRV (riscv_insts_zicboz.sail:51).
 *    Both report rs1, not the block address, in mtval. Golden Sail hard-wires
 *    menvcfg.CBCFE/CBZE to 0 (src/cheri_sys_regs_envcfg.sail:10-22), which
 *    makes every S-mode CBO illegal, so they run in M-mode: cbo.zero under
 *    MPRV, and all of them against locked entries.
 *
 * Entry 15 is a TOR entry granting RWX over [0, region), so S-mode can run
 * the test; region (four pages at the end of .bss) is matched only by the
 * entries a case sets up. The locked entries cannot be undone, so they come
 * last and lock only pages nothing else uses.
 */
#define TEST_NAME "pmp"
#ifdef CHERI_093
#error "RVY v0.9.9 only"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define CSR_PMPCFG2     0x3A2
#define CSR_PMPADDR(n)  (0x3B0 + (n))
#define CAUSE_FETCH_ACCESS_FAULT 1

#define MSTATUS_MPP     0x1800
#define MSTATUS_MPP_S   0x0800
#define MSTATUS_MPRV    (1 << 17)

/* pmpcfg entry fields */
#define PMP_R      0x01
#define PMP_W      0x02
#define PMP_X      0x04
#define PMP_TOR    0x08
#define PMP_NA4    0x10
#define PMP_NAPOT  0x18
#define PMP_L      0x80
/* Entry n's byte within its pmpcfg register. */
#define CFG(n,v)   ((v)<<(8*((n)%8)))

/* Pages of region. */
#define PAGE   4096
#define R0     (0*PAGE)
#define R1     (1*PAGE)
#define R2     (2*PAGE)
#define R3     (3*PAGE)
#define CBO_OFF 0x48             /* not block aligned, so mtval shows rs1 */

#define root   s0                /* ddc */

/* pmpaddr<n> = the word address of region + \off. */
.macro SET_PMPADDR n, off
    la   t0, region + \off
    srli t0, t0, 2
    csrw CSR_PMPADDR(\n), t0
.endm

/* ... as a naturally aligned power-of-two region of \size bytes. */
.macro SET_PMPADDR_NAPOT n, off, size
    la   t0, region + \off
    srli t0, t0, 2
    ori  t0, t0, ((\size) >> 3) - 1
    csrw CSR_PMPADDR(\n), t0
.endm

/* Entries 0-7. */
.macro SET_PMPCFG0 val
    li   t0, \val
    csrw CSR_PMPCFG0, t0
.endm

/* The low byte of pmpcfg0 (entry 0) reads back as \val. */
.macro EXPECT_CFG0_BYTE0 val
    csrr t1, CSR_PMPCFG0
    andi t1, t1, 0xff
    li   t2, \val
    bne  t2, t1, fail
.endm

/* Drop to S-mode at the next instruction (from integer pointer mode). */
.macro TO_S
    li   t0, MSTATUS_MPP
    csrc CSR_MSTATUS, t0
    li   t0, MSTATUS_MPP_S
    csrs CSR_MSTATUS, t0
    la   t0, .Lto_s\@
    csrw CSR_MEPC, t0
    mret
.Lto_s\@:
.endm

/* Back to M-mode at the next instruction (from integer pointer mode). */
.macro TO_M
    la   m_continue, .Lto_m\@
    ecall
.Lto_m\@:
.endm

/* M-mode data accesses are checked as S-mode until the next trap. */
.macro MPRV_S
    li   t0, MSTATUS_MPP
    csrc CSR_MSTATUS, t0
    li   t0, MSTATUS_MPP_S | MSTATUS_MPRV
    csrs CSR_MSTATUS, t0
.endm

.macro MPRV_OFF
    li   t0, MSTATUS_MPRV
    csrc CSR_MSTATUS, t0
.endm

/* ... reported against the address in \reg (readable from any mode). */
.macro EXPECT_TVAL_REG reg
    bne  trap_tval2, \reg, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    li   t0, MENVCFG_CRE
    csrs CSR_MENVCFG, t0
    csrrs root, CSR_DDC, x0

    /* Entry 15: TOR over [0, region), RWX; every other entry off. */
    csrw CSR_PMPADDR(14), x0
    SET_PMPADDR 15, 0
    SET_PMPCFG0 0
    li   t0, CFG(15,PMP_TOR|PMP_R|PMP_W|PMP_X)
    csrw CSR_PMPCFG2, t0

    /* ----------------------------------------------- no matching entry */

    NEXT_TEST "an M-mode load no entry matches is allowed"
    la   a0, region + R0
    ld   t1, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "an M-mode store no entry matches is allowed"
    sd   x0, 0(a0)
    EXPECT_NO_TRAP

    TO_S
    NEXT_TEST "an S-mode load no entry matches takes a load access fault"
    la   a0, region + R0
    ld   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "an S-mode store no entry matches takes a store access fault"
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "an S-mode fetch no entry matches takes a fetch access fault"
    RESUME_AFTER_FAULT 1f
    jr   a0
1:  EXPECT_TRAP CAUSE_FETCH_ACCESS_FAULT
    EXPECT_EPC a0
    EXPECT_TVAL_REG a0
    TO_M

    /* ------------------------------------------------------------ TOR */

    /* Entry 1: TOR [R0, R1), R; entry 0 only supplies the base. */
    SET_PMPADDR 0, R0
    SET_PMPADDR 1, R1
    SET_PMPCFG0 CFG(1,PMP_TOR|PMP_R)
    TO_S
    NEXT_TEST "TOR matches its base"
    la   a0, region + R0
    ld   t1, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "TOR matches the last word below its top"
    la   a1, region + R1 - 8
    ld   t1, 0(a1)
    EXPECT_NO_TRAP

    NEXT_TEST "TOR does not match its top"
    la   a1, region + R1
    ld   t1, 0(a1)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    NEXT_TEST "a TOR match without W refuses a store"
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0
    TO_M

    /* ------------------------------------------------------------ NA4 */

    SET_PMPADDR 0, R1 + 0x10
    SET_PMPCFG0 CFG(0,PMP_NA4|PMP_R|PMP_W)
    TO_S
    NEXT_TEST "NA4 matches a word load at its address"
    la   a0, region + R1 + 0x10
    lw   t1, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "NA4 matches a word store at its address"
    sw   x0, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "NA4 does not match the next word"
    la   a1, region + R1 + 0x14
    lw   t1, 0(a1)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    NEXT_TEST "a doubleword only half inside NA4 is a partial match"
    ld   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a0
    TO_M

    /* ---------------------------------------------------------- NAPOT */

    SET_PMPADDR_NAPOT 0, R2, PAGE
    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R|PMP_W)
    TO_S
    NEXT_TEST "a 4 KiB NAPOT matches its first doubleword"
    la   a0, region + R2
    ld   t1, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "a 4 KiB NAPOT matches its last doubleword"
    la   a1, region + R2 + PAGE - 8
    sd   x0, 0(a1)
    EXPECT_NO_TRAP

    NEXT_TEST "a 4 KiB NAPOT does not match the next page"
    la   a1, region + R3
    ld   t1, 0(a1)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a1
    TO_M

    /* ------------------------------------------------------- priority */

    SET_PMPADDR_NAPOT 0, R2, PAGE
    SET_PMPADDR_NAPOT 1, R2, PAGE
    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R)|CFG(1,PMP_NAPOT|PMP_R|PMP_W)
    TO_S
    NEXT_TEST "entry 0 (R) decides over entry 1 (RW): a store faults"
    la   a0, region + R2
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0
    TO_M

    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R|PMP_W)|CFG(1,PMP_NAPOT|PMP_R)
    TO_S
    NEXT_TEST "control: entry 0 (RW) decides over entry 1 (R): a store works"
    la   a0, region + R2
    sd   x0, 0(a0)
    EXPECT_NO_TRAP
    TO_M

    SET_PMPADDR 0, R2
    SET_PMPCFG0 CFG(0,PMP_NA4|PMP_R|PMP_W)|CFG(1,PMP_NAPOT|PMP_R|PMP_W)
    TO_S
    NEXT_TEST "a partial match on entry 0 fails though entry 1 matches fully"
    la   a0, region + R2
    ld   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "control: a full match on entry 0 allows the word"
    lw   t1, 0(a0)
    EXPECT_NO_TRAP
    TO_M

    /* ------------------------------------------------- legalization */

    NEXT_TEST "pmpcfg legalizes R=0,W=1 to no permissions"
    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_X|PMP_W)
    EXPECT_CFG0_BYTE0 PMP_NAPOT

    NEXT_TEST "pmpcfg bits 6:5 read as zero"
    SET_PMPCFG0 CFG(0,0x60|PMP_R)
    EXPECT_CFG0_BYTE0 PMP_R

    NEXT_TEST "pmpcfg keeps NA4 with G = 0"
    SET_PMPCFG0 CFG(0,PMP_NA4|PMP_R|PMP_W)
    EXPECT_CFG0_BYTE0 PMP_NA4|PMP_R|PMP_W

    SET_PMPADDR_NAPOT 0, R2, PAGE
    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_W)
    TO_S
    NEXT_TEST "a legalized W-only entry does not grant the store"
    la   a0, region + R2
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    TO_M

    /* ----------------------------------------------------------- MPRV */

    SET_PMPADDR_NAPOT 0, R2, PAGE
    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R)
    la   a0, region + R2
    la   a1, region + R3

    NEXT_TEST "MPRV=1, MPP=S: an M-mode load S may make works"
    MPRV_S
    ld   t1, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "MPRV=1, MPP=S: an M-mode store checks S permissions"
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "MPRV=1, MPP=S: an M-mode load no entry matches faults"
    MPRV_S
    ld   t1, 0(a1)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    NEXT_TEST "control: with MPRV=0 the same M-mode store works"
    MPRV_OFF
    sd   x0, 0(a0)
    EXPECT_NO_TRAP

    /* ---------------------------------------------------------- CHERI */

    SET_PMPADDR_NAPOT 0, R2, PAGE
    SET_PMPCFG0 CFG(0,PMP_NAPOT)
    TO_S
    la   a0, region + R2
    NEXT_TEST "ly from a region PMP denies takes a load access fault"
    LY   a2, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "sy to a region PMP denies takes a store access fault"
    SY   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "amoswap.y that can neither read nor write reports the load"
    AMOSWAP_Y a2, a0, x0
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    /*
     * a1 = [R2 + 16, R2 + 32) with its address at R2: tagged, but the
     * access is out of bounds.
     */
    NEXT_TEST "a capability bounds fault wins over the PMP load fault"
    YMODESWY
    addi t1, a0, 16
    YADDRW a1, root, t1
    YBNDSWI a1, a1, 16
    YADDRW a1, a1, a0
    LY   a2, 0(a1)
    YMODESWI
    EXPECT_TRAP CAUSE_CHERI_LOAD

    /* a1 = PCC bounded to [R2, R2 + 16), in capability mode. */
    NEXT_TEST "control: an in-bounds fetch PMP denies faults on PMP"
    YMODESWY
    auipc a1, 0
    YADDRW a1, a1, a0
    YBNDSWI a1, a1, 16
    RESUME_AFTER_FAULT 1f
    jr   a1
1:  YMODESWI
    EXPECT_TRAP CAUSE_FETCH_ACCESS_FAULT
    EXPECT_EPC a0

    /* a1 = PCC bounded to [R2 + 16, R2 + 32), pointing at R2. */
    NEXT_TEST "a PCC bounds fault wins over the PMP fetch fault"
    YMODESWY
    auipc a1, 0
    addi t1, a0, 16
    YADDRW a1, a1, t1
    YBNDSWI a1, a1, 16
    YADDRW a1, a1, a0
    YTAGR t1, a1
    beqz t1, fail
    RESUME_AFTER_FAULT 1f
    jr   a1
1:  YMODESWI
    EXPECT_TRAP CAUSE_CHERI_INST
    TO_M

    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R)
    TO_S
    la   a0, region + R2
    NEXT_TEST "ly from a region PMP lets S read works"
    LY   a2, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "sy to a read-only PMP region takes a store access fault"
    SY   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "control: amoswap.y that can only read reports the store"
    AMOSWAP_Y a2, a0, x0
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0
    TO_M

    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R|PMP_W)
    TO_S
    la   a0, region + R2
    NEXT_TEST "amoswap.y on a region PMP lets S read and write works"
    AMOSWAP_Y a2, a0, x0
    EXPECT_NO_TRAP
    TO_M

    /* ------------------------------------------------------------ CBO */

    SET_PMPCFG0 0
    la   a0, region + R3 + CBO_OFF
    NEXT_TEST "MPRV=1, MPP=S: cbo.clean is checked as M and works"
    MPRV_S
    CBO_CLEAN a0
    EXPECT_NO_TRAP

    NEXT_TEST "MPRV=1, MPP=S: cbo.zero is checked as S and faults at rs1"
    CBO_ZERO a0
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    SET_PMPADDR_NAPOT 0, R2, PAGE
    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R)
    la   a0, region + R2 + CBO_OFF
    NEXT_TEST "MPRV=1, MPP=S: cbo.zero where S may only read faults at rs1"
    MPRV_S
    CBO_ZERO a0
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    SET_PMPCFG0 CFG(0,PMP_NAPOT|PMP_R|PMP_W)
    li   t1, -1
    sd   t1, 0(a0)
    NEXT_TEST "control: MPRV=1, MPP=S: cbo.zero where S may write zeroes"
    MPRV_S
    CBO_ZERO a0
    EXPECT_NO_TRAP
    MPRV_OFF
    ld   t1, 0(a0)
    bnez t1, fail

    /* --------------------------------------------------------- locked */

    SET_PMPADDR_NAPOT 2, R3, PAGE
    SET_PMPCFG0 CFG(2,PMP_L|PMP_NAPOT)
    la   a0, region + R3
    NEXT_TEST "a locked entry without R refuses an M-mode load"
    ld   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "a locked entry without W refuses an M-mode store"
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    NEXT_TEST "a locked entry ignores pmpcfg writes"
    SET_PMPCFG0 CFG(2,PMP_NAPOT|PMP_R|PMP_W|PMP_X)
    csrr t1, CSR_PMPCFG0
    srli t1, t1, 16
    andi t1, t1, 0xff
    li   t2, PMP_L|PMP_NAPOT
    bne  t2, t1, fail
    ld   t1, 0(a0)
    EXPECT_TRAP CAUSE_LOAD_ACCESS_FAULT

    NEXT_TEST "a locked entry ignores pmpaddr writes"
    csrr t1, CSR_PMPADDR(2)
    SET_PMPADDR_NAPOT 2, R0, PAGE
    csrr t2, CSR_PMPADDR(2)
    bne  t2, t1, fail

    la   a1, region + R3 + CBO_OFF
    NEXT_TEST "cbo.clean where a locked entry refuses R and W faults at rs1"
    CBO_CLEAN a1
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    NEXT_TEST "cbo.flush where a locked entry refuses R and W faults at rs1"
    CBO_FLUSH a1
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    NEXT_TEST "cbo.zero where a locked entry refuses W faults at rs1"
    CBO_ZERO a1
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    /* Entry 4: locked TOR [R1, R2), R. */
    SET_PMPADDR 3, R1
    SET_PMPADDR 4, R2
    SET_PMPCFG0 CFG(2,PMP_L|PMP_NAPOT)|CFG(4,PMP_L|PMP_TOR|PMP_R)
    NEXT_TEST "a locked TOR entry freezes the pmpaddr below it"
    csrr t1, CSR_PMPADDR(3)
    SET_PMPADDR 3, R0
    csrr t2, CSR_PMPADDR(3)
    bne  t2, t1, fail

    NEXT_TEST "control: the pmpaddr above a locked TOR entry is writable"
    SET_PMPADDR 5, R0
    csrr t2, CSR_PMPADDR(5)
    la   t1, region + R0
    srli t1, t1, 2
    bne  t2, t1, fail

    la   a0, region + R1
    NEXT_TEST "a locked TOR entry with R allows an M-mode load"
    ld   t1, 0(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "a locked TOR entry without W refuses an M-mode store"
    sd   x0, 0(a0)
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a0

    la   a1, region + R1 + CBO_OFF
    NEXT_TEST "control: cbo.clean where a locked entry grants only R works"
    CBO_CLEAN a1
    EXPECT_NO_TRAP

    NEXT_TEST "cbo.zero where a locked entry grants only R faults at rs1"
    CBO_ZERO a1
    EXPECT_TRAP CAUSE_STORE_ACCESS_FAULT
    EXPECT_TVAL_REG a1

    TEST_PASS
fail:
    /* S-mode may not reach the finisher, so report from M-mode. */
    YMODESWI
    la   m_continue, m_fail
    ecall
m_fail:
    MPRV_OFF
    TEST_FAIL

TRAP_HANDLER_PCC

.section .bss
.balign PAGE
region:
    .space 4 * PAGE

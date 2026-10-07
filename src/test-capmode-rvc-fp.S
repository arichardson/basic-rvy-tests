/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability-mode encodings that no other test executes: the stack-relative
 * compressed capability instructions and the F loads and stores. In
 * capability mode (golden Sail src/cheri_insts_cext.sail):
 *
 *  - c.lcsp (C_LYSP, :41-68) and c.scsp (C_SYSP, :119-138) take the RV64
 *    C.FLDSP/C.FSDSP encodings and are ly/sy through sp with a 16-byte
 *    scaled offset, so sp's bounds and permissions authorize them.
 *  - c.cincoffset16csp (C_ADDI16SP_capmode, :140-162) and
 *    c.cincoffset4cspn (C_ADDI4SPN_capmode, :164-187) are YADDI on sp: the
 *    result keeps sp's bounds, and is untagged if sp is sealed.
 *  - flw/fsw keep their encodings, but the base register is a capability
 *    that has to grant the access (ext_data_get_addr,
 *    src/cheri_addr_checks.sail:90-130).
 *
 * The 16-bit encodings are spelled with .insn because the assembler does not
 * accept them with x-register names. A trap steps over four bytes, so every
 * 16-bit instruction is followed by a c.nop, which keeps the next instruction
 * aligned as well.
 */
#define TEST_NAME "capmode-rvc-fp"
#ifdef CHERI_093
#error "RVY v0.9.9 only"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define MSTATUS_FS_INITIAL (1 << 13)

#define root  s0                 /* ddc */
#define bufp  s1                 /* the address of buf */

/* Register numbers for the 16-bit encodings. */
#define X_A0  10
#define X_A1  11
#define X_A2  12

/*
 * One 16-bit instruction and a c.nop. The assembler only takes a 2-byte
 * .insn with C enabled, which is turned on for these alone so that nothing
 * else is compressed.
 */
.macro INSN16 enc
    .option push
    .option rvc
    .insn 2, \enc
    .insn 2, 0x0001              /* c.nop */
    .option pop
.endm

/* c.lcsp x\rd, \off(sp) */
.macro C_LCSP rd, off
    INSN16 (0x2002 | ((((\off) >> 5) & 1) << 12) | ((\rd) << 7) \
                   | ((((\off) >> 4) & 1) << 6) | ((((\off) >> 6) & 0xf) << 2))
.endm

/* c.scsp x\rs2, \off(sp) */
.macro C_SCSP rs2, off
    INSN16 (0xa002 | ((((\off) >> 4) & 3) << 11) \
                   | ((((\off) >> 6) & 0xf) << 7) | ((\rs2) << 2))
.endm

/* c.cincoffset16csp \imm (sp += imm, a non-zero multiple of 16) */
.macro C_CINCOFFSET16CSP imm
    INSN16 (0x6101 | ((((\imm) >> 9) & 1) << 12) \
                   | ((((\imm) >> 4) & 1) << 6) | ((((\imm) >> 6) & 1) << 5) \
                   | ((((\imm) >> 7) & 3) << 3) | ((((\imm) >> 5) & 1) << 2))
.endm

/* c.cincoffset4cspn x\rd, \uimm (rd = sp + uimm; x8 <= rd <= x15) */
.macro C_CINCOFFSET4CSPN rd, uimm
    INSN16 (((((\uimm) >> 4) & 3) << 11) | ((((\uimm) >> 6) & 0xf) << 7) \
            | ((((\uimm) >> 2) & 1) << 6) | ((((\uimm) >> 3) & 1) << 5) \
            | (((\rd) - 8) << 2))
.endm

/* \reg is tagged iff \tag, with base \base_reg + \off and length \len. */
.macro EXPECT_CAP reg, tag, base_reg, off, len
    YTAGR t3, \reg
    li   t4, \tag
    bne  t4, t3, fail
    YBASER t3, \reg
    addi t4, \base_reg, \off
    bne  t4, t3, fail
    YLENR t3, \reg
    li   t4, \len
    bne  t4, t3, fail
.endm

/* The address of \reg is \base_reg + \off. */
.macro EXPECT_ADDR reg, base_reg, off
    addi t4, \base_reg, \off
    bne  t4, \reg, fail
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    li   t0, MSTATUS_FS_INITIAL
    csrs CSR_MSTATUS, t0
    csrrs root, CSR_DDC, x0
    la   bufp, buf
    YMODESWY

    /* sp = [buf, buf + 256), pointing at buf + 128. */
    li   t0, 256
    YADDRW sp, root, bufp
    YBNDSW sp, sp, t0
    YADDI sp, sp, 128

    NEXT_TEST "c.cincoffset16csp moves sp down and keeps its bounds"
    C_CINCOFFSET16CSP -64
    EXPECT_NO_TRAP
    EXPECT_ADDR sp, bufp, 64
    EXPECT_CAP sp, 1, bufp, 0, 256

    NEXT_TEST "c.cincoffset16csp moves sp up and keeps its bounds"
    C_CINCOFFSET16CSP 96
    EXPECT_ADDR sp, bufp, 160
    EXPECT_CAP sp, 1, bufp, 0, 256

    NEXT_TEST "c.cincoffset4cspn derives sp + uimm with sp's bounds"
    C_CINCOFFSET4CSPN X_A0, 36
    EXPECT_ADDR a0, bufp, 196
    EXPECT_CAP a0, 1, bufp, 0, 256
    EXPECT_ADDR sp, bufp, 160    /* sp itself is unchanged */

    NEXT_TEST "c.cincoffset4cspn from a sealed sp is untagged"
    YMV  a2, sp
    YSENTRY sp, sp
    C_CINCOFFSET4CSPN X_A0, 16
    YMV  sp, a2
    EXPECT_ADDR a0, bufp, 176
    YTAGR t3, a0
    bnez t3, fail

    NEXT_TEST "c.cincoffset16csp on a sealed sp clears its tag"
    YSENTRY sp, sp
    C_CINCOFFSET16CSP 16
    YTAGR t3, sp
    bnez t3, fail
    YMV  sp, a2

    /* a1 = root pointing at buf + 8: a capability worth storing. */
    addi t0, bufp, 8
    YADDRW a1, root, t0
    YADDI sp, sp, -160           /* sp = buf */

    NEXT_TEST "c.scsp stores a capability at sp + 16"
    C_SCSP X_A1, 16
    EXPECT_NO_TRAP

    NEXT_TEST "c.lcsp loads it back intact from sp + 16"
    YMV  a2, x0
    C_LCSP X_A2, 16
    EXPECT_NO_TRAP
    YEQ  t3, a2, a1
    beqz t3, fail

    NEXT_TEST "c.lcsp uses the scaled offset: sp + 32 holds no capability"
    C_LCSP X_A2, 32
    EXPECT_NO_TRAP
    YTAGR t3, a2
    bnez t3, fail

    /* sp = [buf, buf + 32). */
    li   t0, 32
    YBNDSW sp, sp, t0

    NEXT_TEST "c.lcsp outside sp's bounds takes a CHERI load fault"
    C_LCSP X_A2, 32
    EXPECT_TRAP CAUSE_CHERI_LOAD

    NEXT_TEST "c.scsp outside sp's bounds takes a CHERI store fault"
    C_SCSP X_A1, 32
    EXPECT_TRAP CAUSE_CHERI_STORE

    NEXT_TEST "control: c.lcsp at the last slot in sp's bounds works"
    C_LCSP X_A2, 16
    EXPECT_NO_TRAP

    NEXT_TEST "c.scsp through an sp without W takes a CHERI store fault"
    li   t0, PERM_W
    YPERMC sp, sp, t0
    C_SCSP X_A1, 16
    EXPECT_TRAP CAUSE_CHERI_STORE

    NEXT_TEST "c.lcsp through an sp without R takes a CHERI load fault"
    YADDRW sp, root, bufp
    li   t0, PERM_R
    YPERMC sp, sp, t0
    C_LCSP X_A2, 16
    EXPECT_TRAP CAUSE_CHERI_LOAD

    /* ---------------------------------------------------------------- F */

    /* a0 = [buf + 64, buf + 72). */
    addi t0, bufp, 64
    YADDRW a0, root, t0
    li   t0, 8
    YBNDSW a0, a0, t0
    li   t1, 0x3f800000          /* 1.0f */
    fmv.w.x ft0, t1

    NEXT_TEST "fsw through a capability in bounds works"
    fsw  ft0, 4(a0)
    EXPECT_NO_TRAP

    NEXT_TEST "flw through a capability reads the value back"
    flw  ft1, 4(a0)
    EXPECT_NO_TRAP
    fmv.x.w t2, ft1
    bne  t2, t1, fail

    NEXT_TEST "flw past the capability's top takes a CHERI load fault"
    flw  ft1, 8(a0)
    EXPECT_TRAP CAUSE_CHERI_LOAD

    NEXT_TEST "fsw past the capability's top takes a CHERI store fault"
    fsw  ft0, 8(a0)
    EXPECT_TRAP CAUSE_CHERI_STORE

    NEXT_TEST "flw below the capability's base takes a CHERI load fault"
    flw  ft1, -4(a0)
    EXPECT_TRAP CAUSE_CHERI_LOAD

    NEXT_TEST "fsw through a capability without W takes a CHERI store fault"
    li   t0, PERM_W
    YPERMC a1, a0, t0
    fsw  ft0, 0(a1)
    EXPECT_TRAP CAUSE_CHERI_STORE

    NEXT_TEST "control: flw through the same capability works"
    flw  ft1, 0(a1)
    EXPECT_NO_TRAP

    NEXT_TEST "flw through a capability without R takes a CHERI load fault"
    li   t0, PERM_R
    YPERMC a1, a0, t0
    flw  ft1, 0(a1)
    EXPECT_TRAP CAUSE_CHERI_LOAD

    NEXT_TEST "flw through an untagged capability takes a CHERI load fault"
    YADDRW a1, x0, a0
    flw  ft1, 0(a1)
    EXPECT_TRAP CAUSE_CHERI_LOAD

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER_PCC

.section .bss
.balign 256
buf:
    .space 256

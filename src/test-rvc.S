/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Compressed capability instructions (Zca in capability mode):
 *
 *  - c.yaddi16sp (c.addi16sp in capability mode) and c.yaddi4spn (c.addi4spn
 *    in capability mode) increment sp's address like YADDI, preserving sp's
 *    bounds and clearing the tag when sp is sealed or the new address steps
 *    outside the representable range (addi16sp_16bit.adoc,
 *    addi4spn_16bit.adoc). In integer mode, c.addi16sp and c.addi4spn write an
 *    untagged integer. Reserved zero-immediate encodings raise an illegal-
 *    instruction exception.
 *  - c.ymv (c.mv in capability mode) copies the full YLEN capability
 *    (preserving tag, bounds, permissions, and seal), whereas in integer mode
 *    c.mv writes an untagged integer, and c.add writes an untagged integer sum
 *    in both modes (cmv_16bit.adoc, add_16bit.adoc).
 *  - c.lysp (c.lcsp) and c.sysp (c.scsp) load and store capabilities relative
 *    to sp with a YLEN_BYTES-scaled unsigned offset, checked against sp's tag,
 *    seal, permissions, and bounds; c.lysp with cd = x0 is reserved
 *    (load_16bit_cap_sprel.adoc, store_16bit_cap_sprel.adoc).
 *  - c.ly (c.lc) and c.sy (c.sc) load and store capabilities relative to
 *    compressed base register cs1' (x8..x15) with a YLEN_BYTES-scaled unsigned
 *    offset, checked against cs1's tag, seal, permissions, and bounds
 *    (load_16bit_cap.adoc, store_16bit_cap.adoc).
 */
#define TEST_NAME "rvc"
#include "testmacros.h"
#include "exceptions.h"

#define root  s0                 /* ddc */
#if __riscv_xlen == 64
#define REP_BASE_OFFSET -4096
#else
#define REP_BASE_OFFSET -256
#endif
#define bufp  s1                 /* address of buf */

/* \reg is tagged iff \tag, with base \base_reg + \off and length \len. */
.macro EXPECT_CAP reg, tag, base_reg, off, len
    EXPECT_TAG \reg, \tag
    YBASER t3, \reg
    addi t4, \base_reg, \off
    EXPECT_EQ t4, t3
    YLENR t3, \reg
    li   t4, \len
    EXPECT_EQ t4, t3
.endm

/* The address of \reg is \base_reg + \off. */
.macro EXPECT_ADDR reg, base_reg, off
    addi t4, \base_reg, \off
    EXPECT_EQ t4, \reg
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    csrrs root, CSR_DDC, x0
    lla  bufp, buf
    YMODESWY

    /* sp = [buf, buf + 256), pointing at buf + 128. */
    li   t0, 256
    YADDRW sp, root, bufp
    YBNDSW sp, sp, t0
    YADDI sp, sp, 128

    NEXT_TEST "c.yaddi16sp moves sp down and keeps its bounds"
    C_YADDI16SP -64
    EXPECT_NO_TRAP
    EXPECT_ADDR sp, bufp, 64
    EXPECT_CAP sp, 1, bufp, 0, 256

    NEXT_TEST "c.yaddi16sp moves sp up and keeps its bounds"
    C_YADDI16SP 96
    EXPECT_ADDR sp, bufp, 160
    EXPECT_CAP sp, 1, bufp, 0, 256

    NEXT_TEST "c.yaddi4spn derives sp + uimm with sp's bounds"
    C_YADDI4SPN a0, 36
    EXPECT_ADDR a0, bufp, 196
    EXPECT_CAP a0, 1, bufp, 0, 256
    EXPECT_ADDR sp, bufp, 160    /* sp itself is unchanged */

    NEXT_TEST "c.yaddi4spn from a sealed sp produces an untagged capability"
    YMV  a2, sp
    YSEALE sp, sp
    C_YADDI4SPN a0, 16
    YMV  sp, a2
    EXPECT_ADDR a0, bufp, 176
    EXPECT_TAG a0, 0

    NEXT_TEST "c.yaddi16sp on a sealed sp clears its tag"
    YSEALE sp, sp
    C_YADDI16SP 16
    EXPECT_ADDR sp, bufp, 176
    EXPECT_TAG sp, 0
    YMV  sp, a2

    NEXT_TEST "c.yaddi16sp outside sp's representable range clears its tag"
    li   t0, 16
    YADDRW sp, root, bufp
    YBNDSW sp, sp, t0            /* sp = [buf, buf + 16), E = 0 */
    li   t0, REP_BASE_OFFSET
    YADD sp, sp, t0              /* at the bottom of E = 0 representable range */
    EXPECT_TAG sp, 1
    C_YADDI16SP -16              /* steps below representable base */
    addi t0, t0, -16
    add  t4, bufp, t0
    EXPECT_EQ t4, sp
    EXPECT_TAG sp, 0
    YMV  sp, a2

    NEXT_TEST "integer mode: c.addi16sp and c.addi4spn clear the capability tag"
    YMODESWI
    C_YADDI4SPN a0, 16
    EXPECT_ADDR a0, bufp, 176
    EXPECT_TAG a0, 0
    C_YADDI16SP 16
    EXPECT_ADDR sp, bufp, 176
    EXPECT_TAG sp, 0
    YMODESWY
    YMV  sp, a2

    NEXT_TEST "reserved c.addi16sp and c.addi4spn zero-immediate encodings trap"
    INSN16 0x6101                /* c.addi16sp with nzimm = 0 */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    INSN16 0x0000                /* c.addi4spn x8, sp, 0 (all-zeros opcode) */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN
    INSN16 0x0004                /* c.addi4spn x9, sp, 0 */
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    NEXT_TEST "c.ymv copies a full capability in capability mode"
    C_YMV a0, sp
    EXPECT_NO_TRAP
    YEQ  t3, a0, sp
    EXPECT_NONZERO t3
    YSEALE a1, sp
    C_YMV a0, a1
    YEQ  t3, a0, a1
    EXPECT_NONZERO t3

    NEXT_TEST "integer-mode c.mv and both modes' c.add clear the capability tag"
    C_YMV a0, sp
    li   t0, 16
    C_ADD a0, t0
    EXPECT_ADDR a0, bufp, 176
    EXPECT_TAG a0, 0
    YMODESWI
    C_YMV a0, sp
    EXPECT_ADDR a0, bufp, 160
    EXPECT_TAG a0, 0
    C_YMV a0, sp
    C_ADD a0, t0
    EXPECT_ADDR a0, bufp, 176
    EXPECT_TAG a0, 0
    YMODESWY

    /* a1 = root pointing at buf + 8: a capability to store. */
    addi t0, bufp, 8
    YADDRW a1, root, t0
    YADDI sp, sp, -160           /* sp = [buf, buf + 256) at buf */

    NEXT_TEST "c.sysp stores a capability at sp + YLEN_BYTES"
    C_SYSP a1, YLEN_BYTES
    EXPECT_NO_TRAP

    NEXT_TEST "c.lysp loads it back intact from sp + YLEN_BYTES"
    YMV  a2, x0
    C_LYSP a2, YLEN_BYTES
    EXPECT_NO_TRAP
    YEQ  t3, a2, a1
    EXPECT_NONZERO t3

    NEXT_TEST "c.lysp uses the scaled offset: sp + 2 * YLEN_BYTES holds no capability"
    C_LYSP a2, (2 * YLEN_BYTES)
    EXPECT_NO_TRAP
    EXPECT_TAG a2, 0

    NEXT_TEST "reserved c.lysp with cd = x0 raises an illegal-instruction exception"
    INSN16 ((C_LYSP_FUNCT3 << 13) | (C_LYSP_IMM(YLEN_BYTES) << 2) | 2)
    EXPECT_TRAP CAUSE_ILLEGAL_INSN

    /* sp = [buf, buf + 2 * YLEN_BYTES). */
    li   t0, (2 * YLEN_BYTES)
    YBNDSW sp, sp, t0

    NEXT_TEST "c.lysp outside sp's bounds takes a capability bounds fault"
    C_LYSP a2, (2 * YLEN_BYTES)
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)

    NEXT_TEST "c.sysp outside sp's bounds takes a capability bounds fault"
    C_SYSP a1, (2 * YLEN_BYTES)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    NEXT_TEST "control: c.lysp at the last slot in sp's bounds succeeds"
    C_LYSP a2, YLEN_BYTES
    EXPECT_NO_TRAP

    NEXT_TEST "c.sysp through an sp without W takes a capability permission fault"
    li   t0, DROP_MASK(PERM_W)
    DROP_PERMS sp, sp, t0
    C_SYSP a1, YLEN_BYTES
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)

    NEXT_TEST "c.lysp through an sp without R takes a capability permission fault"
    YADDRW sp, root, bufp
    li   t0, DROP_MASK(PERM_R)
    DROP_PERMS sp, sp, t0
    C_LYSP a2, YLEN_BYTES
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)

    NEXT_TEST "c.sysp and c.lysp through an untagged sp take a capability tag fault"
    YADDRW sp, x0, bufp
    C_SYSP a1, YLEN_BYTES
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    C_LYSP a2, YLEN_BYTES
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)

    NEXT_TEST "c.sysp and c.lysp through a sealed sp take a capability seal fault"
    YADDRW sp, root, bufp
    YSEALE sp, sp
    C_SYSP a1, YLEN_BYTES
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    C_LYSP a2, YLEN_BYTES
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)

    /* a0 = [buf, buf + 2 * YLEN_BYTES) for register-based c.sy / c.ly. */
    YADDRW a0, root, bufp
    li   t0, (2 * YLEN_BYTES)
    YBNDSW a0, a0, t0

    NEXT_TEST "c.sy stores a capability at cs1' + YLEN_BYTES and c.ly loads it back"
    YMV  a2, x0
    C_SY a1, 0, a0
    EXPECT_NO_TRAP
    C_LY a2, 0, a0
    EXPECT_NO_TRAP
    YEQ  t3, a2, a1
    EXPECT_NONZERO t3
    YMV  a2, x0
    C_SY a1, YLEN_BYTES, a0
    EXPECT_NO_TRAP
    C_LY a2, YLEN_BYTES, a0
    EXPECT_NO_TRAP
    YEQ  t3, a2, a1
    EXPECT_NONZERO t3

    NEXT_TEST "c.ly and c.sy outside cs1's bounds take capability bounds faults"
    C_LY a2, (2 * YLEN_BYTES), a0
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    C_SY a1, (2 * YLEN_BYTES), a0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)

    NEXT_TEST "c.sy without W and c.ly without R take capability permission faults"
    li   t0, DROP_MASK(PERM_W)
    DROP_PERMS a3, a0, t0
    C_SY a1, 0, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    C_LY a2, 0, a3
    EXPECT_NO_TRAP
    li   t0, DROP_MASK(PERM_R)
    DROP_PERMS a3, a0, t0
    C_LY a2, 0, a3
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)

    NEXT_TEST "c.sy and c.ly through an untagged or sealed cs1' take tag and seal faults"
    YADDRW a3, x0, bufp
    C_SY a1, 0, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    C_LY a2, 0, a3
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    YSEALE a3, a0
    C_SY a1, 0, a3
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    C_LY a2, 0, a3
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
buf:
    .space 256

/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Malformed capabilities, permission legalization, and RVC/32-bit HINTs
 * (golden Sail src/cheri_prelude_128.sail:39-93,
 * src/cheri_cap_common.sail:211-237, 367-393, 564,
 * src/cheri_insts.sail:131-325, 650-687):
 *
 *  - capIsMalformed is true when reserved_0 (pesbt[42:28]) or reserved_1
 *    (pesbt[59:53]) is non-zero, when AP_P (pesbt[52:44]) is outside
 *    ap_p_encdec (ASR without X, C without R|W, M=1 without X, SL without C,
 *    or EL|LM without C&R), or when internal-exponent bounds (EF=0) have
 *    E=52 with B!=0, E=51 with B[13]!=0, or E<0 (TE@BE > 52).
 *  - On any malformed capability, YBASER, YLENR, YTOPR, YMODER, and YSS
 *    return 0, YBLD leaves cd untagged, and YPERMR zeroes the architectural
 *    permissions while still reporting GL and SDP.
 *  - YPERMC on a capability whose only defect is permsMalformed zeroes its
 *    architectural permissions and sets M=0 while keeping GL, SDP, and bounds,
 *    producing a well-formed capability that YBLD can re-tag.
 *  - YPERMC and LY without PERM_LM legalize the remaining permissions via
 *    legalizePermsAndMode.
 *  - RVC HINTs with rd != x0 (c.addi rd, 0; c.slli64; c.srli64; c.srai64)
 *    write rd as an integer (clearing its tag), whereas HINTs targeting x0,
 *    NTL add x0, x0, x2..x5, fence, and fence.i are pure NOPs.
 */
#define TEST_NAME "malformed-cap"
#ifdef CHERI_093
#error "RVY v0.9.9 only"
#endif
#include "testmacros.h"
#include "exceptions.h"

#define PERM_LM   (1 << 1)
#define PERM_EL   (1 << 2)
#define PERM_SL   (1 << 3)
#define PERM_GL   (1 << 4)
#define PERM_ARCH (PERM_R | PERM_W | PERM_X | PERM_C | PERM_ASR | \
                   PERM_LM | PERM_EL | PERM_SL)

/* EncMetadata AP_P field sits at pesbt[52:44] (9 bits: SL..C, P). */
#define AP_P_SHIFT 44
#define AP_P_MASK  (0x1ff << AP_P_SHIFT)
#define AP_P_SL    (1 << 8)
#define AP_P_EL    (1 << 7)
#define AP_P_LM    (1 << 6)
#define AP_P_ASR   (1 << 5)
#define AP_P_X     (1 << 4)
#define AP_P_R     (1 << 3)
#define AP_P_W     (1 << 2)
#define AP_P_C     (1 << 1)
#define AP_P_M     (1 << 0)

#define root  s0                 /* ddc */
#define bufp  s1                 /* address of buf */
#define basep s2                 /* pesbt of [buf, buf+64), RWX, M=1 */

.macro INSN16 enc
    .option push
    .option rvc
    .insn 2, \enc
    .insn 2, 0x0001              /* c.nop */
    .option pop
.endm

/*
 * Check that \reg is treated as malformed by YBASER, YLENR, YTOPR, YMODER,
 * YSS, YBLD, and YPERMR (which must zero all architectural permissions while
 * keeping GL=1).
 */
.macro EXPECT_MALFORMED reg
    YBASER t3, \reg
    bnez t3, fail
    YLENR t3, \reg
    bnez t3, fail
    YTOPR t3, \reg
    bnez t3, fail
    YMODER t3, \reg
    bnez t3, fail
    YSS  t3, root, \reg
    bnez t3, fail
    YSS  t3, \reg, \reg
    bnez t3, fail
    YBLD a4, root, \reg
    YTAGR t3, a4
    bnez t3, fail
    YPERMR t3, \reg
    li   t4, PERM_ARCH
    and  t4, t3, t4
    bnez t4, fail
    andi t4, t3, PERM_GL
    beqz t4, fail
.endm

/* Replace the AP_P field of basep with \ap_p and pack with bufp into a3. */
.macro MAKE_AP_P ap_p
    li   t0, ~AP_P_MASK
    and  t0, basep, t0
    li   t1, ((\ap_p) << AP_P_SHIFT)
    or   t0, t0, t1
    PACKY a3, bufp, t0
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS
    csrrs root, CSR_DDC, x0
    la   bufp, buf
    YMODESWY

    /*
     * Build a0 = [buf, buf + 64) with M = 1 (integer mode) and save its
     * raw metadata in basep. Even untagged (via PACKY), a well-formed
     * capability reports its bounds and mode.
     */
    YADDRW a0, root, bufp
    li   t0, 64
    YBNDSW a0, a0, t0
    li   t0, 1
    YMODEW a0, a0, t0
    SRLIY basep, a0, 64

    NEXT_TEST "control: untagged well-formed capability reports bounds and mode"
    PACKY a3, bufp, basep
    YBASER t3, a3
    bne  bufp, t3, fail
    YLENR t3, a3
    li   t4, 64
    bne  t4, t3, fail
    YTOPR t3, a3
    addi t4, bufp, 64
    bne  t4, t3, fail
    YMODER t3, a3
    li   t4, 1
    bne  t4, t3, fail
    YBLD a4, root, a3
    YTAGR t3, a4
    beqz t3, fail

    /* ---------------------------------------------------- permsMalformed */

    NEXT_TEST "reserved AP_P: ASR without X is malformed"
    MAKE_AP_P (0x1ff & ~AP_P_X)
    EXPECT_MALFORMED a3

    NEXT_TEST "reserved AP_P: C without R or W is malformed"
    MAKE_AP_P AP_P_C
    EXPECT_MALFORMED a3

    NEXT_TEST "reserved AP_P: integer mode (M=1) without X is malformed"
    MAKE_AP_P (AP_P_R | AP_P_M)
    EXPECT_MALFORMED a3

    NEXT_TEST "reserved AP_P: SL without C is malformed"
    MAKE_AP_P (AP_P_SL | AP_P_R | AP_P_W)
    EXPECT_MALFORMED a3

    NEXT_TEST "reserved AP_P: LM without C is malformed"
    MAKE_AP_P (AP_P_LM | AP_P_R)
    EXPECT_MALFORMED a3

    NEXT_TEST "reserved AP_P: EL without R is malformed"
    MAKE_AP_P (AP_P_EL | AP_P_C | AP_P_W)
    EXPECT_MALFORMED a3

    /* -------------------------------------------------- capReservedValid */

    NEXT_TEST "non-zero reserved_0 bits (pesbt[42:28]) are malformed"
    li   t0, (1 << 28)
    or   t0, basep, t0
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3
    li   t0, (1 << 42)
    or   t0, basep, t0
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3

    NEXT_TEST "non-zero reserved_1 bits (pesbt[59:53]) are malformed"
    li   t0, (1 << 53)
    or   t0, basep, t0
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3
    li   t0, (1 << 59)
    or   t0, basep, t0
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3

    /* --------------------------------------------------- boundsMalformed */

    NEXT_TEST "malformed bounds: EF=0, E=52 with B!=0, E=51 with B[13]=1, E<0"
    SRLIY t2, root, 64           /* root has EF=0, TE=0, BE=0 (E=52), B=0 */
    ori  t0, t2, (1 << 3)        /* E = 52 with Bm != 0 */
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3
    li   t1, (1 << 13) | 1       /* BE = 1 (E = 51) with B[13] = 1 */
    or   t0, t2, t1
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3
    li   t1, (7 << 14) | 7       /* TE = 7, BE = 7 (encoded 63 -> E = -11) */
    or   t0, t2, t1
    PACKY a3, bufp, t0
    EXPECT_MALFORMED a3

    /* ----------------------------------------- YPERMC on malformed perms */

    NEXT_TEST "ypermc on permsMalformed zeroes AP and M=0, keeps GL/SDP/bounds"
    MAKE_AP_P (0x1ff & ~AP_P_X)  /* ASR without X, M = 1 */
    YPERMC a4, a3, x0
    YTAGR t3, a4
    bnez t3, fail
    /* Now AP_P = 0 (well-formed null perms), so bounds and GL/SDP are live. */
    YBASER t3, a4
    bne  bufp, t3, fail
    YLENR t3, a4
    li   t4, 64
    bne  t4, t3, fail
    YMODER t3, a4
    bnez t3, fail
    YPERMR t3, a4
    li   t4, 0xf8ffd0            /* reserved ones + SDP=0xf + GL=1, AP=0 */
    bne  t4, t3, fail
    YBLD a5, root, a4
    YTAGR t3, a5
    beqz t3, fail

    NEXT_TEST "ymodew, ysentry, yadd, and YLEN CSR writes on malformed caps"
    /* YMODEW on a malformed capability keeps metadata unchanged and tag 0. */
    MAKE_AP_P (0x1ff & ~AP_P_X)
    YMODEW a4, a3, x0
    YTAGR t3, a4
    bnez t3, fail
    YEQ  t3, a4, a3
    beqz t3, fail
    /* YSENTRY sets CT = 1 even on an unsealed malformed capability. */
    YSENTRY a4, a3
    YTYPER t3, a4
    li   t4, 1
    bne  t4, t3, fail
    /* YADD updates the address of a malformed capability with tag 0. */
    li   t0, 16
    YADD a4, a3, t0
    YTAGR t3, a4
    bnez t3, fail
    addi t4, bufp, 16
    bne  t4, a4, fail
    /* YLEN CSR writes (mscratch, ddc) of a malformed capability keep tag 0. */
    csrw CSR_MSCRATCH, a3
    csrrs a4, CSR_MSCRATCH, x0
    YTAGR t3, a4
    bnez t3, fail
    csrw CSR_DDC, a3
    csrrs a4, CSR_DDC, x0
    csrw CSR_DDC, root
    YTAGR t3, a4
    bnez t3, fail

    /* -------------------------------------- legalizePermsAndMode: YPERMC */

    NEXT_TEST "ypermc clearing C also clears LM, EL, and SL"
    li   t0, PERM_C
    YPERMC a3, a0, t0
    YTAGR t3, a3
    beqz t3, fail
    YPERMR t3, a3
    li   t4, PERM_C | PERM_LM | PERM_EL | PERM_SL
    and  t4, t3, t4
    bnez t4, fail
    li   t4, PERM_R | PERM_W | PERM_X | PERM_ASR | PERM_GL
    and  t3, t3, t4
    bne  t4, t3, fail
    YMODER t3, a3
    li   t4, 1                   /* X is kept, so M = 1 survives */
    bne  t4, t3, fail

    NEXT_TEST "ypermc clearing X also clears ASR and forces M = 0"
    li   t0, PERM_X
    YPERMC a3, a0, t0
    YTAGR t3, a3
    beqz t3, fail
    YPERMR t3, a3
    li   t4, PERM_X | PERM_ASR
    and  t4, t3, t4
    bnez t4, fail
    YMODER t3, a3
    bnez t3, fail                /* M forced to 0 (capability mode) */

    NEXT_TEST "ypermc clearing R also clears EL and LM, keeping C, W, and SL"
    li   t0, PERM_R
    YPERMC a3, a0, t0
    YTAGR t3, a3
    beqz t3, fail
    YPERMR t3, a3
    li   t4, PERM_R | PERM_EL | PERM_LM
    and  t4, t3, t4
    bnez t4, fail
    li   t4, PERM_C | PERM_W | PERM_SL
    and  t3, t3, t4
    bne  t4, t3, fail

    NEXT_TEST "loading a C+W+SL capability without LM legalizes C and SL away"
    li   t0, PERM_R | PERM_X     /* leaves C, W, SL, and GL (no R, X, ASR) */
    YPERMC a3, a0, t0
    SY   a3, 0(a0)
    li   t0, PERM_LM
    YPERMC a4, a0, t0            /* authority without LM */
    LY   a5, 0(a4)
    YTAGR t3, a5
    beqz t3, fail
    YPERMR t3, a5
    li   t4, PERM_ARCH
    and  t4, t3, t4
    bnez t4, fail                /* W stripped -> C and SL legalized to 0 */
    andi t4, t3, PERM_GL
    beqz t4, fail                /* GL survives */

    /* --------------------------------------- RVC and 32-bit HINT opcodes */

    NEXT_TEST "rvc hints with rd != x0 write rd as integer and clear its tag"
    /* c.addi a2, 0 (0x0601) */
    YMV  a2, a0
    INSN16 0x0601
    YTAGR t3, a2
    bnez t3, fail
    bne  bufp, a2, fail
    /* c.slli64 a2 (0x0602) */
    YMV  a2, a0
    INSN16 0x0602
    YTAGR t3, a2
    bnez t3, fail
    bne  bufp, a2, fail
    /* c.srli64 a2 (rd' = 4 -> 0x8201) */
    YMV  a2, a0
    INSN16 0x8201
    YTAGR t3, a2
    bnez t3, fail
    bne  bufp, a2, fail
    /* c.srai64 a2 (rd' = 4 -> 0x8601) */
    YMV  a2, a0
    INSN16 0x8601
    YTAGR t3, a2
    bnez t3, fail
    bne  bufp, a2, fail

    NEXT_TEST "rvc hints targeting x0 and 32-bit NTL/fence hints are pure NOPs"
    YMV  a2, a0
    INSN16 (0x9002 | (12 << 2))  /* c.add x0, a2 */
    INSN16 (0x8002 | (12 << 2))  /* c.mv  x0, a2 */
    INSN16 0x0002                /* c.slli64 x0 */
    INSN16 0x4005                /* c.li x0, 1 */
    INSN16 0x6005                /* c.lui x0, 1 */
    INSN16 0x0005                /* c.nop 1 */
    .insn 4, 0x00200033          /* add x0, x0, x2 (NTL hint) */
    .insn 4, 0x00500033          /* add x0, x0, x5 (NTL hint) */
    .insn 4, 0x8330808f          /* fence.tso with rd = rs1 = x1 */
    .insn 4, 0xffff9f8f          /* fence.i with imm=0xfff, rs1=x31, rd=x31 */
    EXPECT_NO_TRAP
    YTAGR t3, a2
    beqz t3, fail
    bnez x0, fail

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER_PCC

.section .bss
.balign 64
buf:
    .space 64

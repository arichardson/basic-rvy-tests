/* SPDX-License-Identifier: BSD-2-Clause
 *
 * The RVY instruction encodings, and the CSR numbers and field constants
 * that go with them. Split out of testmacros.h so that console.S can use
 * them too: testmacros.h also defines tohost and demands a TEST_NAME, so it
 * can only be included by the one object that carries the test itself.
 *
 * No assembler knows the RVY mnemonics yet, so every one of these is really
 * a raw .insn directive underneath. The macros exist so that tests do not
 * have to spell that out, or the opcode and funct7 numbers, themselves.
 *
 * NOTE: all conditional branches must use the canonical RVY operand order
 * (rs1 > rs2 by register number); the swapped forms are reserved encodings.
 */
#pragma once

/* The CHERI execution mode a capability carries, as read by YMODER and
 * written by YMODEW. These are also the rs2 values YMODESWY/YMODESWI use. */
#define CHERI_MODE_CAP 0
#define CHERI_MODE_INT 1

/* CSR numbers (spelled numerically so any assembler accepts them) */
#define CSR_MSTATUS 0x300
#define CSR_MISA    0x301
#define CSR_MTVEC   0x305
#define CSR_MENVCFG 0x30A
#define CSR_MSCRATCH 0x340
#define CSR_MEPC    0x341
#define CSR_MCAUSE  0x342
#define CSR_MTVAL2  0x34B
#define CSR_PMPCFG0 0x3A0
#define CSR_PMPADDR0 0x3B0
#define CSR_STVEC   0x105
#define CSR_SEPC    0x141
#define CSR_VSTVEC  0x205
#define CSR_VSEPC   0x241
#define CSR_DDC     0x416
/* CHERI thread ID registers, readable without ASR but writable only with it. */
#define CSR_UTIDC   0x480
#define CSR_STIDC   0x580
#define CSR_MTIDC   0x780
#define CSR_MSECCFG 0x747

#define MSECCFG_CRE (1 << 3)

/*
 * Dropping permissions: RVY has ypermc, which clears the bits in the mask,
 * while 0.9.3 only has acperm, which keeps them, so the mask is complemented
 * there. Spelled as two defines rather than a macro so neither version needs
 * a scratch register to invert it.
 */
#ifdef CHERI_093
#define DROP_PERMS   ACPERM
#define DROP_MASK(p) ~(p)
#else
#define DROP_PERMS   YPERMC
#define DROP_MASK(p) (p)
#endif

#define MISA_Y      (1 << 24)
#define MISA_C      (1 << 2)
#ifdef CHERI_093
/* 0.9.3 put the S-mode CHERI enable at bit 28 rather than bit 9. */
#define MENVCFG_CRE (1 << 28)
#else
#define MENVCFG_CRE (1 << 9)
#endif

/* Architectural permission bits, as read by YPERMR / cleared by YPERMC. */
#define PERM_W      (1 << 0)
#define PERM_C      (1 << 5)
#define PERM_ASR    (1 << 16)
#define PERM_X      (1 << 17)
#define PERM_R      (1 << 18)
/*
 * RVY instruction encodings (custom-3 opcode 0x7b, plus the RVY-modified
 * CBOs). No assembler knows these mnemonics yet, so every one is really a
 * raw .insn directive underneath -- these macros exist so that tests don't
 * have to spell that out (or the opcode/funct7 numbers) themselves.
 *
 * Field legend (matches target/riscv/insn32-cheri-rvy.decode):
 *   cd/cs1/cs2 - capability register operands
 *   rd/rs1/rs2 - integer register operands
 * The underlying directives (all positional, matching LLVM/binutils syntax):
 *   R-type: .insn r opcode, funct3, funct7, rd,  rs1, rs2
 *   I-type: .insn i opcode, funct3,         rd,  rs1, simm12
 *   S-type: .insn s opcode, funct3,         rs2, simm12(rs1)
 */
#define RVY_OPC 0x7b
#define CBO_OPC 0x0f

#ifndef CHERI_093
/* ---------------------------------------------------------------- RVY --- */

/* Three-operand instructions (funct3 = 0, sub-op selected by funct7) */
.macro PACKY cd, rs1, rs2
    .insn r RVY_OPC, 0, 0x01, \cd, \rs1, \rs2
.endm
.macro YADD cd, cs1, rs2
    .insn r RVY_OPC, 0, 0x03, \cd, \cs1, \rs2
.endm
/* YMV is YADD with rs2 forced to x0 -- that is what selects it over YADD. */
.macro YMV cd, cs1
    YADD \cd, \cs1, x0
.endm
.macro YADDRW cd, cs1, rs2
    .insn r RVY_OPC, 0, 0x0b, \cd, \cs1, \rs2
.endm
.macro YPERMC cd, cs1, rs2
    .insn r RVY_OPC, 0, 0x13, \cd, \cs1, \rs2
.endm
.macro YBNDSW cd, cs1, rs2
    .insn r RVY_OPC, 0, 0x1b, \cd, \cs1, \rs2
.endm
.macro YBNDSRW cd, cs1, rs2
    .insn r RVY_OPC, 0, 0x23, \cd, \cs1, \rs2
.endm
/* YMODESWY/YMODESWI (rs2 = 0/1 respectively) select the mode-switch forms;
 * anything else with this funct7 is YMODEW. */
.macro YMODESWY
    .insn r RVY_OPC, 0, 0x2b, x0, x0, x0
.endm
.macro YMODESWI
    .insn r RVY_OPC, 0, 0x2b, x0, x0, x1
.endm
.macro YMODEW cd, cs1, rs2
    .insn r RVY_OPC, 0, 0x2b, \cd, \cs1, \rs2
.endm
.macro YSH1ADD cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x05, \cd, \rs1, \cs2
.endm
.macro YSH2ADD cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x0d, \cd, \rs1, \cs2
.endm
.macro YSH3ADD cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x15, \cd, \rs1, \cs2
.endm
.macro YSH4ADD cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x1d, \cd, \rs1, \cs2
.endm
.macro YSH1ADD_UW cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x25, \cd, \rs1, \cs2
.endm
.macro YSH2ADD_UW cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x2d, \cd, \rs1, \cs2
.endm
.macro YSH3ADD_UW cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x35, \cd, \rs1, \cs2
.endm
.macro YSH4ADD_UW cd, rs1, cs2
    .insn r RVY_OPC, 0, 0x3d, \cd, \rs1, \cs2
.endm
.macro YEQ rd, cs1, cs2
    .insn r RVY_OPC, 0, 0x06, \rd, \cs1, \cs2
.endm
.macro YSS rd, cs1, cs2
    .insn r RVY_OPC, 0, 0x0e, \rd, \cs1, \cs2
.endm
.macro YSUNSEAL cd, cs1, cs2
    .insn r RVY_OPC, 0, 0x07, \cd, \cs1, \cs2
.endm
.macro YBLD cd, cs1, cs2
    .insn r RVY_OPC, 0, 0x0f, \cd, \cs1, \cs2
.endm

/* Two-operand instructions: funct7 = 0x7a, sub-op selected via the rs2
 * field (0=YBASER 1=YPERMR 2=YTOPR 3=YLENR 4=YTAGR 5=YTYPER 6=YMODER). */
.macro YBASER rd, cs1
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x0
.endm
.macro YPERMR rd, cs1
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x1
.endm
.macro YTOPR rd, cs1
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x2
.endm
.macro YLENR rd, cs1
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x3
.endm
.macro YTAGR rd, cs1
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x4
.endm
.macro YTYPER rd, cs1
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x5
.endm
.macro YMODER rd, cs1                 /* hybrid-only */
    .insn r RVY_OPC, 0, 0x7a, \rd, \cs1, x6
.endm

.macro YAMASK rd, rs1
    .insn r RVY_OPC, 0, 0x78, \rd, \rs1, x0
.endm

/* cs1 must be x0 (reserved for a future YSEAL); the source capability sits
 * in the cs2/rs2 field position instead. */
.macro YSENTRY cd, cs2
    .insn r RVY_OPC, 0, 0x17, \cd, x0, \cs2
.endm

/* Immediate instructions (funct3 selects the sub-op) */
.macro YADDI cd, cs1, imm
    .insn i RVY_OPC, 4, \cd, \cs1, \imm
.endm

.macro SRLIY rd, cs1, shamt
    .insn i RVY_OPC, 5, \rd, \cs1, \shamt
.endm

/*
 * YBNDSWI's 9-bit immediate does not map linearly onto the requested
 * capability length (see decode_ybndswi_imm() in
 * target/riscv/insn_trans/trans_cheri.c.inc). YBNDSWI_RAW takes the
 * already-encoded 9-bit value for tests that want to exercise specific
 * bit patterns directly; YBNDSWI takes the desired length and works out
 * the matching imm9 across the four representable regions:
 *   length == 4096       -> imm9 = 0                        (page sized)
 *   1 <= length <= 255    -> imm9 = length                   (byte granular)
 *   256 <= length <= 504  -> imm9 = 0x100 | packed nibbles    (8-byte granular)
 *   512 <= length <= 4080 -> imm9 = 0x100 | (length >> 4)    (16-byte granular)
 */
.macro YBNDSWI_RAW cd, cs1, imm9
    .insn i RVY_OPC, 5, \cd, \cs1, (\imm9) - 512
.endm

.macro YBNDSWI cd, cs1, length
    .if (\length) == 4096
        YBNDSWI_RAW \cd, \cs1, 0
    .elseif (\length) >= 1 && (\length) <= 255
        YBNDSWI_RAW \cd, \cs1, (\length)
    .elseif (\length) >= 256 && (\length) <= 504 && (((\length) - 256) % 8) == 0
        YBNDSWI_RAW \cd, \cs1, \
            (0x100 | (((((\length) - 256) / 8) & 1) << 4) \
                    | ((((\length) - 256) / 8) >> 1))
    .elseif (\length) >= 512 && (\length) <= 4080 && ((\length) % 16) == 0
        YBNDSWI_RAW \cd, \cs1, (0x100 | ((\length) >> 4))
    .else
        .error "YBNDSWI: length is not exactly representable"
    .endif
.endm

/* Loads and stores (funct3 selects the sub-op). addr is written the same
 * way as for a normal load/store mnemonic, e.g. "LY a0, 16(a0)". */
.macro LY cd, addr
    .insn i RVY_OPC, 1, \cd, \addr
.endm
.macro SY cs2, addr
    .insn s RVY_OPC, 2, \cs2, \addr
.endm

/* Atomics (funct3 = 3, sub-op + aq/rl in funct7; aq = rl = 0 here since
 * these tests are all single-hart). */
.macro LR_Y cd, cs1
    .insn r RVY_OPC, 3, 0x08, \cd, \cs1, x0
.endm
.macro AMOSWAP_Y cd, cs1, cs2
    .insn r RVY_OPC, 3, 0x04, \cd, \cs1, \cs2
.endm
.macro SC_Y rd, cs1, cs2
    .insn r RVY_OPC, 3, 0x0c, \rd, \cs1, \cs2
.endm

#else /* CHERI_093 */
/*
 * The 0.9.3 standard encodes the same operations on the base OP opcode with
 * different mnemonics (see target/riscv/insn32-cheri-std.decode), so only the
 * subset the tests actually use is provided here; anything without a 0.9.3
 * equivalent errors out at assembly time.
 */
#define STD_OPC     0x33   /* OP    */
#define STD_AMO_OPC 0x2f   /* AMO   */
#define STD_LY_OPC  0x0f   /* ly    */
#define STD_SY_OPC  0x23   /* sy    */

/* Two-operand reads: funct7 0x08, sub-op selected via the rs2 field. */
.macro YTAGR rd, cs1
    .insn r STD_OPC, 0, 0x08, \rd, \cs1, x0     /* gctag */
.endm
.macro YTYPER rd, cs1
    .insn r STD_OPC, 0, 0x08, \rd, \cs1, x2     /* gctype */
.endm
.macro YLENR rd, cs1
    .insn r STD_OPC, 0, 0x08, \rd, \cs1, x6     /* gclen */
.endm
.macro YAMASK rd, rs1
    .insn r STD_OPC, 0, 0x08, \rd, \rs1, x7     /* cram */
.endm
/* sentry takes its source in cs1, unlike the v0.9.9 YSENTRY which uses cs2. */
.macro YSENTRY cd, cs2
    .insn r STD_OPC, 0, 0x08, \cd, \cs2, x8     /* sentry */
.endm

.macro YADDRW cd, cs1, rs2
    .insn r STD_OPC, 1, 0x06, \cd, \cs1, \rs2   /* scaddr */
.endm
.macro YBNDSW cd, cs1, rs2
    .insn r STD_OPC, 0, 0x07, \cd, \cs1, \rs2  /* scbnds */
.endm

.macro YMV cd, cs1
    .insn r STD_OPC, 0, 0x06, \cd, \cs1, x0    /* cmv */
.endm
.macro ACPERM cd, cs1, rs2
    .insn r STD_OPC, 2, 0x06, \cd, \cs1, \rs2 /* acperm: keeps rs2's bits */
.endm
.macro YMODER rd, cs1
    .insn r STD_OPC, 0, 0x08, \rd, \cs1, x3    /* gcmode */
.endm
.macro YMODEW cd, cs1, rs2
    .insn r STD_OPC, 7, 0x06, \cd, \cs1, \rs2 /* scmode */
.endm
.macro YPERMR rd, cs1
    .insn r STD_OPC, 0, 0x08, \rd, \cs1, x1    /* gcperm */
.endm
.macro YBLD cd, cs1, cs2
    .insn r STD_OPC, 5, 0x06, \cd, \cs1, \cs2 /* cbld */
.endm
.macro YADDI cd, cs1, imm
    .insn i 0x1b, 2, \cd, \cs1, \imm          /* caddi */
.endm

.macro YMODESWY
    .insn r STD_OPC, 1, 0x09, x0, x0, x0        /* modesw.cap */
.endm
.macro YMODESWI
    .insn r STD_OPC, 1, 0x0a, x0, x0, x0        /* modesw.int */
.endm

.macro LY cd, addr
    .insn i STD_LY_OPC, 4, \cd, \addr
.endm
.macro SY cs2, addr
    .insn s STD_SY_OPC, 4, \cs2, \addr
.endm

/* Atomics: same funct7 values as RVY, but on the AMO opcode with funct3 4. */
.macro LR_Y cd, cs1
    .insn r STD_AMO_OPC, 4, 0x08, \cd, \cs1, x0
.endm
.macro AMOSWAP_Y cd, cs1, cs2
    .insn r STD_AMO_OPC, 4, 0x04, \cd, \cs1, \cs2
.endm
.macro SC_Y rd, cs1, cs2
    .insn r STD_AMO_OPC, 4, 0x0c, \rd, \cs1, \cs2
.endm

.macro SRLIY rd, cs1, shamt
    .error "SRLIY does not exist in the 0.9.3 standard"
.endm

#endif /* CHERI_093 */

/* Cache-block operations: standard Zicbom/Zicboz opcode and funct12s, but
 * under RVY cs1 authorizes the access as a capability. */
.macro CBO_INVAL cs1
    .insn i CBO_OPC, 2, x0, \cs1, 0
.endm
.macro CBO_CLEAN cs1
    .insn i CBO_OPC, 2, x0, \cs1, 1
.endm
.macro CBO_FLUSH cs1
    .insn i CBO_OPC, 2, x0, \cs1, 2
.endm
.macro CBO_ZERO cs1
    .insn i CBO_OPC, 2, x0, \cs1, 4
.endm


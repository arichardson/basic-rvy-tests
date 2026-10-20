/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Capability execution-mode and permission manipulation instructions:
 *
 *  - YMODEW sets the execution mode of an unsealed executable capability to
 *    CHERI_MODE_INT (1) or CHERI_MODE_CAP (0) when cd != x0.
 *  - Dropping PERM_X via YPERMC / ACPERM on an integer-mode capability forces
 *    its execution mode back to CHERI_MODE_CAP (0) and clears dependent
 *    PERM_ASR.
 *  - Dropping PERM_C or PERM_R legalizes dependent capability permissions
 *    (PERM_LM, PERM_ASR on RV32, and PERM_C on RV32), and on RV64 loading a
 *    C+W capability without PERM_LM clears PERM_W and transitively legalizes
 *    PERM_C to 0.
 */
#define TEST_NAME "cap-perms"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    csrrs s0, CSR_DDC, x0
    lla   t1, buf
    YADDRW a0, s0, t1
    li    t2, 4096
    YBNDSW a0, a0, t2            /* a0 = [buf, buf + 4096) */

    /* YMODEW sets the execution mode of an unsealed executable capability when cd != x0. */
    NEXT_TEST "ymodew sets CHERI_MODE_INT on an executable capability"
    li   t2, CHERI_MODE_INT
    YMODEW a1, s0, t2
    EXPECT_TAG a1, 1
    YMODER t3, a1
    EXPECT_EQ t3, t2
    EXPECT_NO_TRAP

    NEXT_TEST "ymodew sets CHERI_MODE_CAP on an executable capability"
    YMODESWY
    YMODEW a1, a1, x0
    YMODESWI
    EXPECT_TAG a1, 1
    YMODER t3, a1
    EXPECT_ZERO t3
    EXPECT_NO_TRAP

    YMODESWY

    /*
     * Dropping PERM_X on an executable capability whose mode bit is
     * CHERI_MODE_INT (1) forces the mode bit to CHERI_MODE_CAP (0), because
     * non-executable capabilities cannot encode integer execution mode, and
     * also clears dependent PERM_ASR.
     */
    NEXT_TEST "dropping PERM_X clears PERM_ASR and forces capability mode"
    auipc a2, 0
    li   t1, CHERI_MODE_INT
    YMODEW a2, a2, t1
    EXPECT_TAG a2, 1
    YMODER t3, a2
    EXPECT_EQ t3, t1
    li   t2, DROP_MASK(PERM_X)
    DROP_PERMS a2, a2, t2
    EXPECT_TAG a2, 1
    YMODER t3, a2
    EXPECT_ZERO t3               /* forced back to CHERI_MODE_CAP (0) */
    YPERMR t3, a2
    li   t4, PERM_X | PERM_ASR
    and  t3, t3, t4
    EXPECT_ZERO t3
    EXPECT_NO_TRAP

    /*
     * Permission dependency legalization:
     *  - Dropping PERM_C clears dependent PERM_LM while keeping PERM_R,
     *    PERM_W, PERM_X, and mode; PERM_ASR is kept on RV64 (rule base-1: ASR
     *    requires X) and cleared on RV32 (rule RV32-base-7: ASR requires W,
     *    C, and X).
     *  - Dropping PERM_R (along with PERM_X) clears PERM_LM while keeping
     *    PERM_C and PERM_W on RV64 (rule base-2: C requires R or W), whereas
     *    on RV32 rule RV32-base-1 (C requires R) also clears PERM_C.
     *  - On RV64, loading that C+W capability through an authority without
     *    PERM_LM clears PERM_W and transitively legalizes PERM_C to 0.
     */
    NEXT_TEST "dropping PERM_C clears PERM_LM while keeping PERM_R, PERM_W, PERM_X, and mode"
    auipc a2, 0
    li   t1, CHERI_MODE_INT
    YMODEW a2, a2, t1
    li   t2, DROP_MASK(PERM_C)
    DROP_PERMS a3, a2, t2
    EXPECT_TAG a3, 1
    YPERMR t3, a3
#if __riscv_xlen == 64
    li   t4, PERM_C | PERM_LM
    and  t4, t3, t4
    EXPECT_ZERO t4
    li   t4, PERM_R | PERM_W | PERM_X | PERM_ASR
    and  t3, t3, t4
    EXPECT_EQ t4, t3
#else
    li   t4, PERM_C | PERM_LM | PERM_ASR
    and  t4, t3, t4
    EXPECT_ZERO t4
    li   t4, PERM_R | PERM_W | PERM_X
    and  t3, t3, t4
    EXPECT_EQ t4, t3
#endif
    YMODER t3, a3
    EXPECT_EQ t3, t1             /* PERM_X kept, so CHERI_MODE_INT survives */
    EXPECT_NO_TRAP

    NEXT_TEST "dropping PERM_R clears PERM_LM and legalizes PERM_C"
    li   t2, DROP_MASK(PERM_R | PERM_X)
    DROP_PERMS a3, a0, t2
    EXPECT_TAG a3, 1
    YPERMR t3, a3
#if __riscv_xlen == 64
    li   t4, PERM_R | PERM_LM
    and  t4, t3, t4
    EXPECT_ZERO t4
    li   t4, PERM_C | PERM_W
    and  t3, t3, t4
    EXPECT_EQ t4, t3
    EXPECT_NO_TRAP

    NEXT_TEST "loading a C+W capability without PERM_LM clears PERM_W and legalizes PERM_C to 0"
    SY   a3, 0(a0)
    li   t2, DROP_MASK(PERM_LM)
    DROP_PERMS a4, a0, t2        /* authority without LM */
    LY   a5, 0(a4)
    EXPECT_TAG a5, 1
    YPERMR t3, a5
    li   t4, PERM_C | PERM_W | PERM_R | PERM_X | PERM_LM | PERM_ASR
    and  t3, t3, t4
    EXPECT_ZERO t3               /* W cleared by missing LM -> C legalized to 0 */
    EXPECT_NO_TRAP
#else
    li   t4, PERM_R | PERM_C | PERM_LM
    and  t4, t3, t4
    EXPECT_ZERO t4
    li   t4, PERM_W
    and  t3, t3, t4
    EXPECT_EQ t4, t3
    EXPECT_NO_TRAP
#endif

    YMODESWI
    TEST_PASS
fail:
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 4096
buf:
    .space 4096

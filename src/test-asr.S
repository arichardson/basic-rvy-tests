/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Operations gated on the Access_System_Registers permission in PCC. RVY
 * reports a missing ASR as an illegal instruction where 0.9.3 raises a
 * capability exception, so TRAP_ASR_DENIED stands for whichever applies.
 *
 * ASR covers CSRs whose number has a non-zero privilege field, so mtvec and
 * mscratch need it while ddc does not, and that distinction is checked here
 * too: dropping ASR must not make every CSR inaccessible.
 *
 * CBO.INVAL is the other ASR-gated operation. The PCC ASR check outranks the
 * capability checks on the authorizing capability, so a missing ASR is
 * reported even for an untagged capability.
 */
#define TEST_NAME "asr"
#include "testmacros.h"
#include "exceptions.h"

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    YMODESWY                     /* capability mode: jalr takes a capability */

    /* The M-mode root PCC grants ASR, so these all work to begin with. */
    NEXT_TEST "root pcc grants ASR so cbo.inval reports the capability fault"
    csrr t0, CSR_MTVEC
    mv   a1, x0                  /* NULL capability in a non-x0 register */
    CBO_INVAL a1                 /* untagged cap, but ASR is checked first ... */
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)  /* ... so this is the capability fault */

    /* Build a PCC-derived capability with ASR removed and call into it. */
    NEXT_TEST "a pcc without ASR still runs, and consumes its own traps"
    auipc a0, 0
    lla   t0, asr_stub
    YADDRW a0, a0, t0
    li   t1, DROP_MASK(PERM_ASR)
    DROP_PERMS a0, a0, t1
    YPERMR t2, a0
    li   t1, PERM_ASR            /* DROP_MASK may have been complemented */
    and  t2, t2, t1
    EXPECT_ZERO t2               /* ASR really is gone */
    jalr ra, a0, 0
    EXPECT_NO_TRAP               /* the stub consumed all of its own traps */

    /* Back on the root PCC, ASR-gated CSRs work again. */
    NEXT_TEST "back on the root pcc the ASR-gated CSRs work again"
    csrr t0, CSR_MTVEC
    EXPECT_NO_TRAP

    YMODESWI
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

/*
 * Entered with a PCC that grants everything except ASR. Stores still work,
 * so reaching fail from here is fine.
 */
.balign 8
asr_stub:
    /* Reading an M-mode CSR needs ASR */
    NEXT_TEST "reading an M-mode CSR needs ASR"
    csrr t0, CSR_MTVEC
    EXPECT_TRAP TRAP_ASR_DENIED

    /* So does writing one (mscratch is scratch, so a stray write is safe) */
    NEXT_TEST "writing an M-mode CSR needs ASR"
    csrw CSR_MSCRATCH, x0
    EXPECT_TRAP TRAP_ASR_DENIED

    /*
     * CBO.INVAL is ASR-gated, and the PCC ASR check outranks the capability
     * checks on the authorizing capability.
     */
    NEXT_TEST "cbo.inval without ASR faults before the capability check"
    mv   a1, x0
    CBO_INVAL a1
    EXPECT_TRAP TRAP_ASR_DENIED

    /* ddc has no privilege bits in its CSR number, so it needs no ASR */
    NEXT_TEST "ddc has no privilege bits in its number so needs no ASR"
    csrrs t0, CSR_DDC, x0
    EXPECT_NO_TRAP

    ret

TRAP_HANDLER

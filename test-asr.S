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
 * CBO.INVAL is the other ASR-gated operation. Under RVY a missing ASR is an
 * illegal instruction, which outranks the capability checks, so it is
 * reported even for the NULL capability; 0.9.3 instead treats ASR as one more
 * permission on the authorizing capability and reports the tag violation.
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
    NEXT_TEST
    csrr t0, CSR_MTVEC
    CBO_INVAL x0                 /* NULL cap, but ASR is checked first ... */
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)  /* ... so this is the capability fault */

    /* Build a PCC-derived capability with ASR removed and call into it. */
    NEXT_TEST
    auipc a0, 0
    la   t0, asr_stub
    YADDRW a0, a0, t0
    li   t1, DROP_MASK(PERM_ASR)
    DROP_PERMS a0, a0, t1
    YPERMR t2, a0
    li   t1, PERM_ASR            /* DROP_MASK may have been complemented */
    and  t2, t2, t1
    bnez t2, fail                /* ASR really is gone */
    jalr ra, a0, 0
    EXPECT_NO_TRAP               /* the stub consumed all of its own traps */

    /* Back on the root PCC, ASR-gated CSRs work again. */
    NEXT_TEST
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
    NEXT_TEST
    csrr t0, CSR_MTVEC
    EXPECT_TRAP TRAP_ASR_DENIED

    /* So does writing one (mscratch is scratch, so a stray write is safe) */
    NEXT_TEST
    csrw CSR_MSCRATCH, x0
    EXPECT_TRAP TRAP_ASR_DENIED

    /*
     * CBO.INVAL is ASR-gated, but the two versions order that against the
     * capability checks differently: RVY reports a missing ASR as an illegal
     * instruction, which outranks them, while 0.9.3 makes ASR one more
     * permission and so reaches the tag check first.
     */
    NEXT_TEST
    CBO_INVAL x0
#ifdef CHERI_093
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
#else
    EXPECT_TRAP TRAP_ASR_DENIED
#endif

    /* ddc has no privilege bits in its CSR number, so it needs no ASR */
    NEXT_TEST
    csrrs t0, CSR_DDC, x0
    EXPECT_NO_TRAP

    ret

TRAP_HANDLER

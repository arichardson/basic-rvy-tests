/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Verify the RVY exception causes, fault addresses (mtval), and permission and
 * bounds checks for capability atomics (LR.Y, SC.Y, AMOSWAP.Y) and integer
 * atomics (SC.W, AMOSWAP.W) in capability mode, ensuring that faulting
 * operations leave cd/rd holding its prior poison capability and memory
 * unmodified:
 *
 *  - In capability mode with the NULL capability, an untagged capability, a
 *    sealed sentry, or an out-of-bounds capability, the check fails with
 *    CAP_TAG, CAP_SEAL, or CAP_BOUNDS respectively; the reported cause must
 *    be selected by the access type: LR.Y -> CHERI Load Access Fault (33);
 *    SC.Y, AMOSWAP.Y, and integer AMOs (sc.w, amoswap.w) -> CHERI Store/AMO
 *    Access Fault (34), with mtval holding the faulting virtual address in
 *    v0.9.9.
 *  - Read-only capabilities (W=0) reject SC.W, SC.Y, and AMOSWAP.Y with a
 *    store permission fault without modifying cd or memory; write-only
 *    capabilities (R=0, W=1) permit SC.W and SC.Y while rejecting LR.Y with a
 *    load permission fault and AMOSWAP.Y with a store/AMO permission fault.
 */
#define TEST_NAME "amo-cbo-causes"
#include "testmacros.h"
#include "exceptions.h"

.macro CHECK_BUF base_reg
    LY   t0, 0(\base_reg)
    EXPECT_CAP_EQ t0, a3
    LY   t0, YLEN_BYTES(\base_reg)
    EXPECT_CAP_EQ t0, s7
    SY   a3, 0(\base_reg)
    SY   s7, YLEN_BYTES(\base_reg)
.endm

.option norvc
.section .text
.globl _start
_start:
    SETUP_TRAPS

    lla   a0, buf                 /* aligned to 64 bytes */

    /* Derive test capabilities covering buf and seed buf with tagged capabilities. */
    csrrs s0, CSR_DDC, x0
    YADDRW a2, x0, a0            /* a2: untagged capability at buf */
    YADDRW a3, s0, a0            /* a3: full-permission capability at buf */
    li   t2, DROP_MASK(PERM_W)
    DROP_PERMS a4, a3, t2        /* a4: read-only capability (W=0, R=1, C=1) */
    li   t2, DROP_MASK(PERM_R)
    DROP_PERMS a7, a3, t2        /* a7: write-only capability (W=1, R=0; C=1 on RV64, C=0 on RV32) */
    YSEALE s1, a3                /* s1: sealed sentry capability at buf */
    li   t2, YLEN_BYTES
    YBNDSW s2, a3, t2            /* [buf, buf + YLEN_BYTES) */
    YADDI  s2, s2, YLEN_BYTES    /* s2: cursor at top (out of bounds) */
    YADDI  s7, a3, YLEN_BYTES    /* s7: full-permission capability at buf + YLEN_BYTES */
    SY   a3, 0(a0)
    SY   s7, YLEN_BYTES(a0)
    li   t0, 0xdeadbeef
    YADDRW t2, s0, t0            /* t2: distinct tagged store capability */

    YMODESWY

    /* LR.Y via NULL cap: load-classified tag fault */
    NEXT_TEST "lr.y through the NULL capability is load classified"
    POISON_REG t1
    mv   t0, x0
    LR_Y t1, t0
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    CHECK_POISON_REG t1

    /* SC.Y via NULL cap: store-classified tag fault */
    NEXT_TEST "sc.y through the NULL capability is store classified"
    POISON_REG t1
    mv   t0, x0
    SC_Y t1, t0, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_POISON_REG t1

    /* AMOSWAP.Y via NULL cap */
    NEXT_TEST "amoswap.y through the NULL capability is store classified"
    POISON_REG t1
    mv   t0, x0
    AMOSWAP_Y t1, t0, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_POISON_REG t1

    /* Integer SC.W and AMO via NULL cap: store-classified */
    NEXT_TEST "sc.w through the NULL capability is store classified"
    POISON_REG t1
    mv   t0, x0
    sc.w t1, x0, (t0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_POISON_REG t1

    NEXT_TEST "an integer amo through the NULL capability is store classified"
    POISON_REG t1
    mv   t0, x0
    amoswap.w t1, t2, (t0)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    CHECK_POISON_REG t1

    /*
     * LR.Y, SC.Y, and AMOSWAP.Y through an untagged capability at a non-zero
     * address must report that address in mtval (not 0) on v0.9.9.
     */
    NEXT_TEST "lr.y through an untagged capability reports the fault address in mtval"
    POISON_REG t1
    LR_Y t1, a2
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_TAG)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1

    NEXT_TEST "sc.y through an untagged capability reports the fault address in mtval"
    POISON_REG t1
    SC_Y t1, a2, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "amoswap.y through an untagged capability reports the fault address in mtval"
    POISON_REG t1
    AMOSWAP_Y t1, a2, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_TAG)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    /*
     * Sealed sentry capability (s1): LR.Y reports a load CAP_SEAL fault;
     * SC.Y, AMOSWAP.Y, and integer AMOs report a store CAP_SEAL fault.
     */
    NEXT_TEST "lr.y through a sealed sentry faults with load CAP_SEAL"
    POISON_REG t1
    LR_Y t1, s1
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_SEAL)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1

    NEXT_TEST "sc.y through a sealed sentry faults with store CAP_SEAL"
    POISON_REG t1
    SC_Y t1, s1, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "amoswap.y through a sealed sentry faults with store CAP_SEAL"
    POISON_REG t1
    AMOSWAP_Y t1, s1, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "sc.w through a sealed sentry faults with store CAP_SEAL"
    POISON_REG t1
    sc.w t1, t2, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "amoswap.w through a sealed sentry faults with store CAP_SEAL"
    POISON_REG t1
    amoswap.w t1, t2, (s1)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_SEAL)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    /*
     * Out-of-bounds capability (s2 at buf + YLEN_BYTES): LR.Y reports load
     * CAP_BOUNDS; SC.Y, AMOSWAP.Y, and integer SC.W report store CAP_BOUNDS.
     */
    NEXT_TEST "lr.y at capability top faults with load CAP_BOUNDS"
    POISON_REG t1
    LR_Y t1, s2
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_BOUNDS)
    EXPECT_TVAL s7
    CHECK_POISON_REG t1

    NEXT_TEST "sc.y at capability top faults with store CAP_BOUNDS"
    POISON_REG t1
    SC_Y t1, s2, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s7
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "amoswap.y at capability top faults with store CAP_BOUNDS"
    POISON_REG t1
    AMOSWAP_Y t1, s2, t2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s7
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "sc.w at capability top faults with store CAP_BOUNDS"
    POISON_REG t1
    sc.w t1, t2, (s2)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_BOUNDS)
    EXPECT_TVAL s7
    CHECK_POISON_REG t1
    CHECK_BUF a3

    /*
     * Read-only capability (a4, W=0): SC.W, SC.Y, and AMOSWAP.Y must fault
     * with a store capability permission fault even when storing x0 or an
     * untagged capability, leaving cd and memory unmodified. Control:
     * granting W (via a3) permits AMOSWAP.Y when storing x0.
     */
    NEXT_TEST "sc.w through a read-only capability faults with store CAP_PERM"
    lr.w t1, (a4)
    POISON_REG t1
    sc.w t1, t2, (a4)
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "sc.y through a read-only capability faults with store CAP_PERM"
    LR_Y t1, a4
    POISON_REG t1
    SC_Y t1, a4, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "amoswap.y of x0 through a read-only capability faults without side effects"
    POISON_REG t1
    AMOSWAP_Y t1, a4, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1          /* cd (t1) must keep poison capability */
    CHECK_BUF a3                 /* memory must keep a3 */

    NEXT_TEST "amoswap.y of an untagged capability through a read-only capability faults"
    POISON_REG t1
    AMOSWAP_Y t1, a4, a2
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    NEXT_TEST "control: amoswap.y of x0 succeeds when W is granted"
    YMV  t1, x0
    AMOSWAP_Y t1, a3, x0
    EXPECT_NO_TRAP
    EXPECT_TAG t1, 1             /* loaded the tagged capability from memory */
    LY   t2, 0(a3)
    EXPECT_TAG t2, 0             /* stored x0 to memory */

    /*
     * Write-only capability (a7, R=0, W=1):
     *  - LR.Y faults with load CAP_PERM.
     *  - SC.W and SC.Y succeed when paired with a prior LR at the same
     *    address because SC only requires W (and C to retain the tag).
     *  - AMOSWAP.Y requires both R and W and faults with store/AMO CAP_PERM.
     */
    NEXT_TEST "lr.y through a write-only capability faults with load CAP_PERM"
    SY   a3, 0(a3)
    POISON_REG t1
    LR_Y t1, a7
    EXPECT_TRAP TRAP_CAP_LOAD(CAP_PERM)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1

    NEXT_TEST "sc.w through a write-only capability succeeds after a valid lr.w"
    lr.w t1, (a3)
    li   t0, 0x33cc33cc
    sc.w t2, t0, (a7)
    EXPECT_NO_TRAP
    EXPECT_ZERO t2

    NEXT_TEST "sc.y through a write-only capability succeeds after a valid lr.y"
    SY   x0, 0(a3)
    LR_Y t1, a3
    SC_Y t2, a7, a3
    EXPECT_NO_TRAP
    EXPECT_ZERO t2
    LY   t3, 0(a3)
#if __riscv_xlen == 64
    EXPECT_TAG t3, 1
#else
    /* 64-bit compressed capabilities cannot encode C without R, so a7 lacks C and strips the tag */
    EXPECT_TAG t3, 0
#endif

    NEXT_TEST "amoswap.y through a write-only capability faults with store/AMO CAP_PERM"
    SY   a3, 0(a3)
    POISON_REG t1
    AMOSWAP_Y t1, a7, x0
    EXPECT_TRAP TRAP_CAP_STORE(CAP_PERM)
    EXPECT_TVAL a0
    CHECK_POISON_REG t1
    CHECK_BUF a3

    YMODESWI                     /* back to int mode */
    TEST_PASS
fail:
    /* Leave capability mode first so the finisher store cannot fault. */
    YMODESWI
    TEST_FAIL

TRAP_HANDLER

.section .bss
.balign 64
buf:
    .space 128

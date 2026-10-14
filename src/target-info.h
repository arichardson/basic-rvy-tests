/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Target implementation identity and feature flags, instantiated from
 * target-info.c.in into a small ELF per emulator (linked with target-info.ld
 * at TARGET_INFO_ADDR) and copied by console_init into the test's local
 * target_info struct if present.
 */
#pragma once

#define TARGET_INFO_ADDR  0x80100000
#define TARGET_INFO_MAGIC 0x54595652 /* "RVYT" */
#define TARGET_INFO_SIZE  (8 + 2 * (__riscv_xlen / 8))

#define TARGET_IMPL_UNKNOWN 0
#define TARGET_IMPL_QEMU    1
#define TARGET_IMPL_SAIL    2

/* Byte offsets into struct target_info for assembly tests. */
#define TARGET_INFO_OFF_MAGIC                      0
#define TARGET_INFO_OFF_IMPL_ID                    4
#define TARGET_INFO_OFF_UART_ADDR                  8
#define TARGET_INFO_OFF_HAS_HTIF                   (8 + (__riscv_xlen / 8))
#define TARGET_INFO_OFF_SVYRG_TRAPS_CONSERVATIVELY (9 + (__riscv_xlen / 8))

#ifdef __ASSEMBLER__

.macro LOAD_TARGET_IMPL_ID reg
    la   \reg, target_info
    lw   \reg, TARGET_INFO_OFF_IMPL_ID(\reg)
.endm

.macro LOAD_TARGET_FLAG reg, offset
    la   \reg, target_info
    lbu  \reg, \offset(\reg)
.endm

#else

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * All-zeroes is the fallback when the second ELF is not loaded, so zero (or
 * false) in every field after magic must select the default spec-compliant
 * behaviour (and for uart_addr / has_htif, tells console_init to probe the
 * UART and try both outputs).
 */
struct target_info {
    uint32_t magic;
    uint32_t impl_id;
    unsigned long uart_addr;
    bool has_htif;
    bool svyrg_traps_conservatively;
};

_Static_assert(sizeof(struct target_info) ==
               TARGET_INFO_SIZE, "size mismatch");
_Static_assert(offsetof(struct target_info, magic) ==
               TARGET_INFO_OFF_MAGIC, "offset mismatch");
_Static_assert(offsetof(struct target_info, impl_id) ==
               TARGET_INFO_OFF_IMPL_ID, "offset mismatch");
_Static_assert(offsetof(struct target_info, uart_addr) ==
               TARGET_INFO_OFF_UART_ADDR, "offset mismatch");
_Static_assert(offsetof(struct target_info, has_htif) ==
               TARGET_INFO_OFF_HAS_HTIF, "offset mismatch");
_Static_assert(offsetof(struct target_info, svyrg_traps_conservatively) ==
               TARGET_INFO_OFF_SVYRG_TRAPS_CONSERVATIVELY,
               "offset mismatch");

#endif

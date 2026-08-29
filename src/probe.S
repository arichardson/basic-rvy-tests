/* SPDX-License-Identifier: BSD-2-Clause
 *
 * Minimal RISC-V assembly used at configure time to check whether a
 * candidate clang binary was built with the RISC-V backend (see
 * meson.build in this directory). Deliberately plain RV64G, not RVY: this
 * only needs to prove the compiler can target riscv64 at all.
 */
.text
.globl _start
_start:
    li a0, 0

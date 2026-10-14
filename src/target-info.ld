/* SPDX-License-Identifier: BSD-2-Clause */
ENTRY(target_info)
PHDRS
{
    rodata PT_LOAD FLAGS(4);
}
SECTIONS
{
    /* Must match TARGET_INFO_ADDR in target-info.h. */
    . = 0x80100000;
    .rodata : { KEEP(*(.rodata*)) } :rodata
    /DISCARD/ : { *(.text*) *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}

ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) }
    /*
     * HTIF is located by symbol name, so the address does not matter, but it
     * must not share a page with anything else. QEMU turns the page holding
     * tohost into a device, and data placed there stops behaving like memory:
     * it carries no tags, and capability stores to it are not preserved.
     */
    .tohost ALIGN(0x1000) : { *(.tohost) }
}

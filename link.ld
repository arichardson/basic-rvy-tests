ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    /* HTIF: located by symbol name, so the address does not matter. */
    .tohost ALIGN(0x1000) : { *(.tohost) }
    .bss : { *(.bss*) }
}

ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    /*
     * One pointer per NEXT_TEST, in source order, so the TAP stream can name
     * each case. See NEXT_TEST in testmacros.h.
     */
    .tapnames : {
        __tapnames_start = .;
        KEEP(*(.tapnames))
        __tapnames_end = .;
    }
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

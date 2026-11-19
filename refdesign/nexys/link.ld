/* SPDX-License-Identifier: GPL-2.0-only */
ENTRY(_start)
MEMORY { bram (rwx) : ORIGIN = 0, LENGTH = 64K }
__stack_top = ORIGIN(bram) + LENGTH(bram) - 16;
SECTIONS {
    .vectors 0 : { KEEP(*(.vectors)) } > bram
    .text 0x100 : { *(.text*) *(.rodata*) *(.sdata2*) } > bram
    .data : { *(.data*) *(.sdata*) } > bram
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss*) *(.sbss*) *(.sbss2*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > bram
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(__bss_end <= __stack_top - 4096, "BRAM image leaves less than 4 KiB for stack")

ENTRY(_start)
MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 128K
    DMEM (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}
SECTIONS
{
    .text : { . = ALIGN(4); KEEP(*(.text.init)) *(.text) *(.text.*) } > IMEM
    .mailbox (NOLOAD) : { . = ALIGN(4); . = . + 0x1000; } > DMEM
    .rodata : { . = ALIGN(4); *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) . = ALIGN(4); } > DMEM
    .data : { . = ALIGN(4); __data_start = .; *(.sdata) *(.sdata.*) *(.data) *(.data.*) . = ALIGN(4); __data_end = .; } > DMEM
    .bss (NOLOAD) : { . = ALIGN(16); __bss_start = .; *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON) . = ALIGN(16); __bss_end = .; } > DMEM
    PROVIDE(__global_pointer$ = __data_start + 0x800);
    PROVIDE(_stack_top = ORIGIN(DMEM) + LENGTH(DMEM));
    /DISCARD/ : { *(.comment) *(.note*) *(.gnu*) *(.riscv.attributes) *(.eh_frame) *(.eh_frame.*) *(.init_array*) *(.fini_array*) }
}

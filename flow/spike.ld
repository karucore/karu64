/*	spike.ld -- minimal linker script for spike/HTIF rv64 binaries. */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
	. = 0x80000000;

	.text.init : { *(.text.init) }
	.text      : { *(.text) *(.text.*) }

	.rodata : {
		*(.rodata) *(.rodata.*)
		*(.srodata) *(.srodata.*)
	}

	. = ALIGN(8);
	.data : {
		*(.data) *(.data.*)
		*(.sdata) *(.sdata.*)
	}

	. = ALIGN(8);
	_bss_start = .;
	.bss : {
		*(.bss) *(.bss.*)
		*(.sbss) *(.sbss.*)
		*(COMMON)
		. = ALIGN(8);
	}
	_bss_end = .;

	/*	Pin .tohost to a fixed VMA so the HTIF testbench knows where
		to watch. Spike also accepts this (it locates the symbols by
		name from the ELF). */
	. = 0x80001000;
	.tohost : { *(.tohost) }

	. = ALIGN(16);
	. += 0x4000;
	_stack_top = .;
}

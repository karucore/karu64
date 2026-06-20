/* coremark.ld -- roomy HTIF layout for CoreMark firmware. */

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

	. = 0x80040000;
	.tohost : { *(.tohost) }

	. = ALIGN(16);
	. += 0x8000;
	_stack_top = .;
}

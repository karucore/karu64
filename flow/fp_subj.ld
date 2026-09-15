/*	fp_subj.ld -- linker script for the TestFloat subject firmware.
	Same layout as spike.ld but with .tohost pushed to 0x80008000 so
	the larger fp_subj firmware fits. Input vector region begins at
	0x80010000 and output region at 0x80100000 (see test/fw/fp_subj.c). */

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

	. = 0x80008000;
	.tohost : { *(.tohost) }

	. = ALIGN(16);
	. += 0x4000;
	_stack_top = .;

	/* Optional test-only page tables. Empty for ordinary subject firmware;
	   NOLOAD storage is initialized explicitly by its owning test. */
	.pbmt_tables ALIGN(4096) (NOLOAD) : { *(.pbmt_tables) }
	ASSERT(SIZEOF(.pbmt_tables) == 0 ||
	       ADDR(.pbmt_tables) + SIZEOF(.pbmt_tables) <= 0x80200000,
	       "PBMT tables exceed the test's first-2-MiB identity mapping")
}

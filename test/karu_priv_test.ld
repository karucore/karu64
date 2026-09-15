/* Shared privilege-test layout: RESET_PC at 0x80000000, HTIF at 0x80001000. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
	. = 0x80000000;
	.text : { *(.text.boot) *(.text*) }
	. = 0x80001000;
	.htif : { *(.htif) }
	/DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

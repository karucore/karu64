/* karu_supm_test.ld -- flat image at 0x80000000 (htif_tb RESET_PC). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
	. = 0x80000000;
	.text : { *(.text.boot) *(.text*) }
	. = 0x80001000;
	.htif : { *(.htif) }
	/DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

/*	karu_vmmu_test.ld -- flat image based at 0x8000_0000 (= htif_tb RESET_PC).
	Sv39 tables and the vector data frames are pinned to fixed 4 KiB-aligned
	addresses so the PTE constants in karu_vmmu_test.S resolve correctly.
	F0 and F1 are deliberately NON-ADJACENT physically (0x8000_5000 and
	0x8000_7000) while their VAs are adjacent (0x4000/0x5000) -- a vector
	access crossing that VA page boundary only lands right if the V2 2-page
	preflight composes two distinct physical pages. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
	. = 0x80000000;
	.text   : { *(.text.boot) *(.text*) }

	. = 0x80002000;	.root : { *(.root) }
	. = 0x80003000;	.l1   : { *(.l1) }
	. = 0x80004000;	.l0   : { *(.l0) }
	. = 0x80005000;	.f0   : { *(.f0) }
	. = 0x80007000;	.f1   : { *(.f1) }
	. = 0x80008000;	.f2   : { *(.f2) }
	. = 0x80009000;	.ucode : { *(.ucode) }

	/DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

/*	karu_xpage_test.ld -- flat image based at 0x8000_0000 (= htif_tb RESET_PC).
	Sv39 tables and the data frames are pinned to fixed 4 KiB-aligned addresses
	so the PTE constants in karu_xpage_test.S resolve correctly.

	The two mapped frames are deliberately NON-ADJACENT physically while their
	VAs are adjacent:
	    VA_LO = 0x4000 -> F_LO = 0x8000_5000   (beat-1 frame)
	    VA_HI = 0x5000 -> F_HI = 0x8000_7000   (beat-2 SHOULD land here)
	with F_ADJ = 0x8000_6000 = F_LO+1 left unmapped from the low-VA test
	alias -- that is the frame a misaligned cross-page split wrongly hits when
	beat-2 is computed as (PA & ~7) + 8 instead of translate(VA + page). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
	. = 0x80000000;
	.text   : { *(.text.boot) *(.text*) }

	. = 0x80002000;	.root : { *(.root) }
	. = 0x80003000;	.l1   : { *(.l1) }
	. = 0x80004000;	.l0   : { *(.l0) }
	. = 0x80005000;	.flo  : { *(.flo) }
	. = 0x80006000;	.fadj : { *(.fadj) }
	. = 0x80007000;	.fhi  : { *(.fhi) }

	/DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

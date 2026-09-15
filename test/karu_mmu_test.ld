/*	karu_mmu_test.ld -- flat image based at 0x8000_0000 (= htif_tb RESET_PC).
	Each Sv39 table and test frame is pinned to a fixed 4 KiB-aligned address
	so the PTE constants in karu_mmu_test.S resolve correctly. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
	. = 0x80000000;
	.text   : { *(.text.boot) }
	ASSERT(SIZEOF(.text) <= 0x1000, "MMU test code overlaps HTIF/diagnostic page")

	. = 0x80002000;	.rootA  : { *(.rootA) }
	. = 0x80003000;	.rootB  : { *(.rootB) }
	. = 0x80004000;	.l1a    : { *(.l1a) }
	. = 0x80005000;	.l0a    : { *(.l0a) }
	. = 0x80006000;	.l1b    : { *(.l1b) }
	. = 0x80007000;	.l0b    : { *(.l0b) }
	. = 0x80008000;	.frameA : { *(.frameA) }
	. = 0x80009000;	.frameB : { *(.frameB) }
	. = 0x8000A000;	.frameW : { *(.frameW) }
	. = 0x8000B000;	.svade  : { *(.text.svade) }
	ASSERT(SIZEOF(.svade) <= 0x5000, "MMU test code overlaps Svnapot runtime frames")

	/* The 64 KiB NAPOT fixture occupies 0x80010000..0x8001ffff at run time. */
	. = 0x80020000;	.pbmt   : { *(.text.pbmt) }
	ASSERT(SIZEOF(.pbmt) <= 0x10000, "MMU Svpbmt test exceeds its code region")

	/DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

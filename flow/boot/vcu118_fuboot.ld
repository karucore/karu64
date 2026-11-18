/* vcu118_fuboot.ld -- VCU118 DDR monitor in boot ROM.

   0x0000_1000..0x0000_ffff  fu-boot code region (60 KiB) -- the start of the 2 MiB
                             boot ROM. 0x1_0000..0x2_3fff is kept empty for the debug
                             authentication island, which is decoded in front of the
                             ROM. The baked OpenSBI/U-Boot/DTB payloads follow from
                             ROM offset 0x3_0000 (core 0x3_1000).
   0x0020_1000..0x0021_0fff  boot scratch SRAM, directly above the ROM
   0x8000_0000..             DDR payload area */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	ROM  (rx)  : ORIGIN = 0x00001000, LENGTH = 0x0000f000
	SRAM (rwx) : ORIGIN = 0x00201000, LENGTH = 0x00010000
}

SECTIONS
{
	.text.init : { *(.text.init) } > ROM
	.text      : { *(.text) *(.text.*) } > ROM
	.rodata    : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > ROM

	. = ALIGN(8);
	_data_start = ORIGIN(SRAM);
	.data _data_start : {
		*(.data) *(.data.*) *(.sdata) *(.sdata.*)
		. = ALIGN(8);
	} > SRAM AT> ROM
	_data_end = .;
	__data_load_start = LOADADDR(.data);

	. = ALIGN(8);
	_bss_start = .;
	.bss : {
		*(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON)
		. = ALIGN(8);
	} > SRAM
	_bss_end = .;

	_stack_top = ORIGIN(SRAM) + LENGTH(SRAM);

	ASSERT(__data_load_start + SIZEOF(.data) <= ORIGIN(ROM) + LENGTH(ROM),
		"vcu118 fu-boot ROM image exceeds boot ROM")
}

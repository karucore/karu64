OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init    : { *(.text.init) }
  .text.rvtest  : { *(.text.rvtest) *(.text.rvtest.*) }
  . = ALIGN(0x4000);
  .data         : { *(.data) }
  /* Place .tohost explicitly (rather than as an orphan) so the HTIF dword
     lands at a known low address inside the testbench RAM window and the
     objcopy -O binary image stays compact. The runner finds it via nm. */
  . = ALIGN(0x40);
  .tohost       : { *(.tohost) }
  . = ALIGN(0x1000);
  .text.rvmodel : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) }
  . = ALIGN(0x1000);
  _end = .;
}

/* Simulation island ROM (doc/debug-auth-contract.md 8): code in island ROM,
   stack and data in island SRAM. SPDX-License-Identifier: BSD-2-Clause */
MEMORY {
  ROM  (rx)  : ORIGIN = 0x00010000, LENGTH = 64K
  SRAM (rw)  : ORIGIN = 0x00020000, LENGTH = 16K
}
SECTIONS {
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) } > ROM
  .bss (NOLOAD) : { *(.bss*) *(.sbss*) *(COMMON) } > SRAM
  /DISCARD/ : { *(.data*) *(.sdata*) *(.comment) *(.eh_frame*) }
  __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
  __sram_start = ORIGIN(SRAM);
}

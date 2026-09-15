/* SPDX-License-Identifier: BSD-3-Clause */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
    . = 0x80000000;
    .text : { *(.text .text.*) }
    ASSERT(. <= 0x80001000, "Sail interrupt probe overlaps HTIF page")
    . = 0x80001000;
    .tohost : { *(.tohost) }
    /DISCARD/ : { *(.comment .riscv.attributes) }
}

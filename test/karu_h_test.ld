/* H monitor: HTIF, host fixtures and optional two-stage guest fixtures have
 * separate addresses; the optional G root is naturally 16 KiB-aligned. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
PHDRS
{
    boot PT_LOAD FLAGS(5);
    htif PT_LOAD FLAGS(6);
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
    guest PT_LOAD FLAGS(5);
}
SECTIONS
{
    . = 0x80000000;
    .boot : { *(.text.boot) } :boot
    ASSERT(SIZEOF(.boot) <= 0x1000, "H monitor boot overlaps HTIF")
    . = 0x80001000;
    .htif : { *(.htif) } :htif
    . = 0x80002000;
    .text : { *(.text) *(.text.*) } :text
    ASSERT(. <= 0x80010000, "H monitor overlaps host page tables")
    . = 0x80010000; .root : { *(.root) } :data
    . = 0x80011000; .l1 : { *(.l1) } :data
    . = 0x80012000; .l0 : { *(.l0) } :data
    . = 0x80020000; .identity : { *(.identity) } :data
    . = 0x80021000; .translated : { *(.translated) } :data
    . = 0x80040000; .hvm_vs : { *(.hvm_vs) } :data
    . = 0x80048000; .hctx_vb : { *(.hctx_vb) } :data
    . = 0x80050000; .hvm_g : { *(.hvm_g) } :data
    . = 0x80060000; .hvm_data : { *(.hvm_data) } :data
    /* Keep the guest segment mapped even without optional guest code. */
    . = 0x80064000; .hvm_code : { *(.hvm_code) BYTE(0) } :guest
    . = 0x80070000; .hctx_gb : { *(.hctx_gb) } :data
    . = 0x80078000; .hctx_a : { *(.hctx_a) } :data
    . = 0x8007a000; .hctx_b : { *(.hctx_b) } :data
    . = 0x8007c000; .hctx_db : { *(.hctx_db) } :data
    ASSERT(SIZEOF(.hvm_vs) <= 0x3000, "VS tables overlap G root")
    ASSERT(SIZEOF(.hvm_g) <= 0x7000, "G tables exceed reserved space")
    ASSERT(SIZEOF(.hvm_data) <= 0x4000, "Guest data overlaps guest code")
    ASSERT(SIZEOF(.hvm_code) <= 0x2000, "Guest code exceeds two-page mapping")
    ASSERT(SIZEOF(.hctx_vb) <= 0x3000, "Guest B VS tables exceed reserved space")
    ASSERT(SIZEOF(.hctx_gb) <= 0x7000, "Guest B G tables exceed reserved space")
    ASSERT(SIZEOF(.hctx_a) <= 0x2000, "Guest A context overlaps guest B context")
    ASSERT(SIZEOF(.hctx_b) <= 0x2000, "Guest B context overlaps guest B data")
    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

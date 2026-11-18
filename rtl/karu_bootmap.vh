//  karu_bootmap.vh
//  Size of the boot ROM in the standard Karu address map, in 4 KiB pages.
//
//      0x0000_1000 ..                      boot ROM, KARU_BOOT_ROM_PAGES pages
//      directly above it                   64 KiB scratch SRAM
//
//  The default is 2 MiB: ROM 0x0000_1000..0x0020_0fff, scratch SRAM
//  0x0020_1000..0x0021_0fff. One value is shared by the physical access
//  permissions in the core (karu_pma.vh), the boot memory
//  (flow/fpga/karu_boot_mem.v) and the bus decode (flow/fpga/karu_ddr_xbar.v).
//  The software side must agree with it: the scratch SRAM origin in
//  flow/boot/vcu118_fuboot.ld and the image size in flow/build_fuboot_rom.sh
//  and flow/rom_manifest.py.
//
//  Two ranges inside the ROM's span belong to the debug logic, which decodes
//  them in front of the boot memory. A ROM image must leave both empty
//  (flow/build_fuboot_rom.sh checks it):
//
//      0x0001_0000..0x0002_3fff    the authentication island (KARU_DBG_AUTH)
//      0x0012_0000..0x0012_0fff    the Debug Module's private page
//                                  (KARUDBG_BASE in dbg/karudbg_defs.vh)
//
//  The private page is not part of the ROM for the access permissions
//  either: outside Debug Mode an access to it faults, as it did when the
//  ROM ended below it. KARU_BOOT_DEBUG_PAGE must equal KARUDBG_BASE >> 12;
//  karudbg_core checks that in simulation.
//
//  KARU_BOOT_SCRATCH_LO is the first page of the scratch SRAM and
//  KARU_BOOT_SCRATCH_HI the page after its last. Every user of the range
//  takes it from here, the test models included.
`ifndef KARU_BOOT_ROM_PAGES
`define KARU_BOOT_ROM_PAGES 20'h00200
`endif
`ifndef KARU_BOOT_DEBUG_PAGE
`define KARU_BOOT_DEBUG_PAGE 20'h00120
`define KARU_BOOT_SCRATCH_LO (20'h00001 + `KARU_BOOT_ROM_PAGES)
`define KARU_BOOT_SCRATCH_HI (20'h00011 + `KARU_BOOT_ROM_PAGES)
`endif

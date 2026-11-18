// Shared karudbg map; see dbg/README.md for the integration contract.
// SPDX-License-Identifier: SHL-0.51
// Register/map conventions adapted from pulp-platform/riscv-dbg
// src/dm_pkg.sv and src/dm_mem.sv at
// 643607e19df3435cfd77cc56143e2637f5900a6e (ETH Zurich/University of Bologna).
`ifndef KARUDBG_DEFS_VH
`define KARUDBG_DEFS_VH
`include "karudbg_cfg.vh"
`define KARUDBG_BASE       32'h0012_0000
`define KARUDBG_ENTRY      12'h800
`define KARUDBG_EXCEPTION  12'h810
`define KARUDBG_EXCEPTION_ABSTRACT 12'h890
`define KARUDBG_DRET       12'h888
`define KARUDBG_HALTED     12'h100
`define KARUDBG_GOING      12'h108
`define KARUDBG_RESUMING   12'h110
`define KARUDBG_EXCEPT     12'h118
`define KARUDBG_WHERETO    12'h300
`define KARUDBG_ABSTRACT   12'h338
`define KARUDBG_PROGBUF    12'h360
`define KARUDBG_DATA       12'h380
`define KARUDBG_FLAGS      12'h400
`endif

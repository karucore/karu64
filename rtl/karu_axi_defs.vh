//  karu_axi_defs.vh
//  Common AXI4 signal widths used by the core, adapter, and testbench.
//  `DATA_W` is currently 64; widen at the slave/master boundary when
//  vector lands.

`ifndef KARU_AXI_DEFS_VH
`define KARU_AXI_DEFS_VH

`define AXI_ADDR_W  32
`define AXI_DATA_W  64
`define AXI_STRB_W  8           //  DATA_W / 8
`define AXI_ID_W    4
`define AXI_LEN_W   8
`define AXI_SIZE_W  3
`define AXI_BURST_W 2
`define AXI_PROT_W  3
`define AXI_RESP_W  2

//  Encoding helpers
`define AXI_BURST_FIXED 2'b00
`define AXI_BURST_INCR  2'b01
`define AXI_BURST_WRAP  2'b10

`define AXI_RESP_OKAY   2'b00
`define AXI_RESP_EXOKAY 2'b01
`define AXI_RESP_SLVERR 2'b10
`define AXI_RESP_DECERR 2'b11

`define AXI_SIZE_1B     3'd0
`define AXI_SIZE_2B     3'd1
`define AXI_SIZE_4B     3'd2
`define AXI_SIZE_8B     3'd3

`endif

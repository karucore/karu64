//  karu_hpm_events.vh
//  Implementation-defined event IDs for mhpmevent3..31.

`ifndef KARU_HPM_EVENTS_VH
`define KARU_HPM_EVENTS_VH

`define KARU_HPM_NONE                   8'd0
`define KARU_HPM_SDRAM_DMEM_READ        8'd1
`define KARU_HPM_SDRAM_DMEM_WRITE       8'd2
`define KARU_HPM_SDRAM_IMEM_READ        8'd3
`define KARU_HPM_SDRAM_PARTIAL_WRITE    8'd4
`define KARU_HPM_SDRAM_BYTE_WRITE       8'd5
`define KARU_HPM_SDRAM_FULL_WRITE       8'd6
`define KARU_HPM_SDRAM_BUSY_CYCLE       8'd7
`define KARU_HPM_SDRAM_IMEM_WAIT        8'd8
`define KARU_HPM_SDRAM_DMEM_READ_WAIT   8'd9
`define KARU_HPM_SDRAM_DMEM_WRITE_WAIT  8'd10
`define KARU_HPM_SDRAM_CACHE_READ_HIT   8'd11
`define KARU_HPM_SDRAM_CACHE_WRITE_HIT  8'd12
`define KARU_HPM_SDRAM_CACHE_MISS       8'd13
`define KARU_HPM_SDRAM_CACHE_FILL       8'd14
`define KARU_HPM_SDRAM_CACHE_WRITEBACK  8'd15
`define KARU_HPM_SDRAM_BACKEND_READ     8'd16
`define KARU_HPM_SDRAM_BACKEND_WRITE    8'd17
`define KARU_HPM_SDRAM_CACHE_BUSY_CYCLE 8'd18

`endif

// Actual shipping-geometry Karu + DM + JTAG, with bounded AXI RAM/devices.
// SPDX-License-Identifier: BSD-2-Clause
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
module tb_jtag_core (
    input wire clk, input wire rst,
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    input wire hart_reset,
    output wire tdo, output reg [31:0] request_count,
    output wire [63:0] debug_pc,
    output wire debug_parked
);
    wire hart_reset_i;
    assign hart_reset_i=hart_reset;
    wire ndmreset_o, debug_mode_o, debug_resume_ack_o, trap;
    wire cache_flush_req, cache_flush_invalidate;
    wire irq=0, irq_software=0, irq_external_m=0, irq_external_s=0;
    wire [31:0] uncache_page=0, hpm_events=0;
    reg [63:0] time_in=0;
    reg cache_flush_done=0;
    wire [63:0] mmio_value;
    wire [31:0] fifo_count;
    wire [31:0] mmio_reads, mmio_writes;
    wire [`AXI_ID_W-1:0] imem_arid;
    wire [`AXI_ADDR_W-1:0] imem_araddr;
    wire [`AXI_LEN_W-1:0] imem_arlen;
    wire [`AXI_SIZE_W-1:0] imem_arsize;
    wire [`AXI_BURST_W-1:0] imem_arburst;
    wire [`AXI_PROT_W-1:0] imem_arprot;
    wire  imem_arvalid;
    wire  imem_arready;
    wire [`AXI_ID_W-1:0] imem_rid;
    wire [`AXI_DATA_W-1:0] imem_rdata;
    wire [`AXI_RESP_W-1:0] imem_rresp;
    wire  imem_rlast;
    wire  imem_rvalid;
    wire  imem_rready;
    wire [`AXI_ID_W-1:0] dmem_arid;
    wire [`AXI_ADDR_W-1:0] dmem_araddr;
    wire [`AXI_LEN_W-1:0] dmem_arlen;
    wire [`AXI_SIZE_W-1:0] dmem_arsize;
    wire [`AXI_BURST_W-1:0] dmem_arburst;
    wire [`AXI_PROT_W-1:0] dmem_arprot;
    wire  dmem_arvalid;
    wire  dmem_arready;
    wire [`AXI_ID_W-1:0] dmem_rid;
    wire [`AXI_DATA_W-1:0] dmem_rdata;
    wire [`AXI_RESP_W-1:0] dmem_rresp;
    wire  dmem_rlast;
    wire  dmem_rvalid;
    wire  dmem_rready;
    wire [`AXI_ID_W-1:0] dmem_awid;
    wire [`AXI_ADDR_W-1:0] dmem_awaddr;
    wire [`AXI_LEN_W-1:0] dmem_awlen;
    wire [`AXI_SIZE_W-1:0] dmem_awsize;
    wire [`AXI_BURST_W-1:0] dmem_awburst;
    wire [`AXI_PROT_W-1:0] dmem_awprot;
    wire  dmem_awvalid;
    wire  dmem_awready;
    wire [`AXI_DATA_W-1:0] dmem_wdata;
    wire [`AXI_STRB_W-1:0] dmem_wstrb;
    wire  dmem_wlast;
    wire  dmem_wvalid;
    wire  dmem_wready;
    wire [`AXI_ID_W-1:0] dmem_bid;
    wire [`AXI_RESP_W-1:0] dmem_bresp;
    wire  dmem_bvalid;
    wire  dmem_bready;
    karudbg_top dut (.*,.tdo_oe());
    // Exercise the production reset conditioner, including startup with
    // TCK stopped. Sample at its falling edge, after rising-edge NBA updates.
    integer tck_release_edges;
    always @(posedge tck or posedge rst or negedge trst_n)
        if (rst || !trst_n) tck_release_edges <= 0;
        else if (tck_release_edges < 2)
            tck_release_edges <= tck_release_edges + 1;
    always @(negedge tck)
        if (!rst && trst_n &&
            dut.tck_reset_n !== (tck_release_edges >= 2))
            $fatal(1,"Conventional top reset released before two TCK edges");
    assign debug_pc=dut.system.core.ifu_pc;
    assign debug_parked=dut.system.dm.parked_q;
    karudbg_test_ram #(.ENABLE_FIFO(1),.BOOT_LOOP(1)) memory (.*);
    always @(posedge clk) begin
        if(rst) cache_flush_done<=0;
        else cache_flush_done<=cache_flush_req;
        time_in<=time_in+1;
        if(rst) request_count<=0;
        else if(dut.req_valid && dut.req_ready) request_count<=request_count+1;
        if(!rst && trap) $fatal(1,"Unexpected application trap in OpenOCD core fixture");
    end
endmodule

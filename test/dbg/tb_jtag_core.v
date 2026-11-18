// Actual shipping-geometry Karu + DM + JTAG, with bounded AXI RAM/devices.
// SPDX-License-Identifier: BSD-2-Clause
`include "karu_ext.vh"
`include "karu_axi_defs.vh"
module tb_jtag_core #(parameter ROM_HEX = "") (
    input wire clk, input wire rst,
    input wire tck, input wire tms, input wire tdi, input wire trst_n,
    input wire hart_reset,
    output wire tdo, output reg [31:0] request_count,
    output wire [63:0] debug_pc,
    output wire debug_parked
);
    // Options for the board-harness rehearsals (test/dbg/board). Without
    // these plusargs the fixture is what it was: por is rst, and SRST is the
    // hart reset.
    //   +por_on_srst   the SRST input is the power-on reset of the whole
    //                  dut, as the CPU reset button is on the board, and no
    //                  longer the hart reset
    reg por_on_srst=1'b0;
    initial por_on_srst=$test$plusargs("por_on_srst");
    wire por=rst || (por_on_srst && hart_reset);
    wire hart_reset_i;
    assign hart_reset_i=hart_reset && !por_on_srst;
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
`ifdef KARU_DBG_AUTH
    // lc=AUTH with the boot-hold strap: the hart waits for an authdata
    // REQUEST, then runs the island ROM stub (test/dbg/auth_rom_stub.S).
    // Rehearsal options; the values below are the defaults, as before:
    //   +auth_lc=<0..3>         lifecycle strap
    //   +auth_hold=<0|1>        boot-hold strap
    //   +auth_trng_opst=<0..3>  TRNG status (2 is ES16)
    //   +auth_trng_lfsr         TRNG data from an LFSR that advances with
    //                           every word taken and survives a power-on
    //                           reset, so each window draws another nonce
    reg [1:0] lc_i = 2'd1;
    reg hold_strap_i = 1'b1;
    wire revoke_i = 1'b0;
    reg [1:0] trng_opst_i = 2'd2;
    reg [15:0] trng_data_i = 16'h5a5a;
    reg trng_lfsr = 1'b0;
    wire trng_ack_o, auth_reset_o;
    integer auth_arg;
    initial begin
        if ($value$plusargs("auth_lc=%d", auth_arg)) lc_i = auth_arg[1:0];
        if ($value$plusargs("auth_hold=%d", auth_arg)) hold_strap_i = auth_arg[0];
        if ($value$plusargs("auth_trng_opst=%d", auth_arg)) trng_opst_i = auth_arg[1:0];
        trng_lfsr = $test$plusargs("auth_trng_lfsr");
    end
    always @(posedge clk) if (trng_lfsr && trng_ack_o)
        trng_data_i <= {trng_data_i[14:0], trng_data_i[15] ^ trng_data_i[13] ^ trng_data_i[12] ^ trng_data_i[10]};
    karudbg_top #(.RESET_PC(64'h0001_0000), .ISLAND_ROM_HEX(ROM_HEX)) dut (.*,.rst(por),.tdo_oe());
`else
    karudbg_top dut (.*,.rst(por),.tdo_oe());
`endif
    // Exercise the production reset conditioner, including startup with
    // TCK stopped. Sample at its falling edge, after rising-edge NBA updates.
    integer tck_release_edges;
    always @(posedge tck or posedge por or negedge trst_n)
        if (por || !trst_n) tck_release_edges <= 0;
        else if (tck_release_edges < 2)
            tck_release_edges <= tck_release_edges + 1;
    always @(negedge tck)
        if (!por && trst_n &&
            dut.tck_reset_n !== (tck_release_edges >= 2))
            $fatal(1,"Conventional top reset released before two TCK edges");
    assign debug_pc=dut.system.core.ifu_pc;
    assign debug_parked=dut.system.dm.parked_q;
    karudbg_test_ram #(.ENABLE_FIFO(1),.BOOT_LOOP(1)) memory (.*,.rst(por));
    always @(posedge clk) begin
        if(por) cache_flush_done<=0;
        else cache_flush_done<=cache_flush_req;
        time_in<=time_in+1;
        if(rst) request_count<=0;
        else if(dut.req_valid && dut.req_ready) request_count<=request_count+1;
        if(!por && trap) $fatal(1,"Unexpected application trap in OpenOCD core fixture");
    end
endmodule

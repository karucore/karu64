// SPDX-License-Identifier: BSD-3-Clause
// Core/SBA single-outstanding AXI arbiter and coherent-write coordinator.
// SBA uses physical, native-width, single-beat accesses. Core transactions
// retain their original burst, ID and protection fields. Reset must also
// reset the affected platform responders (no abandoned old R/B responses).
`include "karudbg_defs.vh"
module karudbg_bus #(parameter NONSECURE=1, parameter ENABLE=1) (
    input wire clk, input wire rst,
    input wire req_valid_i, output wire req_ready_o,
    input wire [63:0] req_addr_i, input wire [63:0] req_data_i,
    input wire [2:0] req_size_i, input wire req_write_i,
    output wire resp_valid_o, input wire resp_ready_i,
    output reg [63:0] resp_data_o, output reg [2:0] resp_error_o,
    output wire pause_o, input wire quiet_i, output wire flush_o,
    input wire [3:0] c_arid,
    input wire [31:0] c_araddr,
    input wire [7:0] c_arlen,
    input wire [2:0] c_arsize,
    input wire [1:0] c_arburst,
    input wire [2:0] c_arprot,
    input wire c_arvalid,
    input wire c_rready,
    input wire [3:0] c_awid,
    input wire [31:0] c_awaddr,
    input wire [7:0] c_awlen,
    input wire [2:0] c_awsize,
    input wire [1:0] c_awburst,
    input wire [2:0] c_awprot,
    input wire c_awvalid,
    input wire [63:0] c_wdata,
    input wire [7:0] c_wstrb,
    input wire c_wlast,
    input wire c_wvalid,
    input wire c_bready,
    output wire c_arready,
    output wire [3:0] c_rid,
    output wire [63:0] c_rdata,
    output wire [1:0] c_rresp,
    output wire c_rlast,
    output wire c_rvalid,
    output wire c_awready,
    output wire c_wready,
    output wire [3:0] c_bid,
    output wire [1:0] c_bresp,
    output wire c_bvalid,
    output wire [3:0] m_arid,
    output wire [31:0] m_araddr,
    output wire [7:0] m_arlen,
    output wire [2:0] m_arsize,
    output wire [1:0] m_arburst,
    output wire [2:0] m_arprot,
    output wire m_arvalid,
    output wire m_rready,
    output wire [3:0] m_awid,
    output wire [31:0] m_awaddr,
    output wire [7:0] m_awlen,
    output wire [2:0] m_awsize,
    output wire [1:0] m_awburst,
    output wire [2:0] m_awprot,
    output wire m_awvalid,
    output wire [63:0] m_wdata,
    output wire [7:0] m_wstrb,
    output wire m_wlast,
    output wire m_wvalid,
    output wire m_bready,
    input wire m_arready,
    input wire [3:0] m_rid,
    input wire [63:0] m_rdata,
    input wire [1:0] m_rresp,
    input wire m_rlast,
    input wire m_rvalid,
    input wire m_awready,
    input wire m_wready,
    input wire [3:0] m_bid,
    input wire [1:0] m_bresp,
    input wire m_bvalid);
    // The PMA header deliberately sees no Debug Mode authorization here:
    // an independent SBA master must never acquire the private DM aperture.
    wire debug_mode_i;
    assign debug_mode_i = 1'b0;
    /* verilator lint_off UNUSEDSIGNAL */
    `include "karu_pma.vh"
    /* verilator lint_on UNUSEDSIGNAL */
    localparam IDLE=0, CR=1, CW=2, SR=3, SW=4, MAINT=5, REPLY=6;
    reg [2:0] state;
    reg [31:0] addr_q;
    reg [63:0] data_q;
    reg [2:0] size_q;
    reg ram_write_q, aw_done, w_done, pause_q;
    wire bad_size;
    assign bad_size = req_size_i > 3;
    wire bad_align;
    assign bad_align = |(req_addr_i[2:0] & ((3'b001 << req_size_i)-3'b001));
    wire bad_addr;
    assign bad_addr = !ENABLE || (req_addr_i[63:32] != 0) || !karu_pma_ok(req_addr_i,req_write_i ? 2'd2 : 2'd1) ||
        ((req_addr_i & 64'hffff_ffff_ffff_f000) == {32'b0,`KARUDBG_BASE});
    wire invalid_req;
    assign invalid_req = bad_size || bad_align || bad_addr;
    // Custom platforms may override RAM classification separately from PMA.
`ifdef KARU_DBG_SBA_RAM_HEADER
    `include `KARU_DBG_SBA_RAM_HEADER
`else
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic sba_ram(input [63:0] a);
        begin
            sba_ram = a[63:32]==0 && (a[31] ||
                (a[31:12]>=20'h00101 && a[31:12]<20'h00111));
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
`endif
    wire wants_ram;
    assign wants_ram = req_write_i && sba_ram(req_addr_i) && !invalid_req;
    wire core_read;
    assign core_read = state==CR || (state==IDLE && c_arvalid);
    wire core_write;
    assign core_write = state==CW || (state==IDLE && !c_arvalid && (c_awvalid || c_wvalid));
    wire core_selected;
    assign core_selected = c_arvalid || c_awvalid || c_wvalid;
    // Register the hold so reset-gated request VALID cannot feed through to
    // core issue/trigger logic. On the assertion edge the core may still admit
    // an instruction: require the registered hold AND quiet before accepting
    // a RAM write, so that older instruction drains before either AXI channel.
    wire pause_next;
    assign pause_next = (req_valid_i && wants_ram) ||
        ((state==SW || state==MAINT || (state==REPLY && !resp_ready_i)) && ram_write_q);
    always @(posedge clk) begin
        if(rst) pause_q<=0;
        else pause_q<=pause_next;
    end
    assign req_ready_o = state==IDLE && !core_selected && (!wants_ram || (pause_q && quiet_i));
    assign pause_o = pause_q;
    assign flush_o = state==MAINT;
    assign resp_valid_o = state==REPLY;
    wire [63:0] aligned_data;
    assign aligned_data = data_q << {addr_q[2:0],3'b000};
    wire [7:0] byte_mask;
    assign byte_mask = (size_q==0 ? 8'h01 : size_q==1 ? 8'h03 :
                            size_q==2 ? 8'h0f : 8'hff) << addr_q[2:0];
    assign m_arid = core_read ? c_arid : (4'b0);
    assign m_araddr = core_read ? c_araddr : (addr_q[31:0]);
    assign m_arlen = core_read ? c_arlen : (8'b0);
    assign m_arsize = core_read ? c_arsize : (size_q);
    assign m_arburst = core_read ? c_arburst : (2'b01);
    assign m_arprot = core_read ? c_arprot : ({1'b0,NONSECURE!=0,1'b1});
    assign m_arvalid = core_read ? c_arvalid : (state==SR && !aw_done);
    assign m_rready = core_read ? c_rready : (state==SR);
    assign m_awid = core_write ? c_awid : (4'b0);
    assign m_awaddr = core_write ? c_awaddr : (addr_q[31:0]);
    assign m_awlen = core_write ? c_awlen : (8'b0);
    assign m_awsize = core_write ? c_awsize : (size_q);
    assign m_awburst = core_write ? c_awburst : (2'b01);
    assign m_awprot = core_write ? c_awprot : ({1'b0,NONSECURE!=0,1'b1});
    assign m_awvalid = core_write ? c_awvalid : (state==SW && !aw_done);
    assign m_wdata = core_write ? c_wdata : (aligned_data);
    assign m_wstrb = core_write ? c_wstrb : (byte_mask);
    assign m_wlast = core_write ? c_wlast : (1'b1);
    assign m_wvalid = core_write ? c_wvalid : (state==SW && !w_done);
    assign m_bready = core_write ? c_bready : (state==SW && aw_done && w_done);
    assign c_arready = core_read ? m_arready : 1'b0;
    assign c_rid = core_read ? m_rid : 4'b0;
    assign c_rdata = core_read ? m_rdata : 64'b0;
    assign c_rresp = core_read ? m_rresp : 2'b0;
    assign c_rlast = core_read ? m_rlast : 1'b0;
    assign c_rvalid = core_read ? m_rvalid : 1'b0;
    assign c_awready = core_write ? m_awready : 1'b0;
    assign c_wready = core_write ? m_wready : 1'b0;
    assign c_bid = core_write ? m_bid : 4'b0;
    assign c_bresp = core_write ? m_bresp : 2'b0;
    assign c_bvalid = core_write ? m_bvalid : 1'b0;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; ram_write_q<=0; aw_done<=0; w_done<=0;
            resp_error_o<=0; resp_data_o<=0;
        end else case(state)
            IDLE: begin
                ram_write_q<=0; aw_done<=0; w_done<=0;
                if(c_arvalid) state<=CR;
                else if(c_awvalid || c_wvalid) state<=CW;
                else if(req_valid_i && req_ready_o) begin
                    addr_q<=req_addr_i[31:0]; data_q<=req_data_i; size_q<=req_size_i;
                    ram_write_q<=wants_ram; resp_error_o<=0; resp_data_o<=0;
                    if(invalid_req) begin
                        resp_error_o<=bad_size ? 3'd4 : bad_align ? 3'd3 : 3'd2;
                        state<=REPLY;
                    end else state<=req_write_i ? SW : SR;
                end
            end
            CR: if(m_rvalid && c_rready && m_rlast) state<=IDLE;
            CW: if(m_bvalid && c_bready) state<=IDLE;
            SR: begin
                if(m_arvalid && m_arready) aw_done<=1;
                if(m_rvalid && m_rready) begin
                    resp_data_o<=m_rdata >> {addr_q[2:0],3'b000};
                    resp_error_o<=m_rresp[1] || !m_rlast ? 3'd2 : 3'd0;
                    state<=REPLY;
                end
            end
            SW: begin
                if(m_awvalid && m_awready) aw_done<=1;
                if(m_wvalid && m_wready) w_done<=1;
                if(m_bvalid && m_bready) begin
                    resp_error_o<=m_bresp[1] ? 3'd2 : 3'd0;
                    state<=ram_write_q ? MAINT : REPLY;
                end
            end
            // A full quiet clock with flush asserted invalidates both caches
            // and redirects the fetch stream before the response is exposed.
            MAINT: if(quiet_i) state<=REPLY;
            REPLY: if(resp_ready_i) begin state<=IDLE; ram_write_q<=0; end
            default: state<=IDLE;
        endcase
    end
    // synthesis translate_off
    // SBAB1..8 derive ownership and issue counts from interface handshakes.
    // Maintenance may wait indefinitely for quiet/external cache completion.
    reg sbab_reset_seen;
    initial sbab_reset_seen=0;
    reg sbab_owned, sbab_read, sbab_ram, sbab_invalid;
    reg sbab_ar, sbab_aw, sbab_w, sbab_b, sbab_maint;
    reg sbab_arstall, sbab_awstall, sbab_wstall, sbab_replystall;
    reg sbab_pause;
    reg [51:0] sbab_arpayload, sbab_awpayload;
    reg [72:0] sbab_wpayload;
    reg [66:0] sbab_replypayload;
    always @(posedge clk) begin
        if(rst)begin
            sbab_reset_seen<=1;
            sbab_owned<=0;sbab_ar<=0;sbab_aw<=0;sbab_w<=0;
            sbab_b<=0;sbab_maint<=0;sbab_arstall<=0;sbab_awstall<=0;
            sbab_wstall<=0;sbab_replystall<=0;sbab_pause<=0;
        end else if(sbab_reset_seen)begin
            if(state>REPLY) $fatal(1,"SBAB1 invalid bus state");
            if((state==SR || state==SW || state==MAINT || state==REPLY) !== sbab_owned)
                $fatal(1,"SBAB2 SBA ownership differs from accepted request");
            if(sbab_owned && (c_arready||c_awready||c_wready||c_rvalid||c_bvalid))
                $fatal(1,"SBAB3 SBA response/request leaked to core");
            if(sbab_owned && (m_arvalid||m_awvalid||m_wvalid) &&
                (sbab_invalid || (sbab_read ? state!=SR : state!=SW)))
                $fatal(1,"SBAB3 bus VALID outside authorized owner phase");
            if(req_valid_i&&req_ready_o)begin
                if(sbab_owned || (wants_ram&&(!pause_o||!quiet_i)))
                    $fatal(1,"SBAB4 ownership or pre-write drain violated");
                sbab_owned<=1;sbab_read<=!req_write_i;sbab_ram<=wants_ram;
                sbab_invalid<=invalid_req;
                sbab_ar<=0;sbab_aw<=0;sbab_w<=0;sbab_b<=0;sbab_maint<=0;
            end
            if(sbab_owned&&m_arvalid&&m_arready)begin
                if(sbab_ar||!sbab_read) $fatal(1,"SBAB4 duplicate or wrong-kind AR");
                sbab_ar<=1;
            end
            if(sbab_owned&&m_awvalid&&m_awready)begin
                if(sbab_aw||sbab_read) $fatal(1,"SBAB4 duplicate or wrong-kind AW");
                sbab_aw<=1;
            end
            if(sbab_owned&&m_wvalid&&m_wready)begin
                if(sbab_w||sbab_read) $fatal(1,"SBAB4 duplicate or wrong-kind W");
                sbab_w<=1;
            end
            if(sbab_owned&&m_rvalid&&m_rready&&!sbab_ar&&!(m_arvalid&&m_arready))
                $fatal(1,"SBAB4 read response before address acceptance");
            if(sbab_owned&&m_bvalid&&m_bready)begin
                if(!sbab_aw||!sbab_w) $fatal(1,"SBAB4 B before AW/W completion");
                sbab_b<=1;
            end
            if(flush_o)begin
                if(!sbab_owned||!sbab_ram||!sbab_b||!pause_o)
                    $fatal(1,"SBAB5 maintenance without completed RAM write/hold");
                if(quiet_i)sbab_maint<=1;
            end
            if(resp_valid_o&&sbab_ram&&!sbab_maint)
                $fatal(1,"SBAB5 RAM response before completed maintenance");
            if(sbab_owned&&sbab_ram&&!pause_o)
                $fatal(1,"SBAB5 RAM owner lost maintenance hold");
            if(pause_o!==sbab_pause)
                $fatal(1,"SBAB8 pause differs from registered request/ownership history");
            sbab_pause<=(req_valid_i&&wants_ram) ||
                (sbab_owned&&sbab_ram&&!(resp_valid_o&&resp_ready_i));
            if(resp_valid_o&&resp_ready_i)sbab_owned<=0;
            if(sbab_arstall&&(!m_arvalid||{m_arid,m_araddr,m_arlen,m_arsize,m_arburst,m_arprot}!==sbab_arpayload))
                $fatal(1,"SBAB6 stalled AR changed");
            if(sbab_awstall&&(!m_awvalid||{m_awid,m_awaddr,m_awlen,m_awsize,m_awburst,m_awprot}!==sbab_awpayload))
                $fatal(1,"SBAB6 stalled AW changed");
            if(sbab_wstall&&(!m_wvalid||{m_wdata,m_wstrb,m_wlast}!==sbab_wpayload))
                $fatal(1,"SBAB6 stalled W changed");
            if(sbab_replystall&&(!resp_valid_o||{resp_data_o,resp_error_o}!==sbab_replypayload))
                $fatal(1,"SBAB7 stalled response changed");
            sbab_arstall<=m_arvalid&&!m_arready;
            sbab_awstall<=m_awvalid&&!m_awready;
            sbab_wstall<=m_wvalid&&!m_wready;
            sbab_replystall<=resp_valid_o&&!resp_ready_i;
            sbab_arpayload<={m_arid,m_araddr,m_arlen,m_arsize,m_arburst,m_arprot};
            sbab_awpayload<={m_awid,m_awaddr,m_awlen,m_awsize,m_awburst,m_awprot};
            sbab_wpayload<={m_wdata,m_wstrb,m_wlast};
            sbab_replypayload<={resp_data_o,resp_error_o};
        end
    end
    // synthesis translate_on
    wire unused_ids;
    assign unused_ids = &{m_rid,m_bid,debug_mode_i,1'b0};
endmodule

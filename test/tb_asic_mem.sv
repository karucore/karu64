// Four-state check: ASIC data storage has no power-up value; explicit writes
// establish readable data, byte enables and soft-reset retention still work.
`timescale 1ns/1ps
module tb_asic_mem;
    reg clk = 0, rst = 1;
    reg ae = 0, aw = 0, be = 0, bw = 0;
    reg [5:0] aa = 0, ba = 1;
    reg [15:0] abe = 0, bbe = 0;
    reg [127:0] ad = 0, bd = 0;
    wire [127:0] aq, bq;
    wire [255:0] mask;
    reg corrupt_mask = 0, corrupt_read = 0;
    karu_vrf_bram vrf(clk, rst, ae, aw, aa, abe, ad, aq,
                     be, bw, ba, bbe, bd, bq, mask);
    karu_vrf_assert #(.STOP_ON_FAIL(0)) check_vrf(
        .clk(clk), .rst(rst), .varith_active(1'b1), .vlsu_active(1'b0),
        .a_en(ae), .a_we(aw), .a_addr(aa), .a_be(abe), .a_wdata(ad),
        .a_rdata(aq ^ {127'b0,corrupt_read}),
        .b_en(be), .b_we(bw), .b_addr(ba), .b_be(bbe), .b_wdata(bd), .b_rdata(bq),
        .v0(mask ^ {255'b0,corrupt_mask}), .wb_vl_governed(1'b0),
        .wb_mask_dest(1'b0), .wb_vl(16'b0), .wb_vsew(3'b0),
        .wb_group_reg(5'b0), .wb_epr(16'b0));

    reg we = 0;
    reg [4:0] addr = 1;
    reg [63:0] data = 0;
    wire [63:0] r1, r2, f1, f2, m1, m2, m3;
    karu_regfile rf(clk, addr, r1, 5'd0, r2, we, addr, data);
    karu_fregfile frf(clk, addr, f1, addr, f2, we, addr, data);
    karu_1w1r_async_ram #(.DEPTH(4), .ADDR_W(2)) one(
        clk, we, addr[1:0], data, addr[1:0], m1);
    karu_1w2r_async_ram #(.DEPTH(4), .ADDR_W(2)) two(
        clk, we, addr[1:0], data, addr[1:0], m2, addr[1:0], m3);

    task tick;
        begin #5; clk = 1; #1; clk = 0; #4; end
    endtask

    initial begin
        #1;
        if (r1 !== 64'bx || f1 !== 64'bx || f2 !== 64'bx ||
            m1 !== 64'bx || m2 !== 64'bx || m3 !== 64'bx ||
            aq !== 128'bx || bq !== 128'bx || mask !== 256'bx)
            $fatal(1, "ASIC data storage unexpectedly has a power-up value");
        if (r2 !== 0) $fatal(1, "x0 must be zero without initialization");
        tick; rst = 0;

        we = 1; data = 64'h123456789abcdef0;
        ae = 1; aw = 1; abe = 16'hffff; ad = {16{8'ha5}};
        be = 1; bw = 1; bbe = 16'hffff; bd = {16{8'h3c}};
        tick;
        if (r1 !== data || f1 !== data || f2 !== data ||
            m1 !== data || m2 !== data || m3 !== data || mask !== {bd,ad})
            $fatal(1, "explicit writes did not establish coherent data");
        if (aq !== 128'bx || bq !== 128'bx)
            $fatal(1, "VRF write must hold the read output (NO_CHANGE)");

        we = 0; aw = 0; bw = 0;
        tick;
        if (aq !== ad || bq !== bd) $fatal(1, "VRF synchronous read failed");
        aw = 1; abe = 16'h0001; ad = {16{8'h5a}};
        tick;
        if (aq !== {16{8'ha5}} || mask[127:0] !== {{15{8'ha5}},8'h5a})
            $fatal(1, "VRF byte enable / NO_CHANGE failed");
        aw = 0; rst = 1;
        tick;
        if (aq !== {{15{8'ha5}},8'h5a} || bq !== bd || mask !== {bd,aq})
            $fatal(1, "soft reset must preserve VRF and shadow together");
        // Integer x0 writes are suppressed; f0 remains an ordinary register.
        rst = 0; addr = 0; we = 1; data = 64'hfeed;
        tick;
        if (r1 !== 0 || r2 !== 0 || f1 !== data)
            $fatal(1, "x0/f0 semantics changed");
        if (check_vrf.fails != 0) $fatal(1, "VRF checker rejected valid ASIC startup/write behavior");
        // Expected negative controls: masking unknown bytes must not hide
        // corruption of bytes that have been written, including across reset.
        corrupt_mask = 1; tick;
        if (check_vrf.fails != 1) $fatal(1, "VRF checker missed initialized mask corruption");
        corrupt_mask = 0; corrupt_read = 1; tick;
        if (check_vrf.fails != 2) $fatal(1, "VRF checker missed initialized read corruption");
        corrupt_read = 0; tick;
        if (check_vrf.fails != 2) $fatal(1, "VRF checker did not recover after negative controls");
        $display("ASIC_MEM PASS: uninitialized data, x0, writes, byte enables, NO_CHANGE, retention");
        $finish;
    end
endmodule

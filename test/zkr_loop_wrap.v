//  zkr_loop_wrap.v -- for make zkr-loop-test.
//
//  The CSR file and the entropy block, connected as in the SoC, and nothing
//  else. A CSR set or clear instruction computes the value it writes from
//  the value it reads, so zkr_wdata_o depends combinationally on
//  zkr_rdata_i. The entropy block must therefore not let csr_rdata_o depend
//  on csr_wdata_i, csr_we_i or csr_fire_i, or the two form a combinational
//  loop. Simulation does not notice such a loop when its two halves are
//  never active together; Vivado refuses to write a bitstream with it.
//
//  zkr_loop_strict is the same rule stated on the entropy block alone, and
//  does not rely on what karu_csr happens to do: the value that the core
//  reads is fed back into the write strobes and the written value.
//  csr_sel_i stays an input: it is decoded from the instruction, and the
//  read value has to depend on it.
//  SPDX-License-Identifier: BSD-2-Clause
module zkr_loop_strict (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire        rng_val,
    input  wire [3:0]  rng_b,
    input  wire [1:0]  sel,
    output wire [63:0] rdata
);
    wire fb = ^rdata;
    karu_entropy entropy (
        .clk(clk), .rst(rst), .en_i(en),
        .rng_en_o(), .rng_fips_o(), .rng_val_i(rng_val), .rng_b_i(rng_b),
        .csr_fire_i(fb), .csr_sel_i(sel), .csr_we_i(fb),
        .csr_wdata_i(rdata), .csr_rdata_o(rdata), .respace_i(fb), .test_o(), .lock_o());
endmodule

module zkr_loop_wrap (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire        rng_val,
    input  wire [3:0]  rng_b,
    input  wire        op_req,
    input  wire [11:0] op_addr,
    input  wire [63:0] op_src,
    input  wire [4:0]  op_sub,
    input  wire [4:0]  op_rs1,
    input  wire        trap_req,
    output wire [63:0] op_rd_v,
    output wire [1:0]  csr_exc
);
    wire [63:0] zkr_rdata, zkr_wdata;
    wire        zkr_fire, zkr_we;
    wire [1:0]  zkr_sel;
    karu_csr csr (
        .clk(clk), .rst(rst),
        .zkr_rdata_i(zkr_rdata), .zkr_fire_o(zkr_fire), .zkr_sel_o(zkr_sel),
        .zkr_we_o(zkr_we), .zkr_wdata_o(zkr_wdata),
        .op_req(op_req), .op_addr(op_addr), .op_src(op_src), .op_sub(op_sub), .op_rs1(op_rs1),
        .op_rd_v(op_rd_v), .csr_exc_o(csr_exc), .trap_req(trap_req));
    karu_entropy entropy (
        .clk(clk), .rst(rst), .en_i(en),
        .rng_en_o(), .rng_fips_o(), .rng_val_i(rng_val), .rng_b_i(rng_b),
        .csr_fire_i(zkr_fire), .csr_sel_i(zkr_sel), .csr_we_i(zkr_we),
        .csr_wdata_i(zkr_wdata), .csr_rdata_o(zkr_rdata), .respace_i(1'b0), .test_o(), .lock_o());
endmodule

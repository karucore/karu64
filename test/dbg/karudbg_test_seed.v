// SPDX-License-Identifier: BSD-3-Clause
// Bench stand-in for an entropy source on the core's Zkr sideband
// (KARU_ZKR): the seed CSR reports the status and the word that the bench
// drives, and an access that writes takes the word. mnoise, mentropycfg and
// mentropystat read zero. The debug authentication ROM draws its nonce from
// seed, so a bench that runs that ROM needs a source: this one where the
// bench wants to choose every word, flow/fpga/karu_entropy_src.v where it
// wants the real block.
module karudbg_test_seed (
    input wire zkr_fire_i,
    input wire [1:0] zkr_sel_i,      // 0 seed
    input wire zkr_we_i,
    output wire [63:0] zkr_rdata_o,
    input wire [1:0] opst_i,         // 0 BIST, 1 WAIT, 2 ES16, 3 DEAD
    input wire [15:0] data_i,
    output wire taken_o              // an ES16 word is taken in this cycle
);
    assign zkr_rdata_o = (zkr_sel_i == 2'd0) ?
        {32'b0, opst_i, 14'b0, opst_i == 2'd2 ? data_i : 16'b0} : 64'b0;
    assign taken_o = zkr_fire_i && zkr_we_i && zkr_sel_i == 2'd0 && opst_i == 2'd2;
endmodule

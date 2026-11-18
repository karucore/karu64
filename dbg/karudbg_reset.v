// SPDX-License-Identifier: BSD-3-Clause
// Assert even with the destination clock stopped; release only after two
// destination-clock rising edges. Instantiate separately for each domain.
module karudbg_reset (
    input wire clk,
    input wire reset_i,
    output wire reset_n_o
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] release_q;
    always @(posedge clk or posedge reset_i)
        if (reset_i) release_q <= 2'b00;
        else release_q <= {release_q[0], 1'b1};
    assign reset_n_o = release_q[1];
endmodule

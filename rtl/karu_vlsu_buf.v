//  karu_vlsu_buf.v
//  Scratch buffers for karu_vlsu.
//
//  This leaf keeps the large temporary arrays out of the VLSU control FSM while
//  preserving the existing async multi-read behavior. An ASIC flow can replace
//  this module with a compiled scratch/register-file implementation without
//  matching arrays buried inside the load/store sequencer.

`include "karu_vcfg.vh"

module karu_vlsu_buf #(
    parameter integer GRAN = `KARU_VGRAN,
    parameter integer GW   = (`KARU_VGRAN > 1) ? $clog2(`KARU_VGRAN) : 1
) (
    input  wire         clk,

    //  Contiguous path geometry.
    input  wire [5:0]   rg,
    input  wire [5:0]   mg,
    input  wire [3:0]   boff,
    input  wire [31:0]  nbytes,
    input  wire [31:0]  vst_b,
    input  wire [1:0]   eew_q,
    input  wire         vm_q,
    input  wire [`KARU_VLEN-1:0] v0_q,
    output reg  [127:0] asm_gran,
    output reg  [127:0] st_wdata,
    output reg  [15:0]  st_strb,

    //  Per-element path geometry.
    input  wire [1:0]   idx_eew_q,
    input  wire [31:0]  pe_i,
    input  wire [31:0]  rbyte0,
    input  wire [31:0]  eewb,
    input  wire [3:0]   pe_off,
    output reg  [63:0]  idxv,
    output reg  [127:0] pe_wd0,
    output reg  [127:0] pe_wd1,
    output reg  [15:0]  pe_st0,
    output reg  [15:0]  pe_st1,
    output reg  [127:0] pe_wbgran,

    //  Write intents from the VLSU FSM.
    input  wire         regbuf_we,
    input  wire [5:0]   regbuf_wrg,
    input  wire [127:0] regbuf_wdata,

    input  wire         membuf_we,
    input  wire [5:0]   membuf_wmg,
    input  wire [127:0] membuf_wdata,

    input  wire         pib_we,
    input  wire [5:0]   pib_wrg,
    input  wire [127:0] pib_wdata,

    input  wire         peb_gran_we,
    input  wire [5:0]   peb_wrg,
    input  wire [127:0] peb_wdata,

    input  wire         peb_elem_we,
    input  wire [31:0]  peb_elem_base,
    input  wire [3:0]   peb_elem_off,
    input  wire [127:0] peb_elem_g0,
    input  wire [127:0] peb_elem_g1
);
    localparam integer MAXRG = 8 * GRAN;
    localparam integer MAXMG = MAXRG + 2;
    localparam integer MAXB  = 8 * `KARU_VLENB;
    localparam integer RGW   = $clog2(MAXRG);
    localparam integer BW    = $clog2(MAXB);

    reg [127:0] membuf [0:MAXMG-1];
    reg [127:0] regbuf [0:MAXRG-1];
    reg [7:0]   peb [0:MAXB-1];
    reg [7:0]   pib [0:MAXB-1];

    integer k;
    reg [31:0] bi, sa, ej;
    reg [127:0] msel;
    reg act;
    always @(*) begin
        asm_gran = regbuf[rg[RGW-1:0]];
        for (k = 0; k < 16; k = k + 1) begin
            bi  = ({26'b0, rg} << 4) + k[31:0];
            ej  = bi >> eew_q;
            act = vm_q || v0_q[ej[7:0]];
            sa  = {28'b0, boff} + bi;
            msel = membuf[sa[31:4]];
            asm_gran[k*8 +: 8] =
                (bi >= nbytes) ? regbuf[rg[RGW-1:0]][k*8 +: 8] :
                (bi <  vst_b)  ? regbuf[rg[RGW-1:0]][k*8 +: 8] :
                act            ? msel[{sa[3:0], 3'b000} +: 8]
                               : regbuf[rg[RGW-1:0]][k*8 +: 8];
        end
    end

    integer p;
    reg [31:0] mabs;
    reg signed [31:0] ri;
    reg [31:0] rabs, sej;
    reg [127:0] rsel;
    always @(*) begin
        st_wdata = 128'b0;
        st_strb  = 16'b0;
        mabs = 32'b0; ri = 32'sb0; rabs = 32'b0; sej = 32'b0; rsel = 128'b0;
        for (p = 0; p < 16; p = p + 1) begin
            mabs = ({26'b0, mg} << 4) + p[31:0];
            ri   = $signed(mabs) - $signed({28'b0, boff});
            if (ri >= $signed(vst_b) && ri < $signed(nbytes)) begin
                rabs = ri[31:0];
                sej  = rabs >> eew_q;
                if (vm_q || v0_q[sej[7:0]]) begin
                    rsel = regbuf[rabs[31:4]];
                    st_wdata[p*8 +: 8] = rsel[{rabs[3:0], 3'b000} +: 8];
                    st_strb[p] = 1'b1;
                end
            end
        end
    end

    integer ik;
    reg [31:0] ibyte;
    always @(*) begin
        idxv = 64'b0;
        ibyte = 32'b0;
        for (ik = 0; ik < 8; ik = ik + 1)
            if (ik < (32'd1 << idx_eew_q)) begin
                ibyte = pe_i * (32'd1 << idx_eew_q) + ik[31:0];
                idxv[ik*8 +: 8] = pib[ibyte[BW-1:0]];
            end
    end

    integer sk;
    reg [31:0] mbk;
    always @(*) begin
        pe_wd0 = 128'b0; pe_wd1 = 128'b0; pe_st0 = 16'b0; pe_st1 = 16'b0; mbk = 32'b0;
        for (sk = 0; sk < 8; sk = sk + 1)
            if (sk < eewb) begin
                mbk = {28'b0, pe_off} + sk[31:0];
                if (mbk < 32'd16) begin
                    pe_wd0[mbk[3:0]*8 +: 8] = peb[(rbyte0+sk[31:0]) & (MAXB-1)];
                    pe_st0[mbk[3:0]] = 1'b1;
                end else begin
                    pe_wd1[(mbk-32'd16)*8 +: 8] = peb[(rbyte0+sk[31:0]) & (MAXB-1)];
                    pe_st1[mbk[3:0]] = 1'b1;
                end
            end
    end

    integer wk;
    always @(*) begin
        pe_wbgran = 128'b0;
        for (wk = 0; wk < 16; wk = wk + 1)
            pe_wbgran[wk*8 +: 8] = peb[((({26'b0, rg} << 4) + wk[31:0]) & (MAXB-1))];
    end

    integer wi;
    always @(posedge clk) begin
        if (regbuf_we)
            regbuf[regbuf_wrg[RGW-1:0]] <= regbuf_wdata;

        if (membuf_we)
            membuf[membuf_wmg] <= membuf_wdata;

        if (pib_we)
            for (wi = 0; wi < 16; wi = wi + 1)
                pib[((({26'b0, pib_wrg} << 4) + wi[31:0]) & (MAXB-1))] <= pib_wdata[wi*8 +: 8];

        if (peb_gran_we)
            for (wi = 0; wi < 16; wi = wi + 1)
                peb[((({26'b0, peb_wrg} << 4) + wi[31:0]) & (MAXB-1))] <= peb_wdata[wi*8 +: 8];

        if (peb_elem_we)
            for (wi = 0; wi < 8; wi = wi + 1)
                if (wi < eewb)
                    peb[(peb_elem_base + wi[31:0]) & (MAXB-1)] <=
                        (({28'b0, peb_elem_off} + wi[31:0]) < 32'd16)
                            ? peb_elem_g0[({28'b0, peb_elem_off} + wi[31:0])*8 +: 8]
                            : peb_elem_g1[({28'b0, peb_elem_off} + wi[31:0] - 32'd16)*8 +: 8];
    end
endmodule

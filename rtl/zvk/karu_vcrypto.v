//  karu_vcrypto.v
//  Zvk standard vector-crypto unit -- the single ISOLATED crypto datapath
//  (analogous to the one `keccak i_keccak` behind vkeccak). It aggregates the
//  locally cleaned Marian leaf cores behind ONE uniform req/busy/done handshake so the
//  karu_varith sequencer can drive any Zvk op the same way it drives keccak:
//    load operand groups -> pulse req -> wait done -> store vd group.
//
//  Element group width per op: EGW128 (AES / SM4 / GHASH / SHA-256-SEW32) or
//  EGW256 (SHA-2 SEW64 / SM3). egw_* ports are 256b; EGW128 ops use the low 128.
//
//  Timing: AES and SM3 message expansion are combinational but their result is
//  REGISTERED here. SHA2 and SM3 compression are staged in local iterative
//  wrappers. SM4 runs one generalized-Feistel round/cycle in karu_sm4_iter.
//  GHASH is serialised via karu_ghash (KARU_V_GHASH_CYCLES).
//
//  Cross-checked: each leaf core is bit-exact to its standard KAT (see
//  test/zvk/tb_*_kat.sv); this wrapper is KAT'd as a unit in tb_vcrypto_kat.sv.
//
//  cop[4:0] operation selector (see localparams). aux[4:0]:
//    AESKF1/2, SM4K, SM3C : round / uimm
//    SHA2CH/CL/MS         : bit0 = SEW64 (SHA-512) else SHA-256
//  Wiring (matches Marian aes.sv/sha.sv/sm4.sv/sm3.sv + gcm dispatch):
//    AES encdec   : state=vd,  key=vs2
//    AES keyexp   : curr=vs2,  prev=vd,  rnd=aux, kf2=(cop==AESKF2)
//    SHA2 compress: c0=vd, c1=vs2, msg=vs1
//    SHA2 msgsched: w0=vd, w1=vs2, w2=vs1
//    SM4 round    : state=vd,  key=vs2
//    SM4 keyexp   : curr=vs2,  rnd=aux[2:0]
//    SM3 compress : crnt=vd,   msg=vs2,  rnds=aux
//    SM3 msgexp   : start=vs1, end=vs2
//    GHASH        : vd, vs1, vs2 (mode: GHSH=1 add-mult, GMUL=0 mult)

`include "karu_ext.vh"

module karu_vcrypto (
    input  wire         clk,
    input  wire         rst,
    input  wire         req,        //  pulse one cycle to start (when !busy)
    input  wire [4:0]   cop,        //  crypto op selector
    input  wire [4:0]   aux,        //  round/uimm or SEW64 flag (see header)
    input  wire [255:0] egw_vd,
    input  wire [255:0] egw_vs1,
    input  wire [255:0] egw_vs2,
    output reg          busy,
    output reg          done,
    output reg  [255:0] egw_res
);
    //  ---- op encoding ----
    localparam [4:0]
        COP_AESZ   = 5'd0,  COP_AESEM  = 5'd1,  COP_AESEF  = 5'd2,
        COP_AESDM  = 5'd3,  COP_AESDF  = 5'd4,  COP_AESKF1 = 5'd5,
        COP_AESKF2 = 5'd6,  COP_SHA2CH = 5'd7,  COP_SHA2CL = 5'd8,
        COP_SHA2MS = 5'd9,  COP_SM4R   = 5'd10, COP_SM4K   = 5'd11,
        COP_SM3C   = 5'd12, COP_SM3ME  = 5'd13, COP_GHSH   = 5'd14,
        COP_GMUL   = 5'd15;

    //  ---- latched request ----
    reg  [4:0]   cop_q, aux_q;
    reg  [255:0] vd_q, vs1_q, vs2_q;

    //  ================= leaf cores (all combinational except GHASH) =========
`ifdef KARU_EN_ZVKNED
    //  AES encdec: aes_op 000=Z 010=EM 011=EF 100=DM 101=DF
    wire [2:0] aes_op =
        (cop_q == COP_AESEM) ? 3'b010 :
        (cop_q == COP_AESEF) ? 3'b011 :
        (cop_q == COP_AESDM) ? 3'b100 :
        (cop_q == COP_AESDF) ? 3'b101 : 3'b000; //  AESZ
    wire [127:0] aes_enc_o;
    encdec i_aes_encdec (
        .aes_op_i    (aes_op),
        .rnd_state_i (vd_q[127:0]),
        .rnd_key_i   (vs2_q[127:0]),
        .rnd_state_o (aes_enc_o)
    );
    wire [127:0] aes_kf_o;
    key_expansion i_aes_keyexp (
        .aes_kop_i      (cop_q == COP_AESKF2),
        .rnd_i          (aux_q[3:0]),
        .curr_rnd_key_i (vs2_q[127:0]),
        .prev_rnd_key_i (vd_q[127:0]),
        .next_rnd_key_o (aes_kf_o)
    );
`endif

`ifdef KARU_EN_ZVKNHA
    //  SHA-2: sha_op = {CL?, SEW64} ; compression + message schedule
    wire [1:0] sha_op = {(cop_q == COP_SHA2CL), aux_q[0]};
    reg          sha2_req;
    wire         sha2_busy, sha2_done;
    wire [255:0] sha2_o;
    karu_sha2_iter i_sha2 (
        .clk(clk), .rst(rst), .req(sha2_req),
        .is_ms(cop_q == COP_SHA2MS),
        .sha_op(sha_op),
        .state0_i(vd_q),
        .state1_i(vs2_q),
        .msg_i(vs1_q),
        .busy(sha2_busy), .done(sha2_done), .result(sha2_o)
    );
    wire _sha2_unused = &{1'b0, sha2_busy};
`endif

`ifdef KARU_EN_ZVKSED
    //  SM4: four dependent generalized-Feistel rounds, iterated one round/cycle.
    reg          sm4_req;
    wire         sm4_busy, sm4_done;
    wire [127:0] sm4_o;
    karu_sm4_iter i_sm4 (
        .clk(clk), .rst(rst), .req(sm4_req),
        .is_key(cop_q == COP_SM4K),
        .rnd(aux_q[2:0]),
        .state_i(vd_q[127:0]),
        .key_i(vs2_q[127:0]),
        .busy(sm4_busy), .done(sm4_done), .result(sm4_o)
    );
    wire _sm4_unused = &{1'b0, sm4_busy};
`endif

`ifdef KARU_EN_ZVKSH
    //  SM3
    reg          sm3_req;
    wire         sm3_busy, sm3_done;
    wire [255:0] sm3_comp_o, sm3_me_o;
    karu_sm3_iter i_sm3_comp (
        .clk(clk), .rst(rst), .req(sm3_req),
        .rnds(aux_q),
        .crnt_state_i(vd_q),
        .msg_words_i(vs2_q),
        .busy(sm3_busy), .done(sm3_done), .result(sm3_comp_o)
    );
    sm3_msg_expansion i_sm3_me (
        .msg_words_start_i (vs1_q),
        .msg_words_end_i   (vs2_q),
        .msg_words_o       (sm3_me_o)
    );
    wire _sm3_unused = &{1'b0, sm3_busy};
`endif

`ifdef KARU_EN_ZVKG
    //  GHASH (multi-cycle): mode 1 = vghsh (add-mult), 0 = vgmul
    reg          gh_req;
    wire         gh_busy, gh_done;
    wire [127:0] gh_prod;
    karu_ghash i_ghash (
        .clk(clk), .rst(rst), .req(gh_req),
        .mode(cop_q == COP_GHSH),
        .vd (vd_q [127:0]),
        .vs1(vs1_q[127:0]),
        .vs2(vs2_q[127:0]),
        .busy(gh_busy), .done(gh_done), .prod(gh_prod)
    );
    wire _gh_unused = &{1'b0, gh_busy};
`endif

    //  ---- combinational result mux (for the shallow cores) ----
    reg [255:0] comb_res;
    always @(*) begin
        case (cop_q)
`ifdef KARU_EN_ZVKNED
            COP_AESZ, COP_AESEM, COP_AESEF,
            COP_AESDM, COP_AESDF:    comb_res = {128'b0, aes_enc_o};
            COP_AESKF1, COP_AESKF2:  comb_res = {128'b0, aes_kf_o};
`endif
`ifdef KARU_EN_ZVKNHA
`endif
`ifdef KARU_EN_ZVKSH
            COP_SM3ME:               comb_res = sm3_me_o;
`endif
            default:                 comb_res = 256'b0;
        endcase
    end
    //  ================= handshake FSM =================
    localparam [2:0]
        S_IDLE=3'd0, S_COMB=3'd1, S_GH=3'd2, S_SM4=3'd3,
        S_SHA2=3'd4, S_SM3=3'd5;
    reg [2:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
`ifdef KARU_EN_ZVKG
            gh_req <= 1'b0;
`endif
`ifdef KARU_EN_ZVKSED
            sm4_req <= 1'b0;
`endif
`ifdef KARU_EN_ZVKNHA
            sha2_req <= 1'b0;
`endif
`ifdef KARU_EN_ZVKSH
            sm3_req <= 1'b0;
`endif
        end else begin
            done   <= 1'b0;
`ifdef KARU_EN_ZVKG
            gh_req <= 1'b0;
`endif
`ifdef KARU_EN_ZVKSED
            sm4_req <= 1'b0;
`endif
`ifdef KARU_EN_ZVKNHA
            sha2_req <= 1'b0;
`endif
`ifdef KARU_EN_ZVKSH
            sm3_req <= 1'b0;
`endif
            case (state)
                S_IDLE: if (req && !busy) begin
                    cop_q <= cop; aux_q <= aux;
                    vd_q  <= egw_vd; vs1_q <= egw_vs1; vs2_q <= egw_vs2;
                    busy  <= 1'b1;
                    state <= S_COMB;
`ifdef KARU_EN_ZVKSED
                    if ((cop == COP_SM4R) || (cop == COP_SM4K)) begin
                        sm4_req <= 1'b1;
                        state   <= S_SM4;
                    end
`endif
`ifdef KARU_EN_ZVKNHA
                    if ((cop == COP_SHA2CH) || (cop == COP_SHA2CL) || (cop == COP_SHA2MS)) begin
                        sha2_req <= 1'b1;
                        state    <= S_SHA2;
                    end
`endif
`ifdef KARU_EN_ZVKSH
                    if (cop == COP_SM3C) begin
                        sm3_req <= 1'b1;
                        state   <= S_SM3;
                    end
`endif
`ifdef KARU_EN_ZVKG
                    if ((cop == COP_GHSH) || (cop == COP_GMUL)) begin
                        gh_req <= 1'b1;     //  karu_ghash latches on this pulse
                        state  <= S_GH;
                    end
`endif
                end
                S_COMB: begin
                    egw_res <= comb_res;    //  registered output
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end
`ifdef KARU_EN_ZVKG
                S_GH: if (gh_done) begin
                    egw_res <= {128'b0, gh_prod};
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end
`endif
`ifdef KARU_EN_ZVKSED
                S_SM4: if (sm4_done) begin
                    egw_res <= {128'b0, sm4_o};
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end
`endif
`ifdef KARU_EN_ZVKNHA
                S_SHA2: if (sha2_done) begin
                    egw_res <= sha2_o;
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end
`endif
`ifdef KARU_EN_ZVKSH
                S_SM3: if (sm3_done) begin
                    egw_res <= sm3_comp_o;
                    done    <= 1'b1;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end
`endif
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

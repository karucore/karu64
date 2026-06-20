//  karu_dec.v
//  Combinational decoder. Input: 32-bit instruction (already uncompressed
//  by karu_rvc64 upstream when applicable). Output: uop fields ready for
//  the issue stage.

`include "karu_uop_defs.vh"
`include "karu_fpkg.vh"

module karu_dec (
    input  wire [31:0]  ins,

    output reg  [3:0]   unit,
    output reg  [4:0]   sub,
    output reg  [4:0]   rd,
    output reg  [4:0]   rs1,
    output reg  [4:0]   rs2,
    output reg  [4:0]   rs3,        //  for FMA (FMADD/FMSUB/FNMSUB/FNMADD)
    output reg  [63:0]  imm,
    output reg  [1:0]   size,
    output reg          sign_l,
    output reg          use_imm,    //  op2 = imm (not rs2)
    output reg          use_pc,     //  op1 = pc (not rs1)
    output reg          is_w,       //  W-suffix arithmetic
    output reg  [11:0]  csr_addr,
    //  Per-source-and-dest "which regfile?" flags (1 = f-regfile)
    output reg          rs1_is_f,
    output reg          rs2_is_f,
    output reg          rs3_is_f,
    output reg          rd_is_f,
    output reg          fp_is_d,    //  1 = double-precision FP op; 0 = single
    output reg          is_h,       //  1 = Zfhmin half-precision op (FPU FP16 path)
    output reg  [3:0]   fp_zfa,     //  Zfa op selector (FPZ_*, 0 = not Zfa)
    output reg          vm,         //  vector mask bit (1 = unmasked); ins[25]
    output reg  [2:0]   vfunct3,    //  OP-V funct3 (forwarded to karu_vpu)
    output reg  [5:0]   vfunct6     //  OP-V funct6 = ins[31:26]
);
    wire [6:0]  op   = ins[6:0];
    wire [4:0]  opc  = ins[6:2];
    wire [4:0]  rd_w = ins[11:7];
    wire [2:0]  fn3  = ins[14:12];
    wire [4:0]  rs1_w= ins[19:15];
    wire [4:0]  rs2_w= ins[24:20];
    wire [4:0]  rs3_w= ins[31:27];  //  FMA third source
    wire [6:0]  fn7  = ins[31:25];
    wire [5:0]  fn6  = ins[31:26];  //  for RV64 SLLI/SRLI/SRAI
    wire [1:0]  fmt  = ins[26:25];  //  FP format: 00=S, 01=D, 10=H, 11=Q

    //  -- immediates --
    wire [63:0] imm_i = { {52{ins[31]}}, ins[31:20] };
    wire [63:0] imm_s = { {52{ins[31]}}, ins[31:25], ins[11:7] };
    wire [63:0] imm_b = { {52{ins[31]}}, ins[7], ins[30:25], ins[11:8], 1'b0 };
    wire [63:0] imm_u = { {32{ins[31]}}, ins[31:12], 12'b0 };
    wire [63:0] imm_j = { {44{ins[31]}}, ins[19:12], ins[20], ins[30:21], 1'b0 };
    //  5-bit zero-extended for CSR I-form (immediate is in rs1 field)
    wire [63:0] imm_csri = { 59'b0, rs1_w };

    always @(*) begin
        //  defaults
        unit        = `UNIT_NOP;
        sub         = 5'h00;
        rd          = rd_w;
        rs1         = rs1_w;
        rs2         = rs2_w;
        rs3         = rs3_w;
        imm         = 64'b0;
        size        = 2'b11;
        vm          = ins[25];      //  vector mask bit (consumed only by vector ops)
        vfunct3     = ins[14:12];
        vfunct6     = ins[31:26];
        sign_l      = 1'b0;
        use_imm     = 1'b0;
        use_pc      = 1'b0;
        is_w        = 1'b0;
        csr_addr    = ins[31:20];
        rs1_is_f    = 1'b0;
        rs2_is_f    = 1'b0;
        rs3_is_f    = 1'b0;
        rd_is_f     = 1'b0;
        fp_is_d     = 1'b0;
        is_h        = 1'b0;
        fp_zfa      = `FPZ_NONE;

        if (op[1:0] != 2'b11) begin
            unit = `UNIT_SYS;
            sub  = `SYS_TRAP;
        end else case (opc)
            5'b00000: begin                                     //  LOAD
                unit    = `UNIT_LSU;
                sub     = `LSU_LOAD;
                size    = fn3[1:0];
                sign_l  = ~fn3[2];  //  fn3[2]==1 -> unsigned
                imm     = imm_i;
                rs2     = 5'd0;     //  loads don't use rs2
            end

            5'b00011: begin                                     //  FENCE / FENCE.I / Zicbo
                if (fn3 == 3'b010) begin                        //  CBO (MISC-MEM fn3=010)
                    //  All CBO ops address the block containing rs1 and route
                    //  through the LSU so they translate + raise page/access
                    //  faults; on a write-through L1 the *data* effect of
                    //  clean/flush/inval is a NOP (block always coherent), so
                    //  those just translate + retire. cbo.zero actually zeroes.
                    //  Per-op privilege/envcfg gating is execute-time (karu64).
                    unit = `UNIT_LSU; rs1 = rs1_w; rs2 = 5'd0; rd = 5'd0;
                    imm = 64'd0; size = `LS_D;          //  addr = rs1 (no offset)
                    case (ins[31:20])
                        12'h000:  sub = `LSU_CBOINVAL;      //  cbo.inval (W permission)
                        12'h001:  sub = `LSU_CBOCF;         //  cbo.clean (R|W)
                        12'h002:  sub = `LSU_CBOCF;         //  cbo.flush (R|W)
                        12'h004:  sub = `LSU_CBOZERO;       //  cbo.zero  (W, real zero)
                        default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                    endcase
                end else begin
                    unit    = `UNIT_SYS;
                    sub     = (fn3 == 3'b001) ? `SYS_FENCEI : `SYS_FENCE;   //  FENCE.I flushes IFU
                    rd      = 5'd0;
                    rs1     = 5'd0;
                    rs2     = 5'd0;
                end
            end

            5'b00100: begin                                     //  OP-IMM
                unit    = `UNIT_ALU;
                use_imm = 1'b1;
                imm     = imm_i;
                rs2     = 5'd0;
                case (fn3)
                    3'b000: sub = `ALU_ADD;
                    3'b001: sub = `ALU_SLL;
                    3'b010: sub = `ALU_SLT;
                    3'b011: sub = `ALU_SLTU;
                    3'b100: sub = `ALU_XOR;
                    3'b101: sub = (fn6 == 6'b010000) ? `ALU_SRA : `ALU_SRL;
                    3'b110: sub = `ALU_OR;
                    3'b111: sub = `ALU_AND;
                endcase
                //  For shifts, use the 6-bit shamt as the second operand
                if (fn3 == 3'b001 || fn3 == 3'b101)
                    imm = { 58'b0, ins[25:20] };
            end

            5'b00101: begin                                     //  AUIPC
                unit    = `UNIT_ALU;
                sub     = `ALU_ADD;
                use_pc  = 1'b1;
                use_imm = 1'b1;
                imm     = imm_u;
                rs1     = 5'd0;
                rs2     = 5'd0;
            end

            5'b00110: begin                                     //  OP-IMM-32 (RV64)
                unit    = `UNIT_ALU;
                is_w    = 1'b1;
                use_imm = 1'b1;
                imm     = imm_i;
                rs2     = 5'd0;
                case (fn3)
                    3'b000: sub = `ALU_ADD;                             //  ADDIW
                    3'b001: sub = `ALU_SLL;                             //  SLLIW
                    3'b101: sub = (fn7 == 7'b0100000) ? `ALU_SRA :
                                                        `ALU_SRL;       //  SRAIW/SRLIW
                    default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                endcase
                if (fn3 == 3'b001 || fn3 == 3'b101)
                    imm = { 59'b0, ins[24:20] };    //  5-bit shamt for W ops
            end

            5'b01000: begin                                     //  STORE
                unit    = `UNIT_LSU;
                sub     = `LSU_STORE;
                size    = fn3[1:0];
                imm     = imm_s;
                rd      = 5'd0;
            end

            5'b00001: begin                                     //  LOAD-FP / vector load
                if (fn3 == 3'b010 || fn3 == 3'b011) begin       //  scalar FLW/FLD
                    unit    = `UNIT_LSU;    sub = `LSU_FLOAD;
                    imm     = imm_i;        rs2 = 5'd0;     rd_is_f = 1'b1;
                    size    = (fn3 == 3'b010) ? `LS_W : `LS_D;
                    fp_is_d = fn3[0];
                end else if (fn3 == 3'b001) begin               //  scalar FLH (Zfhmin)
                    unit    = `UNIT_LSU;    sub = `LSU_FLOAD;
                    imm     = imm_i;        rs2 = 5'd0;     rd_is_f = 1'b1;
                    size    = `LS_H;        is_h = 1'b1;
                end else begin                              //  vector load (unit/strided/indexed)
                    unit = `UNIT_VLSU;
                    rd = rd_w;  rs1 = rs1_w;    rs2 = rs2_w;    //  rs2 = stride (strided) / vs2 index (indexed)
                    size = (fn3 == 3'b000) ? 2'd0 :     //  EEW 8
                           (fn3 == 3'b101) ? 2'd1 :     //  EEW 16
                           (fn3 == 3'b110) ? 2'd2 : 2'd3;   //  EEW 32 / 64
                    case (ins[27:26])                       //  mop
                        2'b00: begin                        //  unit-stride family
                            rs2 = 5'd0;
                            if (ins[31:29] != 3'b000) begin //  nf>0 -> segment / whole-multi
                                if (ins[24:20] == 5'b00000 || ins[24:20] == 5'b10000) sub = `VLSU_VLSG; //  unit-seg
                                else if (ins[24:20] == 5'b01000) sub = `VLSU_VLR;   //  vl<nf>re
                                else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            end else case (ins[24:20])      //  lumop, nf=0
                                5'b00000: sub = `VLSU_VLE;  //  vle (unit-stride)
                                5'b10000: sub = `VLSU_VLE;  //  vle*ff (no faults here -> vle)
                                5'b01011: sub = `VLSU_VLM;  //  vlm.v (mask load)
                                5'b01000: sub = `VLSU_VLR;  //  vl1re*
                                default:  begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        2'b10: sub = `VLSU_VLSE;            //  strided  (addr = base + i*x[rs2])
                        default: sub = `VLSU_VLXE;          //  indexed  (01 unordered / 11 ordered)
                    endcase
                end
            end

            5'b01001: begin                                     //  STORE-FP / vector store
                if (fn3 == 3'b010 || fn3 == 3'b011) begin       //  scalar FSW/FSD
                    unit    = `UNIT_LSU;    sub = `LSU_FSTORE;
                    imm     = imm_s;        rd  = 5'd0;     rs2_is_f = 1'b1;
                    size    = (fn3 == 3'b010) ? `LS_W : `LS_D;
                    fp_is_d = fn3[0];
                end else if (fn3 == 3'b001) begin               //  scalar FSH (Zfhmin)
                    unit    = `UNIT_LSU;    sub = `LSU_FSTORE;
                    imm     = imm_s;        rd  = 5'd0;     rs2_is_f = 1'b1;
                    size    = `LS_H;        is_h = 1'b1;
                end else begin                              //  vector store (unit/strided/indexed)
                    unit = `UNIT_VLSU;
                    rd = rd_w;  rs1 = rs1_w;    rs2 = rs2_w;    //  rd field = vs3 (data); rs2 = stride/index
                    size = (fn3 == 3'b000) ? 2'd0 :
                           (fn3 == 3'b101) ? 2'd1 :
                           (fn3 == 3'b110) ? 2'd2 : 2'd3;
                    case (ins[27:26])                       //  mop
                        2'b00: begin                        //  unit-stride family
                            rs2 = 5'd0;
                            if (ins[31:29] != 3'b000) begin //  nf>0 -> segment / whole-multi
                                if (ins[24:20] == 5'b00000) sub = `VLSU_VSSG;       //  unit-seg
                                else if (ins[24:20] == 5'b01000) sub = `VLSU_VSR;   //  vs<nf>r
                                else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            end else case (ins[24:20])      //  sumop, nf=0
                                5'b00000: sub = `VLSU_VSE;  //  vse (unit-stride)
                                5'b01011: sub = `VLSU_VSM;  //  vsm.v (mask store)
                                5'b01000: sub = `VLSU_VSR;  //  vs1r.v
                                default:  begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        2'b10: sub = `VLSU_VSSE;            //  strided
                        default: sub = `VLSU_VSXE;          //  indexed (01 unordered / 11 ordered)
                    endcase
                end
            end

            5'b01011: begin                                     //  A-extension (AMO)
                unit = `UNIT_LSU;
                size = (fn3 == 3'b010) ? `LS_W : `LS_D;
                sign_l = 1'b1;  //  AMO/LR return sign-extended W result
                //  rs1 = base addr, rs2 = data (for SC/AMO; LR has rs2=0)
                if (fn3 != 3'b010 && fn3 != 3'b011) begin
                    unit = `UNIT_SYS; sub = `SYS_TRAP;
                end else begin
                    case (ins[31:27])
                        5'b00010: begin sub = `LSU_LR;       rs2 = 5'd0; end
                        5'b00011:       sub = `LSU_SC;
                        5'b00001:       sub = `LSU_AMOSWAP;
                        5'b00000:       sub = `LSU_AMOADD;
                        5'b00100:       sub = `LSU_AMOXOR;
                        5'b01100:       sub = `LSU_AMOAND;
                        5'b01000:       sub = `LSU_AMOOR;
                        5'b10000:       sub = `LSU_AMOMIN;
                        5'b10100:       sub = `LSU_AMOMAX;
                        5'b11000:       sub = `LSU_AMOMINU;
                        5'b11100:       sub = `LSU_AMOMAXU;
                        default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                    endcase
                end
            end

            5'b01100: begin                                     //  OP
                if (fn7 == 7'b0000001) begin                    //  RV64M
                    unit = `UNIT_M;
                    sub  = {2'b0, fn3};
                end else if (fn7 == 7'b0000111) begin           //  Zicond
                    unit = `UNIT_ALU;
                    case (fn3)
                        3'b101:  sub = `ALU_CZEQZ;  //  czero.eqz
                        3'b111:  sub = `ALU_CZNEZ;  //  czero.nez
                        default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                    endcase
                end else begin
                    unit    = `UNIT_ALU;
                    case (fn3)
                        3'b000: sub = (fn7 == 7'b0100000) ? `ALU_SUB : `ALU_ADD;
                        3'b001: sub = `ALU_SLL;
                        3'b010: sub = `ALU_SLT;
                        3'b011: sub = `ALU_SLTU;
                        3'b100: sub = `ALU_XOR;
                        3'b101: sub = (fn7 == 7'b0100000) ? `ALU_SRA : `ALU_SRL;
                        3'b110: sub = `ALU_OR;
                        3'b111: sub = `ALU_AND;
                    endcase
                end
            end

            5'b01101: begin                                     //  LUI
                unit    = `UNIT_ALU;
                sub     = `ALU_PASS;
                use_imm = 1'b1;
                imm     = imm_u;
                rs1     = 5'd0;
                rs2     = 5'd0;
            end

            5'b01110: begin                                     //  OP-32 (RV64)
                if (fn7 == 7'b0000001) begin                    //  RV64M *W
                    //  Only MULW/DIVW/DIVUW/REMW/REMUW are defined
                    //  (funct3 in {000, 100, 101, 110, 111}).
                    if (fn3 == 3'b000 || fn3[2]) begin
                        unit = `UNIT_M;
                        sub  = {2'b0, fn3};
                        is_w = 1'b1;
                    end else begin
                        unit = `UNIT_SYS;
                        sub  = `SYS_TRAP;
                    end
                end else begin
                    unit    = `UNIT_ALU;
                    is_w    = 1'b1;
                    case (fn3)
                        3'b000: sub = (fn7 == 7'b0100000) ? `ALU_SUB : `ALU_ADD;
                        3'b001: sub = `ALU_SLL;
                        3'b101: sub = (fn7 == 7'b0100000) ? `ALU_SRA : `ALU_SRL;
                        default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                    endcase
                end
            end

            //  ---- F/D-extension OP-FP ----
            5'b10100: begin                                     //  OP-FP
                unit = `UNIT_FPU;
                rd_is_f = 1'b1;                             //  default: rd is f-reg
                rs1_is_f = 1'b1;
                rs2_is_f = 1'b1;
                if (fmt == 2'b11) begin                     //  Q never supported
                    unit = `UNIT_SYS; sub = `SYS_TRAP;
                    rs1_is_f = 0; rs2_is_f = 0; rd_is_f = 0;
                end else if (fmt == 2'b10) begin            //  H dest: only Zfhmin ops
                    is_h = 1'b1;
                    case (ins[31:27])
                        5'b01000: begin                     //  FCVT.H.{S,D}: dest H, src = rs2_w
                            rs2 = 5'd0;
                            if (rs2_w == 5'd0)      begin sub = `FOP_CVT_TO_H; fp_is_d = 1'b0; end  //  fcvt.h.s
                            else if (rs2_w == 5'd1) begin sub = `FOP_CVT_TO_H; fp_is_d = 1'b1; end  //  fcvt.h.d
                            else begin unit = `UNIT_SYS; sub = `SYS_TRAP; rs1_is_f=0; rs2_is_f=0; rd_is_f=0; end
                        end
                        5'b11100: begin                     //  FMV.X.H (reuse MV_X_W; is_h selects half)
                            rd_is_f = 1'b0;
                            if (fn3 == 3'b000) sub = `FOP_MV_X_W;
                            else begin unit = `UNIT_SYS; sub = `SYS_TRAP; rs1_is_f=0; rs2_is_f=0; rd_is_f=0; end
                        end
                        5'b11110: begin                     //  FMV.H.X (reuse MV_W_X)
                            rs1_is_f = 1'b0; rs2_is_f = 1'b0;
                            if (fn3 == 3'b000) sub = `FOP_MV_W_X;
                            else begin unit = `UNIT_SYS; sub = `SYS_TRAP; rs1_is_f=0; rs2_is_f=0; rd_is_f=0; end
                        end
                        default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; rs1_is_f=0; rs2_is_f=0; rd_is_f=0; end
                    endcase
                end else begin
                    fp_is_d = fmt[0];                       //  0=single, 1=double
                    case (ins[31:27])
                        5'b00000: sub = `FOP_ADD;
                        5'b00001: sub = `FOP_SUB;
                        5'b00010: sub = `FOP_MUL;
                        5'b00011: sub = `FOP_DIV;
                        5'b01011: begin sub = `FOP_SQRT; rs2 = 5'd0; end
                        5'b00100: begin                         //  FSGNJ family
                            case (fn3)
                                3'b000:  sub = `FOP_SGNJ;
                                3'b001:  sub = `FOP_SGNJN;
                                3'b010:  sub = `FOP_SGNJX;
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        5'b00101: begin                         //  FMIN/FMAX
                            case (fn3)
                                3'b000:  sub = `FOP_MIN;
                                3'b001:  sub = `FOP_MAX;
                                3'b010:  begin sub = `FOP_MIN; fp_zfa = `FPZ_FMINM; end //  fminm (Zfa)
                                3'b011:  begin sub = `FOP_MAX; fp_zfa = `FPZ_FMAXM; end //  fmaxm (Zfa)
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        5'b10100: begin                         //  FCMP
                            rd_is_f = 1'b0;                 //  rd is int
                            case (fn3)
                                3'b010:  sub = `FOP_EQ;
                                3'b001:  sub = `FOP_LT;
                                3'b000:  sub = `FOP_LE;
                                3'b100:  begin sub = `FOP_LE; fp_zfa = `FPZ_FLEQ; end   //  fleq (Zfa)
                                3'b101:  begin sub = `FOP_LT; fp_zfa = `FPZ_FLTQ; end   //  fltq (Zfa)
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        5'b11000: begin                         //  FCVT.int.{S,D}
                            rd_is_f = 1'b0;
                            case (rs2_w)
                                5'd0: sub = `FOP_CVT_W_S;   //  FCVT.W.{S,D}
                                5'd1: sub = `FOP_CVT_WU_S;  //  FCVT.WU.{S,D}
                                5'd2: sub = `FOP_CVT_L_S;   //  FCVT.L.{S,D}
                                5'd3: sub = `FOP_CVT_LU_S;  //  FCVT.LU.{S,D}
                                5'd8: begin             //  fcvtmod.w.d (Zfa): D source, rtz only
                                    if (fmt == 2'b01 && fn3 == 3'b001) begin sub = `FOP_ADD; fp_zfa = `FPZ_FCVTMOD; end
                                    else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                                end
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        5'b11010: begin                         //  FCVT.{S,D}.int
                            rs1_is_f = 1'b0;                //  rs1 is int
                            rs2_is_f = 1'b0;
                            case (rs2_w)
                                5'd0: sub = `FOP_CVT_S_W;   //  FCVT.{S,D}.W
                                5'd1: sub = `FOP_CVT_S_WU;  //  FCVT.{S,D}.WU
                                5'd2: sub = `FOP_CVT_S_L;   //  FCVT.{S,D}.L
                                5'd3: sub = `FOP_CVT_S_LU;  //  FCVT.{S,D}.LU
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        5'b01000: begin                         //  FCVT.{S,D}.{S,D,H}
                            //  Cross-precision: target fmt = fmt[1:0],
                            //  source fmt = rs2_w[1:0].
                            rs2 = 5'd0;
                            if (fmt == 2'b00 && rs2_w == 5'd1)
                                sub = `FOP_CVT_S_D;         //  source D, target S
                            else if (fmt == 2'b01 && rs2_w == 5'd0)
                                sub = `FOP_CVT_D_S;         //  source S, target D
                            else if (rs2_w == 5'd2) begin   //  source H -> fcvt.s.h / fcvt.d.h
                                sub = `FOP_CVT_FROM_H;      //  fp_is_d (=fmt[0]) picks S/D dest
                                is_h = 1'b1;
                            end else if (rs2_w == 5'd4) begin   sub = `FOP_ADD; fp_zfa = `FPZ_FROUND; end   //  fround (Zfa)
                            else if (rs2_w == 5'd5) begin   sub = `FOP_ADD; fp_zfa = `FPZ_FROUNDNX; end //  froundnx
                            else begin
                                unit = `UNIT_SYS; sub = `SYS_TRAP;
                                rs1_is_f = 0; rs2_is_f = 0; rd_is_f = 0;
                            end
                        end
                        5'b11100: begin                         //  FMV.X.{W,D} / FCLASS.{S,D}
                            rd_is_f = 1'b0;
                            if (fn3 == 3'b000)      sub = `FOP_MV_X_W;
                            else if (fn3 == 3'b001) sub = `FOP_CLASS;
                            else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                        end
                        5'b11110: begin                         //  FMV.{W,D}.X / fli (Zfa)
                            rs1_is_f = 1'b0;
                            rs2_is_f = 1'b0;
                            if (fn3 == 3'b000 && rs2_w == 5'd0) sub = `FOP_MV_W_X;
                            else if (fn3 == 3'b000 && rs2_w == 5'd1) begin  //  fli: index=rs1 field, dest f-reg
                                sub = `FOP_ADD; fp_zfa = `FPZ_FLI; rd_is_f = 1'b1;
                                rs1 = 5'd0; imm = { 59'b0, rs1_w };
                            end
                            else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                        end
                        default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                    endcase
                end
            end

            //  ---- F/D-extension FMA family ----
            5'b10000, 5'b10001, 5'b10010, 5'b10011: begin       //  MADD/MSUB/NMSUB/NMADD
                unit = `UNIT_FPU;
                rs1_is_f = 1'b1; rs2_is_f = 1'b1; rs3_is_f = 1'b1; rd_is_f = 1'b1;
                if (fmt[1] || fmt == 2'b10) begin               //  H/Q not supported
                    unit = `UNIT_SYS; sub = `SYS_TRAP;
                    rs1_is_f = 0; rs2_is_f = 0; rs3_is_f = 0; rd_is_f = 0;
                end else begin
                    fp_is_d = fmt[0];
                    case (opc)
                        5'b10000: sub = `FOP_MADD;
                        5'b10001: sub = `FOP_MSUB;
                        5'b10010: sub = `FOP_NMSUB;
                        5'b10011: sub = `FOP_NMADD;
                    endcase
                end
            end

            //  ---- V-extension OP-V (vset* and vector arithmetic) ----
            5'b10101: begin                                     //  OP-V
                if (fn3 == 3'b111) begin                        //  OPCFG: vset*
                    unit = `UNIT_VCFG;
                    rd   = rd_w;    rs1 = rs1_w;    rs2 = rs2_w;
                    if (ins[31] == 1'b0) begin                  //  vsetvli
                        sub = `VCFG_SETVLI;
                        imm = { 53'b0, ins[30:20] };            //  vtype zimm[10:0]
                    end else if (ins[31:30] == 2'b11) begin     //  vsetivli
                        sub = `VCFG_SETIVLI;
                        imm = { 54'b0, ins[29:20] };            //  vtype zimm[9:0]
                    end else if (ins[31:25] == 7'b1000000) begin // vsetvl
                        sub = `VCFG_SETVL;
                    end else begin
                        unit = `UNIT_SYS; sub = `SYS_TRAP;
                    end
                end else if (fn3 == 3'b001 || fn3 == 3'b101) begin  //  OPFVV / OPFVF
                    //  Vector floating-point -> karu_vfpu (decodes funct6).
                    //  .vf (fn3=101): scalar operand is f[rs1].
                    rd = rd_w;  rs1 = rs1_w;    rs2 = rs2_w;
                    if (fn3 == 3'b101) rs1_is_f = 1'b1;
                    //  vfmv.f.s writes a scalar f-register (f[rd]).
                    if (fn3 == 3'b001 && fn7[6:1] == 6'b010000 && ins[19:15] == 5'b00000) rd_is_f = 1'b1;
                    if ( fn7[6:1] == 6'b000000 ||                       //  vfadd
                         fn7[6:1] == 6'b000010 ||                       //  vfsub
                         fn7[6:1] == 6'b000100 ||                       //  vfmin
                         fn7[6:1] == 6'b000110 ||                       //  vfmax
                         fn7[6:1] == 6'b001000 ||                       //  vfsgnj
                         fn7[6:1] == 6'b001001 ||                       //  vfsgnjn
                         fn7[6:1] == 6'b001010 ||                       //  vfsgnjx
                         (fn3 == 3'b101 && fn7[6:1] == 6'b010111) ||    //  vfmerge.vfm / vfmv.v.f
                         fn7[6:1] == 6'b011000 ||                       //  vmfeq
                         fn7[6:1] == 6'b011001 ||                       //  vmfle
                         fn7[6:1] == 6'b011011 ||                       //  vmflt
                         fn7[6:1] == 6'b011100 ||                       //  vmfne
                         (fn3 == 3'b101 && fn7[6:1] == 6'b011101) ||    //  vmfgt.vf
                         (fn3 == 3'b101 && fn7[6:1] == 6'b011111) ||    //  vmfge.vf
                         fn7[6:1] == 6'b100000 ||                       //  vfdiv
                         (fn3 == 3'b101 && fn7[6:1] == 6'b100001) ||    //  vfrdiv.vf
                         fn7[6:1] == 6'b100100 ||                       //  vfmul
                         (fn3 == 3'b101 && fn7[6:1] == 6'b100111) ||    //  vfrsub.vf
                         fn7[6:4] == 3'b101 ||                          //  FMA 101xxx (vf{,n}m{acc,sac,add,sub})
                         (fn3 == 3'b001 && fn7[6:1] == 6'b010011 &&     //  VFUNARY1: vfsqrt(0)/vfrsqrt7(00100)/vfrec7(00101)/vfclass(10000)
                            (ins[19:15] == 5'b00000 || ins[19:15] == 5'b00100 ||
                             ins[19:15] == 5'b00101 || ins[19:15] == 5'b10000)) ||
                         (fn3 == 3'b001 && fn7[6:1] == 6'b010010 && ins[19:18] != 2'b11) || //  vfcvt/vfwcvt/vfncvt (VFUNARY0, incl. rod.f.f)
                         (fn3 == 3'b001 && fn7[6:1] == 6'b010000 && ins[19:15] == 5'b00000) ||  //  vfmv.f.s (VWFUNARY0)
                         (fn3 == 3'b101 && fn7[6:1] == 6'b010000 && ins[24:20] == 5'b00000) ||  //  vfmv.s.f (VRFUNARY0)
                         (fn3 == 3'b001 && (fn7[6:1] == 6'b000001 || fn7[6:1] == 6'b000011  //  vfredusum/osum
                                         || fn7[6:1] == 6'b000101 || fn7[6:1] == 6'b000111)) || //  vfredmin/max
                         (fn3 == 3'b101 && (fn7[6:1] == 6'b001110 || fn7[6:1] == 6'b001111)) || //  vfslide1up/down.vf
                         fn7[6:1] == 6'b110000 || fn7[6:1] == 6'b110010 ||  //  vfwadd/vfwsub .vv/.vf  (F->D widen)
                         fn7[6:1] == 6'b110100 || fn7[6:1] == 6'b110110 ||  //  vfwadd.w/vfwsub.w
                         fn7[6:1] == 6'b111000 ||                           //  vfwmul .vv/.vf
                         fn7[6:3] == 4'b1111 ||                             //  vfwmacc/nmacc/msac/nmsac (1111xx)
                         (fn3 == 3'b001 && (fn7[6:1] == 6'b110001 || fn7[6:1] == 6'b110011)) )  //  vfwredusum/osum (OPFVV)
                        unit = `UNIT_VFPU;
                    else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                end else begin                              //  OPI*/OPM* vector arith
                    //  Forward funct6/funct3 to karu_vpu (it decodes); whitelist
                    //  the Stage-1 implemented ops here so the rest still trap.
                    //  fn3: 000 OPIVV, 100 OPIVX, 011 OPIVI, 010 OPMVV, 110 OPMVX.
                    rd = rd_w;  rs1 = rs1_w;    rs2 = rs2_w;
                    if (fn3 == 3'b011) imm = { {59{ins[19]}}, ins[19:15] }; //  simm5 (.vi)
                    if ( ( (fn3 == 3'b000 || fn3 == 3'b100 || fn3 == 3'b011) && //  OPIV*
                           ( fn7[6:1] == 6'b000000 || fn7[6:1] == 6'b000010 ||  //  add sub
                             fn7[6:1] == 6'b000011 ||                           //  rsub
                             fn7[6:1] == 6'b001001 || fn7[6:1] == 6'b001010 ||  //  and or
                             fn7[6:1] == 6'b001011 ||                           //  xor
                             fn7[6:1] == 6'b100101 || fn7[6:1] == 6'b101000 ||  //  sll srl
                             fn7[6:1] == 6'b101001 ||                           //  sra
                             fn7[6:1] == 6'b000100 || fn7[6:1] == 6'b000101 ||  //  minu min
                             fn7[6:1] == 6'b000110 || fn7[6:1] == 6'b000111 ||  //  maxu max
                             fn7[6:4] == 3'b011 ||                              //  compares
                             fn7[6:3] == 4'b0100 ||                             //  vadc/vmadc/vsbc/vmsbc (0100xx)
                             fn7[6:3] == 4'b1000 ||                             //  vsaddu/vsadd/vssubu/vssub (1000xx)
                             fn7[6:2] == 5'b10101 ||                            //  vssrl/vssra (10101x)
                             fn7[6:2] == 5'b10110 || fn7[6:2] == 5'b10111 ||    //  vnsrl/vnsra/vnclipu/vnclip (1011xx)
                             (fn3 == 3'b000 && fn7[6:2] == 5'b11000) ||         //  vwredsumu/vwredsum (OPIVV 11000x)
                             ((fn3 == 3'b000 || fn3 == 3'b100) && fn7[6:1] == 6'b100111) || //  vsmul.vv/.vx
                             fn7[6:1] == 6'b010111 ||                           //  vmv.v.*/vmerge
                             (fn3 == 3'b011 && fn7[6:1] == 6'b100111) ||        //  vmv<nr>r.v
                             fn7[6:1] == 6'b001100 ||                           //  vrgather.v{v,x,i}
                             (fn3 == 3'b000 && fn7[6:1] == 6'b001110) ||        //  vrgatherei16.vv
                             ((fn3 == 3'b100 || fn3 == 3'b011) &&               //  vslideup/down.v{x,i}
                                (fn7[6:1] == 6'b001110 || fn7[6:1] == 6'b001111)) ) )
                      || ( (fn3 == 3'b010 || fn3 == 3'b110) &&                  //  OPMV*
                           ( (fn3 == 3'b010 && fn7[6:4] == 3'b000) ||           //  vredsum/and/or/xor/minu/min/maxu/max (OPMVV 0000xx)
                             fn7[6:3] == 4'b1001 ||                         //  mul/mulh/mulhu/mulhsu (1001xx)
                             fn7[6:3] == 4'b1000 ||                         //  vdivu/vdiv/vremu/vrem (1000xx)
                             fn7[6:5] == 2'b11 ||                               //  widening vw* (funct6 11xxxx)
                             fn7[6:3] == 4'b0010 ||                         //  vaaddu/vaadd/vasubu/vasub (0010xx)
                             (fn7[6:4] == 3'b101 && fn7[1]) ||                  //  vmadd/vnmsub/vmacc/vnmsac (101xx1)
                             (fn3 == 3'b010 && fn7[6:4] == 3'b011) ||           //  mask logic
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010000 && ins[19:15] == 5'b10001) ||  //  vfirst.m
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010000 && ins[19:15] == 5'b00000) ||  //  vmv.x.s
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010000 && ins[19:15] == 5'b10000) ||  //  vcpop.m
                             (fn3 == 3'b110 && fn7[6:1] == 6'b010000 && ins[24:20] == 5'b00000) ||  //  vmv.s.x (vs2=selector)
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010100 && ins[19:15] == 5'b10001) ||  //  vid
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010100 && ins[19:15] == 5'b00001) ||  //  vmsbf.m
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010100 && ins[19:15] == 5'b00010) ||  //  vmsof.m
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010100 && ins[19:15] == 5'b00011) ||  //  vmsif.m
                             (fn3 == 3'b110 && (fn7[6:1] == 6'b001110 || fn7[6:1] == 6'b001111)) || //  vslide1up/down.vx
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010111) ||        //  vcompress.vm
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010010 && ins[19:18] == 2'b00 && ins[17:16] != 2'b00) ||  //  vsext/vzext.vf{2,4,8}
                             (fn3 == 3'b010 && fn7[6:1] == 6'b010100 && ins[19:15] == 5'b10000) ) ) //  viota.m
`ifdef KARU_EN_ZVKB
                          //    Zvkb: vandn/vrol/vror element ops + the VXUNARY0
                          //    byte/bit reversals (vs1 selectors 01000/01001).
                          //    vror.vi carries uimm[5] in funct6[0] (01010x).
                          || ( (fn3 == 3'b000 || fn3 == 3'b100) &&
                               ( fn7[6:1] == 6'b000001 ||                       //  vandn.vv/.vx
                                 fn7[6:1] == 6'b010101 ||                       //  vrol.vv/.vx
                                 fn7[6:1] == 6'b010100 ) )                      //  vror.vv/.vx
                          || (fn3 == 3'b011 && fn7[6:2] == 5'b01010)            //  vror.vi
                          || ( fn3 == 3'b010 && fn7[6:1] == 6'b010010 &&
                               (ins[19:15] == 5'b01000 || ins[19:15] == 5'b01001) ) //  vbrev8/vrev8
`endif
                           )
                        unit = `UNIT_VARITH;
                    else begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                end
            end

            5'b11000: begin                                     //  BRANCH
                unit    = `UNIT_BRU;
                sub     = {1'b0, fn3};
                imm     = imm_b;
                rd      = 5'd0;
            end

            5'b11001: begin                                     //  JALR
                unit    = `UNIT_BRU;
                sub     = `BRU_JALR;
                imm     = imm_i;
                rs2     = 5'd0;
            end

            5'b11011: begin                                     //  JAL
                unit    = `UNIT_BRU;
                sub     = `BRU_JAL;
                imm     = imm_j;
                rs1     = 5'd0;
                rs2     = 5'd0;
            end

            5'b11100: begin                                     //  SYSTEM
                if (fn3 == 3'b000) begin
                    unit = `UNIT_SYS;
                    rd   = 5'd0; rs1 = 5'd0; rs2 = 5'd0;
                    //  SFENCE.VMA is funct7=0001001 with rs1(vaddr)/rs2(asid)
                    //  OPERANDS, so it must be matched on funct7 -- not the full
                    //  funct12. The old `12'h120` only matched the rs2==0 flush-all
                    //  form; Linux issues ASID/VA-targeted sfence.vma (rs2!=0) at
                    //  context switch, which fell through to SYS_TRAP and halted
                    //  the core at the userspace transition. karu's MMU flushes the
                    //  whole TLB on any sfence.vma, so rs1/rs2 stay unused (0).
                    case (ins[31:20])
                        12'h000: sub = `SYS_ECALL;
                        12'h001: sub = `SYS_EBREAK;
                        12'h102: sub = `SYS_SRET;
                        12'h302: sub = `SYS_MRET;
                        12'h105: sub = `SYS_WFI;
                        //  Zawrs: WRS.NTO (0x00d) / WRS.STO (0x01d). On this
                        //  single-hart core a reservation set is never stolen, so
                        //  the spec permits the wait to terminate immediately --
                        //  implement as a retiring NOP (FENCE is the core's NOP).
                        12'h00d, 12'h01d: sub = `SYS_FENCE;
                        default: sub = (ins[31:25] == 7'b0001001)
                                           ? `SYS_SFENCEVMA : `SYS_TRAP;
                    endcase
                end else if (fn3 == 3'b100) begin
                    //  Zimop: MOP.R.N (mask 0xb3c0707f==0x81c04073) and MOP.RR.N
                    //  (0xb200707f==0x82004073) are "may-be-operations" that, until
                    //  some extension repurposes them, write 0 to rd. Realise as
                    //  ALU add x0,x0 -> rd. (funct3=100 SYSTEM is otherwise unused
                    //  here -- no H-extension HLV/HSV.)
                    if (((ins & 32'hb3c0_707f) == 32'h81c0_4073) ||
                        ((ins & 32'hb200_707f) == 32'h8200_4073)) begin
                        unit = `UNIT_ALU; sub = `ALU_ADD;
                        rs1 = 5'd0; rs2 = 5'd0; use_imm = 1'b0; rd = rd_w;
                    end else begin
                        unit = `UNIT_SYS; sub = `SYS_TRAP;
                    end
                end else begin
                    unit    = `UNIT_CSR;
                    sub     = {2'b0, fn3};  //  matches CSR_RW/RS/RC/RWI/RSI/RCI
                    rs2     = 5'd0;
                    if (fn3[2]) begin       //  I-form: rs1 field is uimm[4:0]
                        imm     = imm_csri;
                        use_imm = 1'b1;     //  op2 source is the immediate
                    end
                end
            end

            //  ---- OP-VE (0x77): standard Zvk and experimental vkeccak ----
            //  Standard vector crypto (Zvk*, spec Ch. 30.4) also lives under
            //  OP-VE. Keccak is separate from that table (spec Ch. 31), but this
            //  core implements the older keccak-xrv full-permutation custom op, so
            //  match its full `.insn r 0x77,0x2,0x53` template rather than every
            //  funct6=101001 encoding. Otherwise standard VAES.vs forms alias as
            //  Keccak.
            5'b11101: begin
                unit = `UNIT_SYS;
                sub  = `SYS_TRAP;
`ifdef KARU_EN_ZVK
                if (fn3 == 3'b010 && ins[25]) begin
                    rd = rd_w; rs1 = rs1_w; rs2 = rs2_w;
                    case (fn7[6:1])
                        6'b100000: begin                        //  vsm3me.vv
`ifdef KARU_EN_ZVKSH
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SM3ME; //  vd, vs2, vs1 -- vs1 is a real operand, not a subopcode
`endif
                        end
                        6'b100001: begin                        //  vsm4k.vi
`ifdef KARU_EN_ZVKSED
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SM4K;
                            imm = { 59'b0, rs1_w };
`endif
                        end
                        6'b100010: begin                        //  vaeskf1.vi
`ifdef KARU_EN_ZVKNED
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESKF1;
                            imm = { 59'b0, rs1_w };
`endif
                        end
                        6'b101000: begin                        //  VAES.vv / vsm4r.vv / vgmul.vv
                            case (rs1_w)
`ifdef KARU_EN_ZVKNED
                                5'd0:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESDM;  end
                                5'd1:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESDF;  end
                                5'd2:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESEM;  end
                                5'd3:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESEF;  end
`endif
`ifdef KARU_EN_ZVKSED
                                5'd16: begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SM4R;   end
`endif
`ifdef KARU_EN_ZVKG
                                5'd17: begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_GMUL;   end
`endif
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        6'b101001: begin                        //  VAES.vs / vsm4r.vs / vaesz.vs
                            case (rs1_w)
`ifdef KARU_EN_ZVKNED
                                5'd0:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESDM;  end
                                5'd1:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESDF;  end
                                5'd2:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESEM;  end
                                5'd3:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESEF;  end
                                5'd7:  begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESZ;   end
`endif
`ifdef KARU_EN_ZVKSED
                                5'd16: begin unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SM4R;   end
`endif
                                default: begin unit = `UNIT_SYS; sub = `SYS_TRAP; end
                            endcase
                        end
                        6'b101010: begin                        //  vaeskf2.vi
`ifdef KARU_EN_ZVKNED
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_AESKF2;
                            imm = { 59'b0, rs1_w };
`endif
                        end
                        6'b101011: begin                        //  vsm3c.vi
`ifdef KARU_EN_ZVKSH
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SM3C;
                            imm = { 59'b0, rs1_w };
`endif
                        end
                        6'b101100: begin                        //  vghsh.vv
`ifdef KARU_EN_ZVKG
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_GHSH;  //  vd, vs2, vs1 -- vs1 is a real operand, not a subopcode
`endif
                        end
                        6'b101101: begin                        //  vsha2ms.vv
`ifdef KARU_EN_ZVKNHA
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SHA2MS;    //  vd, vs2, vs1 -- vs1 is a real operand, not a subopcode
`endif
                        end
                        6'b101110: begin                        //  vsha2ch.vv
`ifdef KARU_EN_ZVKNHA
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SHA2CH;    //  vd, vs2, vs1 -- vs1 is a real operand, not a subopcode
`endif
                        end
                        6'b101111: begin                        //  vsha2cl.vv
`ifdef KARU_EN_ZVKNHA
                            unit = `UNIT_VCRYPTO; sub = `VCRYPTO_SHA2CL;    //  vd, vs2, vs1 -- vs1 is a real operand, not a subopcode
`endif
                        end
                        default: begin end
                    endcase
                end
`endif
`ifdef KARU_EN_KECCAK
                if (fn3 == 3'b010 && fn7 == 7'b1010011 &&
                    rs1_w == 5'd17 && rs2_w == 5'd24) begin
                    unit = `UNIT_VKECCAK;
                    rd   = rd_w;                //  vd group base (m8, e64)
                    sub  = 5'd0;
                end
`endif
            end

            default: begin
                unit = `UNIT_SYS;
                sub  = `SYS_TRAP;
            end
        endcase

        //  ================================================================
        //  Scalar bit-manipulation (Zba/Zbb/Zbs) post-pass.
        //  The base decode above ignores funct7 for several funct3 values, so
        //  these encodings are detected here and OVERRIDE unit/sub. Their
        //  funct7/funct6 values don't collide with any base RV64 op (verified).
        //  CRITICAL: only WRITE the decode outputs when bm_hit -- otherwise the
        //  base decode for non-bitmanip ops in these opcode groups (addi/addiw/
        //  shifts) is left intact.
        begin : bm_decode
            reg        bm_hit, bm_isw, bm_imm6, bm_imm5;
            reg [4:0]  bm_sub;
            bm_hit = 1'b0; bm_isw = 1'b0; bm_imm6 = 1'b0; bm_imm5 = 1'b0; bm_sub = 5'd0;
            case (ins[6:2])
            5'b01100: begin                     //  OP (R-type) -- all use rs2, no imm
                bm_hit = 1'b1;
                case ({fn7, fn3})
                {7'b0010000, 3'b010}: bm_sub = `BM_SH1ADD;
                {7'b0010000, 3'b100}: bm_sub = `BM_SH2ADD;
                {7'b0010000, 3'b110}: bm_sub = `BM_SH3ADD;
                {7'b0100000, 3'b111}: bm_sub = `BM_ANDN;
                {7'b0100000, 3'b110}: bm_sub = `BM_ORN;
                {7'b0100000, 3'b100}: bm_sub = `BM_XNOR;
                {7'b0000101, 3'b110}: bm_sub = `BM_MAX;
                {7'b0000101, 3'b111}: bm_sub = `BM_MAXU;
                {7'b0000101, 3'b100}: bm_sub = `BM_MIN;
                {7'b0000101, 3'b101}: bm_sub = `BM_MINU;
                {7'b0110000, 3'b001}: bm_sub = `BM_ROL;
                {7'b0110000, 3'b101}: bm_sub = `BM_ROR;
                {7'b0100100, 3'b001}: bm_sub = `BM_BCLR;
                {7'b0100100, 3'b101}: bm_sub = `BM_BEXT;
                {7'b0110100, 3'b001}: bm_sub = `BM_BINV;
                {7'b0010100, 3'b001}: bm_sub = `BM_BSET;
                default: bm_hit = 1'b0;
                endcase
            end
            5'b01110: begin                     //  OP-32 (W) -- all use rs2, no imm
                bm_hit = 1'b1;
                case ({fn7, fn3})
                {7'b0000100, 3'b000}: bm_sub = `BM_ADDUW;
                {7'b0010000, 3'b010}: bm_sub = `BM_SH1ADDUW;
                {7'b0010000, 3'b100}: bm_sub = `BM_SH2ADDUW;
                {7'b0010000, 3'b110}: bm_sub = `BM_SH3ADDUW;
                {7'b0110000, 3'b001}: begin bm_sub = `BM_ROL; bm_isw = 1'b1; end    //  rolw
                {7'b0110000, 3'b101}: begin bm_sub = `BM_ROR; bm_isw = 1'b1; end    //  rorw
                default: bm_hit = 1'b0;
                endcase
                if (!bm_hit && fn7 == 7'b0000100 && fn3 == 3'b100 && rs2_w == 5'd0) begin
                    bm_sub = `BM_ZEXTH; bm_hit = 1'b1;      //  zext.h
                end
            end
            5'b00100: begin                     //  OP-IMM
                bm_hit = 1'b1;
                if (fn3 == 3'b001 && ins[31:26] == 6'b011000) begin //  clz/ctz/cpop/sext.b/.h
                    case (rs2_w)
                    5'b00000: bm_sub = `BM_CLZ;
                    5'b00001: bm_sub = `BM_CTZ;
                    5'b00010: bm_sub = `BM_CPOP;
                    5'b00100: bm_sub = `BM_SEXTB;
                    5'b00101: bm_sub = `BM_SEXTH;
                    default:  bm_hit = 1'b0;
                    endcase
                end
                else if (fn3 == 3'b001 && ins[31:26] == 6'b010010) begin bm_sub = `BM_BCLR; bm_imm6 = 1'b1; end
                else if (fn3 == 3'b001 && ins[31:26] == 6'b011010) begin bm_sub = `BM_BINV; bm_imm6 = 1'b1; end
                else if (fn3 == 3'b001 && ins[31:26] == 6'b001010) begin bm_sub = `BM_BSET; bm_imm6 = 1'b1; end
                else if (fn3 == 3'b101 && ins[31:26] == 6'b011000) begin bm_sub = `BM_ROR;  bm_imm6 = 1'b1; end //  rori
                else if (fn3 == 3'b101 && ins[31:26] == 6'b010010) begin bm_sub = `BM_BEXT; bm_imm6 = 1'b1; end //  bexti
                else if (fn3 == 3'b101 && ins[31:20] == 12'b001010000111) bm_sub = `BM_ORCB;
                else if (fn3 == 3'b101 && ins[31:20] == 12'b011010111000) bm_sub = `BM_REV8;
                else bm_hit = 1'b0;
            end
            5'b00110: begin                     //  OP-IMM-32 (W)
                bm_hit = 1'b1;
                if (fn3 == 3'b001 && ins[31:26] == 6'b011000) begin //  clzw/ctzw/cpopw
                    bm_isw = 1'b1;
                    case (rs2_w)
                    5'b00000: bm_sub = `BM_CLZ;
                    5'b00001: bm_sub = `BM_CTZ;
                    5'b00010: bm_sub = `BM_CPOP;
                    default:  begin bm_hit = 1'b0; bm_isw = 1'b0; end
                    endcase
                end
                else if (fn3 == 3'b001 && ins[31:26] == 6'b000010) begin bm_sub = `BM_SLLIUW; bm_imm6 = 1'b1; end
                else if (fn3 == 3'b101 && fn7 == 7'b0110000) begin bm_sub = `BM_ROR; bm_isw = 1'b1; bm_imm5 = 1'b1; end //  roriw
                else bm_hit = 1'b0;
            end
            default: ;
            endcase

            //  apply -- ONLY when a bitmanip op was matched
            if (bm_hit) begin
`ifdef KARU_EN_B
                unit    = `UNIT_BITMANIP;
                sub     = bm_sub;
                is_w    = bm_isw;
                rd      = rd_w;
                rs1     = rs1_w;
                use_imm = bm_imm6 || bm_imm5;
                //  R-type bitmanip uses rs2; immediate forms take the shamt as
                //  op2 (and read no rs2); unary forms read no rs2.
                if (bm_imm6)      begin rs2 = 5'd0; imm = { 58'b0, ins[25:20] }; end
                else if (bm_imm5) begin rs2 = 5'd0; imm = { 59'b0, ins[24:20] }; end
                else if (ins[6:2] == 5'b01100 || ins[6:2] == 5'b01110)
                    //  R-type: andn/sh*add/min/max/rol/... read rs2; .uw/zext/rolw too
                    rs2 = (bm_sub == `BM_ZEXTH || bm_sub == `BM_CLZ ||
                           bm_sub == `BM_CTZ   || bm_sub == `BM_CPOP) ? 5'd0 : rs2_w;
                else
                    rs2 = 5'd0; //  OP-IMM/OP-IMM-32 unary (clz/sext/orc.b/rev8)
`else
                unit    = `UNIT_SYS;
                sub     = `SYS_TRAP;
                rd      = 5'd0;
                rs1     = 5'd0;
                rs2     = 5'd0;
                use_imm = 1'b0;
`endif
            end
        end

        //  ---- build-time ISA-extension gating (see karu_ext.vh) ----
        //  When an extension is compiled out, downgrade its instructions to
        //  an illegal-instruction trap so the core never issues to a unit
        //  that is not present. A/M are independent; the F/D/V/K dependency
        //  cascade (K>V>D>F) is resolved in the header.
`ifndef KARU_EN_A
        //  No A: trap LR/SC/AMO while leaving normal loads/stores intact.
        if (unit == `UNIT_LSU && sub >= `LSU_LR && sub <= `LSU_AMOMAXU) begin
            unit = `UNIT_SYS;   sub = `SYS_TRAP;
        end
`endif
`ifndef KARU_EN_M
        //  No M: trap multiply/divide instructions.
        if (unit == `UNIT_M) begin
            unit = `UNIT_SYS;   sub = `SYS_TRAP;
        end
`endif
`ifndef KARU_EN_F
        //  No F: trap every FPU op, every scalar FP load/store, and FP CSRs.
        if (unit == `UNIT_FPU ||
            (unit == `UNIT_CSR && csr_addr >= 12'h001 && csr_addr <= 12'h003) ||
            (unit == `UNIT_LSU && (sub == `LSU_FLOAD || sub == `LSU_FSTORE)))
        begin
            unit = `UNIT_SYS;   sub = `SYS_TRAP;
            rs1_is_f = 1'b0; rs2_is_f = 1'b0; rs3_is_f = 1'b0; rd_is_f = 1'b0;
            fp_zfa = `FPZ_NONE;
        end
`endif
`ifndef KARU_EN_D
        //  No D: trap every double-precision op. fp_is_d flags everything
        //  that computes in double (incl. FLD/FSD); FCVT.S.D consumes double
        //  with a single result (fp_is_d=0) so it needs an explicit term.
        if (fp_is_d || (unit == `UNIT_FPU && sub == `FOP_CVT_S_D)) begin
            unit = `UNIT_SYS;   sub = `SYS_TRAP;
            rs1_is_f = 1'b0; rs2_is_f = 1'b0; rs3_is_f = 1'b0; rd_is_f = 1'b0;
            fp_is_d = 1'b0; fp_zfa = `FPZ_NONE;
        end
`endif
`ifndef KARU_EN_V
        //  No V: trap vset*, vector arith and vector load/store.
        if (unit == `UNIT_VCFG || unit == `UNIT_VARITH || unit == `UNIT_VLSU ||
            unit == `UNIT_VCRYPTO || unit == `UNIT_VKECCAK)
        begin
            unit = `UNIT_SYS;   sub = `SYS_TRAP;
        end
`endif
    end
endmodule

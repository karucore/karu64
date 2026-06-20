//  karu_uop_defs.vh
//  Shared uop encodings used across the karu64 modules.

`ifndef KARU_UOP_DEFS_VH
`define KARU_UOP_DEFS_VH

`include "karu_ext.vh"                  //  F/D/V/K extension enables

//  Functional-unit selector (uop.unit). 4 bits: the 8 scalar codes plus the
//  vector units. (Widened from 3 bits when V landed -- A/M/F filled 0..7.)
`define UNIT_ALU    4'd0    //  ADD/SUB/AND/.../SLT/...W variants
`define UNIT_BRU    4'd1    //  BEQ/BNE/.../JAL/JALR
`define UNIT_LSU    4'd2    //  loads + stores (incl. FLW/FSW)
`define UNIT_CSR    4'd3    //  CSRRW/S/C(+I)
`define UNIT_SYS    4'd4    //  ECALL/EBREAK/MRET/WFI/FENCE
`define UNIT_M      4'd5    //  M-extension: MUL/MULH*/DIV*/REM* (+ W variants)
`define UNIT_FPU    4'd6    //  F-extension: FADD/FMUL/.../FCVT/...
`define UNIT_NOP    4'd7    //  bubble or illegal
`define UNIT_VCFG   4'd8    //  vsetvli / vsetvl / vsetivli
`define UNIT_VLSU   4'd9    //  vector loads / stores
`define UNIT_VARITH 4'd10   //  vector arithmetic (incl. vmv.v.*)
`define UNIT_VFPU   4'd11   //  vector floating-point (OPFVV / OPFVF)
`define UNIT_VKECCAK 4'd12  //  experimental Zvknhk vkeccak (custom opcode 0x77)
`define UNIT_VCRYPTO 4'd13  //  standard Zvk (opt-in KARU_ZVK); see rtl/zvk/
`define UNIT_BITMANIP 4'd14 //  scalar Zba/Zbb/Zbs (RVA23-mandatory)

//  ---- standard vector crypto (VCRYPTO) sub-ops ----
//  Keep these values aligned with karu_vcrypto.v's cop selector.
`define VCRYPTO_AESZ    5'd0
`define VCRYPTO_AESEM   5'd1
`define VCRYPTO_AESEF   5'd2
`define VCRYPTO_AESDM   5'd3
`define VCRYPTO_AESDF   5'd4
`define VCRYPTO_AESKF1  5'd5
`define VCRYPTO_AESKF2  5'd6
`define VCRYPTO_SHA2CH  5'd7
`define VCRYPTO_SHA2CL  5'd8
`define VCRYPTO_SHA2MS  5'd9
`define VCRYPTO_SM4R    5'd10
`define VCRYPTO_SM4K    5'd11
`define VCRYPTO_SM3C    5'd12
`define VCRYPTO_SM3ME   5'd13
`define VCRYPTO_GHSH    5'd14
`define VCRYPTO_GMUL    5'd15

//  ---- vector config (VCFG) sub-ops ----
`define VCFG_SETVLI 5'h00   //  vsetvli   (zimm vtype, rs1=AVL)
`define VCFG_SETVL  5'h01   //  vsetvl    (rs2=vtype, rs1=AVL)
`define VCFG_SETIVLI 5'h02  //  vsetivli  (zimm vtype, uimm=AVL)

//  ---- vector load/store (VLSU) sub-ops ----
`define VLSU_VLE    5'h00   //  unit-stride load
`define VLSU_VSE    5'h01   //  unit-stride store
`define VLSU_VLM    5'h02   //  mask load   (vlm.v: evl=ceil(vl/8), EEW=8, tail-agnostic)
`define VLSU_VSM    5'h03   //  mask store  (vsm.v)
`define VLSU_VLR    5'h04   //  whole-register load  (vl1re*: 1 reg = VLENB bytes)
`define VLSU_VSR    5'h05   //  whole-register store (vs1r.v)
//  per-element engine (strided / indexed / segment). The core resolves the
//  address source + stride; nf (segment field count) is read from the insn.
`define VLSU_VLSE   5'h06   //  strided load   (addr = base + i*x[rs2]); unit-seg: stride=nf*eewb
`define VLSU_VSSE   5'h07   //  strided store
`define VLSU_VLXE   5'h08   //  indexed load   (addr = base + idx[i]); idx EEW = insn width, data EEW = SEW
`define VLSU_VSXE   5'h09   //  indexed store
`define VLSU_VLSG   5'h0a   //  unit-stride segment load  (stride = nf*eewb)
`define VLSU_VSSG   5'h0b   //  unit-stride segment store

//  ---- vector arithmetic (VARITH) sub-ops ----
//  vmv splat/copy (0x00-0x02), unary index/first (0x03-0x04), then two
//  funct6-keyed groups: compares (0x08|funct6[2:0]) and mask logic
//  (0x10|funct6[2:0]). The low 3 bits mirror the RVV funct6 low bits.
`define VARITH_MV_V_I 5'h00 //  vmv.v.i  (splat sign-extended imm)
`define VARITH_MV_V_X 5'h01 //  vmv.v.x  (splat scalar x)
`define VARITH_MV_V_V 5'h02 //  vmv.v.v  (copy vector)
`define VARITH_VID    5'h03 //  vid.v    (element index -> vd)
`define VARITH_VFIRST 5'h04 //  vfirst.m (first set mask bit -> x)
`define VARITH_CMP    5'h08 //  vms{eq,ne,ltu,lt,leu,le,gtu,gt}: 0x08|f6[2:0]
`define VARITH_MLOGIC 5'h10 //  vm{andn,and,or,xor,orn,nand,nor,xnor}.mm: 0x10|f6[2:0]

//  Sub-ops are 5 bits to fit the F-extension's larger operation space.
//  Other units use only the low 4 bits (values < 16).

//  ALU sub-ops (uop.sub)
`define ALU_ADD     5'h00
`define ALU_SUB     5'h01
`define ALU_AND     5'h02
`define ALU_OR      5'h03
`define ALU_XOR     5'h04
`define ALU_SLL     5'h05
`define ALU_SRL     5'h06
`define ALU_SRA     5'h07
`define ALU_SLT     5'h08
`define ALU_SLTU    5'h09
`define ALU_PASS    5'h0a   //  rd = op2 (used for LUI)
`define ALU_CZEQZ   5'h0b   //  czero.eqz: rd = (rs2==0) ? 0 : rs1  (Zicond)
`define ALU_CZNEZ   5'h0c   //  czero.nez: rd = (rs2!=0) ? 0 : rs1  (Zicond)

//  BRU sub-ops
`define BRU_BEQ     5'h00
`define BRU_BNE     5'h01
`define BRU_BLT     5'h04
`define BRU_BGE     5'h05
`define BRU_BLTU    5'h06
`define BRU_BGEU    5'h07
`define BRU_JAL     5'h08
`define BRU_JALR    5'h09

//  LSU sub-ops
`define LSU_LOAD    5'h00   //  integer load (lb/lh/lw/lwu/ld/lbu/lhu)
`define LSU_STORE   5'h01   //  integer store (sb/sh/sw/sd)
`define LSU_FLOAD   5'h02   //  FLW/FLD -> f-regfile
`define LSU_FSTORE  5'h03   //  FSW/FSD from f-regfile
//  ---- A-extension (atomics) ----
`define LSU_LR      5'h04   //  lr.w / lr.d  -- load + set reservation
`define LSU_SC      5'h05   //  sc.w / sc.d  -- store iff reservation valid
`define LSU_AMOSWAP 5'h06   //  atomic swap   (rd = mem; mem = rs2)
`define LSU_AMOADD  5'h07
`define LSU_AMOXOR  5'h08
`define LSU_AMOAND  5'h09
`define LSU_AMOOR   5'h0A
`define LSU_AMOMIN  5'h0B   //  signed
`define LSU_AMOMAX  5'h0C   //  signed
`define LSU_AMOMINU 5'h0D
`define LSU_AMOMAXU 5'h0E
`define LSU_CBOZERO 5'h0F   //  cbo.zero: zero a 64-byte (Zic64b) block (Zicboz)
`define LSU_CBOCF   5'h10   //  cbo.clean/flush: translate (R|W) + retire, no data (Zicbom)
`define LSU_CBOINVAL    5'h11   //  cbo.inval: translate (W) + retire, no data (Zicbom)

//  CSR sub-ops (same encoding as funct3 bits, except 0=invalid)
`define CSR_RW      5'h01
`define CSR_RS      5'h02
`define CSR_RC      5'h03
`define CSR_RWI     5'h05
`define CSR_RSI     5'h06
`define CSR_RCI     5'h07

//  M-extension sub-ops (mirror funct3 of OP / OP-32 with funct7=0000001)
`define M_MUL       5'h00
`define M_MULH      5'h01
`define M_MULHSU    5'h02
`define M_MULHU     5'h03
`define M_DIV       5'h04
`define M_DIVU      5'h05
`define M_REM       5'h06
`define M_REMU      5'h07

//  BITMANIP sub-ops (Zba/Zbb/Zbs); is_w selects the 32-bit W variants for
//  clz/ctz/cpop/rol/ror. .uw forms carry their own codes (they zext rs1).
`define BM_ANDN     5'd0
`define BM_ORN      5'd1
`define BM_XNOR     5'd2
`define BM_CLZ      5'd3
`define BM_CTZ      5'd4
`define BM_CPOP     5'd5
`define BM_MAX      5'd6
`define BM_MAXU     5'd7
`define BM_MIN      5'd8
`define BM_MINU     5'd9
`define BM_SEXTB    5'd10
`define BM_SEXTH    5'd11
`define BM_ZEXTH    5'd12
`define BM_ROL      5'd13
`define BM_ROR      5'd14
`define BM_ORCB     5'd15
`define BM_REV8     5'd16
`define BM_SH1ADD   5'd17
`define BM_SH2ADD   5'd18
`define BM_SH3ADD   5'd19
`define BM_ADDUW    5'd20
`define BM_SH1ADDUW 5'd21
`define BM_SH2ADDUW 5'd22
`define BM_SH3ADDUW 5'd23
`define BM_SLLIUW   5'd24
`define BM_BCLR     5'd25
`define BM_BEXT     5'd26
`define BM_BINV     5'd27
`define BM_BSET     5'd28

//  SYS sub-ops
`define SYS_ECALL   5'h00
`define SYS_EBREAK  5'h01
`define SYS_MRET    5'h02
`define SYS_WFI     5'h03
`define SYS_FENCE   5'h04
`define SYS_FENCEI  5'h05   //  FENCE.I: flush IFU prefetch (self-modifying code)
`define SYS_SRET    5'h06   //  supervisor return (S-mode)
`define SYS_SFENCEVMA 5'h07 //  SFENCE.VMA: flush Sv39 TLBs
`define SYS_TRAP    5'h1f   //  decode-time illegal instruction

//  LSU size codes (mirror funct3[1:0])
`define LS_B        2'b00
`define LS_H        2'b01
`define LS_W        2'b10
`define LS_D        2'b11

`endif

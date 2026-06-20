//  karu_rvc64.v
//  Markku-Juhani O. Saarinen <mjos@iki.fi>.  See LICENSE.

//  === Decode compressed (RV64C) instructions to 32-bit (combinatorial).
//  Full RV64DC: c.fld/c.fsd/c.fldsp/c.fsdsp expand to FLD/FSD (the
//  D-precision floating-point load/store insns at opcodes 0000111 /
//  0100111). Note RV64C does NOT have c.flw/c.fsw -- those encodings
//  are reused for c.ld/c.sd in RV64 (RV32C only).

`include    "config.vh"

`ifdef  CORE_COMPRESSED

module karu_rvc64(
    input   wire [15:0] c,
    output  wire [31:0] out
);

    assign out =

        c[1:0] == 2'b00 ? (                             //  == quadrant 0 ==

            c[15:13] == 3'b000 ?                        //  c.addi4spn
                //  nzuimm == 0 is RESERVED -- and the all-zeros halfword is
                //  the architecturally DEFINED illegal instruction. Expand to
                //  an invalid 32-bit word so decode raises the cause-2 trap
                //  (this previously expanded to addi s0,sp,0 and executed
                //  silently -- a latent hole the vresv illegal case exposed).
                (c[12:5] == 8'b0 ? 32'hFFFF_FFFF :
                //  addi rd', x2, nzuimm[9:2]
                { 2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00,
                    5'b00010, 3'b000, 2'b01, c[4:2], 7'b0010011 }) :

            c[15:13] == 3'b001 ?                        //  c.fld (RV64DC)
                //  fld rd', uimm[7:3](rs1')  offset = {c[6:5],c[12:10],000}
                //  same offset as c.ld; opcode is LOAD-FP (0000111)
                { 4'b0000, c[6:5], c[12:10], 3'b000,
                    2'b01, c[9:7], 3'b011, 2'b01, c[4:2], 7'b0000111 } :

            c[15:13] == 3'b101 ?                        //  c.fsd (RV64DC)
                //  fsd rs2', uimm[7:3](rs1')  offset same as c.sd
                //  S-format, opcode is STORE-FP (0100111)
                { 4'b0000, c[6:5], c[12], 2'b01, c[4:2], 2'b01, c[9:7],
                    3'b011, c[11:10], 3'b000, 7'b0100111 } :

            c[15:13] == 3'b010 ?                        //  c.lw
                //  lw rd', uimm[6:2](rs1')  offset = {c[5],c[12:10],c[6],00}
                { 5'b00000, c[5], c[12:10], c[6], 2'b00,
                    2'b01, c[9:7], 3'b010, 2'b01, c[4:2], 7'b0000011 } :

            c[15:13] == 3'b011 ?                        //  c.ld (RV64)
                //  ld rd', uimm[7:3](rs1')  offset = {c[6:5],c[12:10],000}
                { 4'b0000, c[6:5], c[12:10], 3'b000,
                    2'b01, c[9:7], 3'b011, 2'b01, c[4:2], 7'b0000011 } :

            c[15:13] == 3'b110 ?                        //  c.sw
                //  sw rs2', uimm[6:2](rs1')
                { 5'b00000, c[5], c[12], 2'b01, c[4:2], 2'b01, c[9:7],
                    3'b010, c[11:10], c[6], 2'b00, 7'b0100011 } :

            c[15:13] == 3'b111 ?                        //  c.sd (RV64)
                //  sd rs2', uimm[7:3](rs1')
                { 4'b0000, c[6:5], c[12], 2'b01, c[4:2], 2'b01, c[9:7],
                    3'b011, c[11:10], 3'b000, 7'b0100011 } :

            c[15:13] == 3'b100 ? (                      //  Zcb byte/half load-store
                //  rs1'=c[9:7]+8, rd'/rs2'=c[4:2]+8. Byte offset {c[5],c[6]};
                //  half offset {c[5],0}. Sub-decoded by c[12:10].
                c[12:10] == 3'b000 ?                    //  c.lbu
                    { 10'b0, c[5], c[6], 2'b01, c[9:7], 3'b100,
                        2'b01, c[4:2], 7'b0000011 } :
                c[12:10] == 3'b001 ?                    //  c.lhu (c[6]=0) / c.lh (c[6]=1)
                    { 10'b0, c[5], 1'b0, 2'b01, c[9:7], (c[6] ? 3'b001 : 3'b101),
                        2'b01, c[4:2], 7'b0000011 } :
                c[12:10] == 3'b010 ?                    //  c.sb
                    { 7'b0000000, 2'b01, c[4:2], 2'b01, c[9:7], 3'b000,
                        3'b000, c[5], c[6], 7'b0100011 } :
                c[12:10] == 3'b011 ?                    //  c.sh (c[6]=0)
                    { 7'b0000000, 2'b01, c[4:2], 2'b01, c[9:7], 3'b001,
                        3'b000, c[5], 1'b0, 7'b0100011 } : 32'b0 ) : 0 ) :

        c[1:0] == 2'b01 ? (                             //  == quadrant 1 ==

            c[15:13] == 3'b000 ?                        //  c.nop / c.addi
                //  addi rd, rd, imm[5:0]
                { {7{c[12]}}, c[6:2], c[11:7], 3'b000, c[11:7], 7'b0010011 } :

            c[15:13] == 3'b001 ?                        //  c.addiw (RV64)
                //  addiw rd, rd, imm[5:0]   (rd=x0 is reserved)
                { {7{c[12]}}, c[6:2], c[11:7], 3'b000, c[11:7], 7'b0011011 } :

            c[15:13] == 3'b010 ?                        //  c.li
                //  addi rd, x0, imm[5:0]
                { {7{c[12]}}, c[6:2], 5'b00000, 3'b000, c[11:7], 7'b0010011 } :

            //  c.mop.n (Zcmop): sits in the c.lui nzimm==0 reserved slot with
            //  c[7]=1, c[11]=0 (n=2*c[10:8]+1). A "may-be-op" that defaults to a
            //  NOP preserving all registers -- expand to addi x0,x0,0.
            c[15:13] == 3'b011 && c[12] == 1'b0 && c[6:2] == 5'b00000
                && c[11] == 1'b0 && c[7] == 1'b1 ?
                32'h00000013 :

            c[15:13] == 3'b011 && c[11:7] == 5'b00010 ? //  c.addi16sp
                //  addi x2, x2, nzimm[9:4]
                { {3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000,
                    5'b00010, 3'b000, 5'b00010, 7'b0010011 } :

            c[15:13] == 3'b011 ?                        //  c.lui
                //  lui rd, nzimm[17:12]
                { {15{c[12]}}, c[6:2], c[11:7], 7'b0110111 } :

            c[15:13] == 3'b100 && c[11:10] == 2'b00 ?   //  c.srli (RV64: 6-bit)
                { 6'b000000, c[12], c[6:2], 2'b01, c[9:7],
                    3'b101, 2'b01, c[9:7], 7'b0010011 } :

            c[15:13] == 3'b100 && c[11:10] == 2'b01 ?   //  c.srai (RV64: 6-bit)
                { 6'b010000, c[12], c[6:2], 2'b01, c[9:7],
                    3'b101, 2'b01, c[9:7], 7'b0010011 } :

            c[15:13] == 3'b100 && c[11:10] == 2'b10 ?   //  c.andi
                { {7{c[12]}}, c[6:2], 2'b01, c[9:7],
                    3'b111, 2'b01, c[9:7], 7'b0010011 } :

            c[15:13] == 3'b100 && c[11:10] == 2'b11 ? ( //  c.sub/xor/or/and (c[12]=0)
                                                        //  c.subw/c.addw  (c[12]=1)
                c[12] == 1'b0 ? (
                    c[6:5] == 2'b00 ?                   //  c.sub
                        { 7'b0100000, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b000, 2'b01, c[9:7], 7'b0110011 } :
                    c[6:5] == 2'b01 ?                   //  c.xor
                        { 7'b0000000, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b100, 2'b01, c[9:7], 7'b0110011 } :
                    c[6:5] == 2'b10 ?                   //  c.or
                        { 7'b0000000, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b110, 2'b01, c[9:7], 7'b0110011 } :
                    /* c[6:5]==2'b11 */                 //  c.and
                        { 7'b0000000, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b111, 2'b01, c[9:7], 7'b0110011 } ) :
                /* c[12]==1 */ (
                    c[6:5] == 2'b00 ?                   //  c.subw (RV64)
                        { 7'b0100000, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b000, 2'b01, c[9:7], 7'b0111011 } :
                    c[6:5] == 2'b01 ?                   //  c.addw (RV64)
                        { 7'b0000000, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b000, 2'b01, c[9:7], 7'b0111011 } :
                    c[6:5] == 2'b10 ?                   //  c.mul (Zcb)
                        { 7'b0000001, 2'b01, c[4:2], 2'b01, c[9:7],
                            3'b000, 2'b01, c[9:7], 7'b0110011 } :
                    /* c[6:5]==2'b11 : Zcb unary on rd'=rs1'=c[9:7] */ (
                        c[4:2] == 3'b000 ?              //  c.zext.b -> andi rd',rd',0xff
                            { 12'h0ff, 2'b01, c[9:7], 3'b111, 2'b01, c[9:7], 7'b0010011 } :
                        c[4:2] == 3'b001 ?              //  c.sext.b (Zbb)
                            { 7'b0110000, 5'b00100, 2'b01, c[9:7], 3'b001, 2'b01, c[9:7], 7'b0010011 } :
                        c[4:2] == 3'b010 ?              //  c.zext.h (Zbb, RV64)
                            { 7'b0000100, 5'b00000, 2'b01, c[9:7], 3'b100, 2'b01, c[9:7], 7'b0111011 } :
                        c[4:2] == 3'b011 ?              //  c.sext.h (Zbb)
                            { 7'b0110000, 5'b00101, 2'b01, c[9:7], 3'b001, 2'b01, c[9:7], 7'b0010011 } :
                        c[4:2] == 3'b100 ?              //  c.zext.w -> add.uw rd',rd',x0 (Zba)
                            { 7'b0000100, 5'b00000, 2'b01, c[9:7], 3'b000, 2'b01, c[9:7], 7'b0111011 } :
                        c[4:2] == 3'b101 ?              //  c.not -> xori rd',rd',-1
                            { 12'hfff, 2'b01, c[9:7], 3'b100, 2'b01, c[9:7], 7'b0010011 } :
                            32'b0 ) ) ) :

            c[15:13] == 3'b101 ?                        //  c.j
                //  jal x0, offset[11:1]
                { c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3],
                    {9{c[12]}}, 5'b00000, 7'b1101111 } :

            c[15:14] == 2'b11 ?                         //  c.beqz / c.bnez
                //  beq/bne rs1', x0, offset[8:1]
                { {4{c[12]}}, c[6:5], c[2], 7'b0000001, c[9:7], 2'b00,
                    c[13], c[11:10], c[4:3], c[12], 7'b1100011 } : 0 ) :

        c[1:0] == 2'b10 ? (                             //  == quadrant 2 ==

            c[15:13] == 3'b000 ?                        //  c.slli (RV64: 6-bit)
                { 6'b000000, c[12], c[6:2], c[11:7], 3'b001, c[11:7],
                    7'b0010011 } :

            c[15:13] == 3'b001 ?                        //  c.fldsp (RV64DC)
                //  fld rd, uimm[8:3](x2)  offset same as c.ldsp
                //  I-format, opcode LOAD-FP (0000111)
                { 3'b000, c[4:2], c[12], c[6:5], 3'b000,
                    5'b00010, 3'b011, c[11:7], 7'b0000111 } :

            c[15:13] == 3'b010 ?                        //  c.lwsp
                //  lw rd, uimm[7:2](x2)  offset = {c[3:2],c[12],c[6:4],00}
                { 4'b0000, c[3:2], c[12], c[6:4], 2'b00,
                    5'b00010, 3'b010, c[11:7], 7'b0000011 } :

            c[15:13] == 3'b011 ?                        //  c.ldsp (RV64)
                //  ld rd, uimm[8:3](x2)  offset = {c[4:2],c[12],c[6:5],000}
                { 3'b000, c[4:2], c[12], c[6:5], 3'b000,
                    5'b00010, 3'b011, c[11:7], 7'b0000011 } :

            c[15:0] == 16'b1001000000000010 ?           //  c.ebreak
                32'b00000000000100000000000001110011 :

            c[15:13] == 3'b100 && c[6:2] == 5'b00000 ?  //  c.jr / c.jalr
                //  jalr {x0|x1}, rs1, 0   (rd = c[12] ? x1 : x0)
                { 12'b000000000000, c[11:7], 3'b000, 4'b0000, c[12],
                    7'b1100111 } :

            c[15:12] == 4'b1000 ?                       //  c.mv
                //  add rd, x0, rs2
                { 7'b0000000, c[6:2], 5'b00000, 3'b000, c[11:7], 7'b0110011 } :

            c[15:12] == 4'b1001 ?                       //  c.add
                //  add rd, rd, rs2
                { 7'b0000000, c[6:2], c[11:7], 3'b000, c[11:7], 7'b0110011 } :

            c[15:13] == 3'b101 ?                        //  c.fsdsp (RV64DC)
                //  fsd rs2, uimm[8:3](x2)  offset same as c.sdsp
                //  S-format, opcode STORE-FP (0100111)
                { 3'b000, c[9:7], c[12], c[6:2], 5'b00010, 3'b011,
                    c[11:10], 3'b000, 7'b0100111 } :

            c[15:13] == 3'b110 ?                        //  c.swsp
                //  sw rs2, uimm[7:2](x2)
                { 4'b0000, c[8:7], c[12], c[6:2], 5'b00010, 3'b010,
                    c[11:9], 2'b00, 7'b0100011 } :

            c[15:13] == 3'b111 ?                        //  c.sdsp (RV64)
                //  sd rs2, uimm[8:3](x2)
                { 3'b000, c[9:7], c[12], c[6:2], 5'b00010, 3'b011,
                    c[11:10], 3'b000, 7'b0100011 } : 0 ) :

            0;                                          //  == quadrant 3 (uncompressed)

endmodule

`endif

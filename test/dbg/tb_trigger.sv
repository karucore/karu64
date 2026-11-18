// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_trigger;
`ifdef TEST_FOUR_TRIGGERS
 localparam COUNT=4;
`else
 localparam COUNT=2;
`endif
 reg clk=0,rst=1,debug_mode_i=0,csr_write_i=0;
 reg [11:0] csr_addr_i=0;
 reg [63:0] csr_data_i=0;
 wire [63:0] csr_data_o;
 reg [1:0] priv_i=3;
 reg virt_i=0,exec_valid_i=0,data_valid_i=0,data_load_i=0,data_store_i=0;
 reg [63:0] exec_addr_i=0,data_addr_i=0;
 wire exec_hit_o,data_hit_o,data_armed_o;
 karu_trigger #(.COUNT(COUNT)) dut(.*);
 always #5 clk=!clk;
 integer checks=0,i,j,md,kind;
 reg [63:0] cfg,addr,expected;
 task check(input condition,input string message);
 begin checks=checks+1; if(condition!==1) $fatal(1,"%s",message); end endtask
 task write(input [11:0] a,input[63:0] d);
 begin @(negedge clk);csr_write_i=1;csr_addr_i=a;csr_data_i=d;@(negedge clk);csr_write_i=0; end endtask
 task read_check(input[11:0]a,input[63:0] d);
 begin csr_addr_i=a;#1;check(csr_data_o===d,"CSR value");end endtask
 initial begin
  repeat(3) @(negedge clk);rst=0;
  read_check('h7a0,0);read_check('h7a1,64'hf000000000000000);read_check('h7a4,64'h01008040);
  for(i=0;i<COUNT;i=i+1)begin
   write('h7a0,i);read_check('h7a0,i);read_check('h7a1,64'hf000000000000000);
  end
  write('h7a0,COUNT);read_check('h7a0,COUNT-1);write('h7a0,0);
  write('h7a1,64'h6800000000001047);read_check('h7a1,64'hf000000000000000);
  debug_mode_i=1;
  write('h7a2,64'hfeedfaceabcdef01);read_check('h7a2,64'hfeedfaceabcdef01);
  write('h7a1,64'h680000000000105f);
  debug_mode_i=0;
  write('h7a1,0);read_check('h7a1,64'h680000000000105f);
  write('h7a2,0);read_check('h7a2,64'hfeedfaceabcdef01);
  debug_mode_i=1;write('h7a1,64'h6000000000001047);read_check('h7a1,64'hf000000000000000);
  write('h7a1,64'h6800000000000047);read_check('h7a1,64'hf000000000000000);
  // Individually unsupported fields/actions disable cleanly.
  for(j=0;j<64;j=j+1) if(j==11||j==16||j==17||j==18||j==21)begin
   write('h7a1,64'h6800000000001047|(64'd1<<j));read_check('h7a1,64'hf000000000000000);
  end
  // Every executing privilege, operation kind, NAPOT size and boundary.
  for(md=0;md<5;md=md+1)for(kind=0;kind<3;kind=kind+1)begin
   cfg=64'h6800000000001000|(64'd1<<kind)|
    (md==0?64'h40:md==1?64'h10:md==2?64'h8:md==3?64'h1000000:64'h800000);
   priv_i=md==0?3:(md==1||md==3)?1:0;virt_i=md>=3;
   for(i=0;i<=16;i=i+1)begin
    debug_mode_i=1;
    write('h7a1,0);
    addr=64'h80000000|((64'd1<<i)-1);
    write('h7a2,addr);write('h7a1,cfg|(i==0?0:64'h80));
    debug_mode_i=0;
    for(j=-1;j<=3;j=j+1)begin
     exec_valid_i=kind==2;data_valid_i=kind!=2;data_load_i=kind==0;data_store_i=kind==1;
     exec_addr_i=64'h80000000+(j<0?-64'd1:((64'd1<<i)*j));data_addr_i=exec_addr_i;
     #1;expected=i==0?(j==0):(j==0||j==1);
     // NAPOT of tdata2 trailing i ones spans 2^(i+1) bytes.
     check((exec_hit_o||data_hit_o)==expected,"address/range boundary");
     @(negedge clk);
    end
    exec_valid_i=0;data_valid_i=0;
   end
  end
  debug_mode_i=1;write('h7a1,0);write('h7a2,0);write('h7a1,64'h68000000000010c1);
  write('h7a2,~64'd0);read_check('h7a2,64'hbfffffffffffffff);
  write('h7a1,0);write('h7a2,~64'd0);read_check('h7a2,~64'd0);
  write('h7a1,64'h6800000000001041);read_check('h7a2,~64'd0);
  // Debug Mode suppresses every kind of match, including stale address data.
  exec_valid_i=1;data_valid_i=1;data_load_i=1;exec_addr_i=~64'd0;data_addr_i=~64'd0;
  #1;check(!exec_hit_o&&!data_hit_o&&!data_armed_o,"debug suppression");
  $display("karudbg triggers (%0d slots): PASS %0d checks",COUNT,checks);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule

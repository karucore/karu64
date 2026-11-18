// SPDX-License-Identifier: BSD-2-Clause
// Independent memory/VRF model for precise RVV address-watchpoint sequencing.
`timescale 1ns/1ps
`include "karu_vcfg.vh"
module tb_vlsu_watch;
 reg clk=0,rst=1,req=0,is_store=0,vm=1,vta=0,vma=0,pelem=0,indexed=0,ff=0;
 reg[63:0]base=64'h80001000,vl=4,stride=1;
 reg[5:0]dpmlen=0;
 reg pm_virtual=0;
 reg[4:0]vd=8,idx_vs=24;
 reg[1:0]eew=0,idx_eew=0;
 reg[31:0]vstart=0;
 reg[3:0]nreg=1,nf=1,idx_nreg=1;
 reg[255:0]v0mask=~256'd0;
 wire busy,done,xlate_req,xlate_st,fault_abort,trim_req,fault_bus;
 wire[63:0]xlate_va,fault_va;
 reg xlate_done=0,xlate_fault=0;
 reg[63:0]xlate_pa=0;
 reg[1:0]xlate_pbmt=0;
 wire[31:0]fault_index,trim_vl;
 wire vmem_req,vmem_allow_post,vmem_is_store;
 reg vmem_busy=0,store_pending=0,vmem_fault=0;
 reg[63:0]vmem_fault_va=0;
 wire[63:0]vmem_va,vmem_addr;
 wire[127:0]vmem_wdata;
 wire[15:0]vmem_wstrb,vmem_rstrb;
 wire[1:0]vmem_pbmt,vmem_size;
 reg vmem_done=0;
 reg[127:0]vmem_rdata=0;
 wire[4:0]vg_rs,vg_wd;
 wire vg_rg,vg_wg,vg_we;
 reg[127:0]vg_rdata=0;
 wire[127:0]vg_wdata;
 wire[15:0]vg_wbe;
 reg debug_watch_enable_i=1;
 wire debug_watch_hit_i,debug_watch_valid_o,debug_watch_abort_o,debug_watch_progress_o;
 wire[63:0]debug_watch_addr_o;
 wire[31:0]debug_watch_index_o;
 reg[63:0]watched=0,fault_at=~64'd0;
 assign debug_watch_hit_i=debug_watch_valid_o&&debug_watch_addr_o==watched;
 karu_vlsu dut(.*);
 reg[127:0]vrf[0:63];
 reg[7:0]ram[0:16383];
 reg[7:0]expected_ram[0:4095];
 integer i,b,checks=0,ops=0,reads=0,writes=0,cases=0,trims=0;
 integer sew,lmul,mode,which,maskcase,len,hit,stop,first,limit,field,sidx;
 reg[63:0]target;
 always #5 clk=!clk;
 always @(posedge clk)begin
  if(trim_req)trims<=trims+1;
  vg_rdata<=vrf[{vg_rs,vg_rg}];
  if(vg_we)for(b=0;b<16;b=b+1)if(vg_wbe[b])vrf[{vg_wd,vg_wg}][b*8+:8]<=vg_wdata[b*8+:8];
  xlate_done<=xlate_req;xlate_fault<=xlate_va==fault_at;xlate_pa<=xlate_va;
  vmem_done<=vmem_req;
  if(vmem_req)begin
   if(vmem_is_store)begin
    writes<=writes+1;
    for(b=0;b<16;b=b+1)if(vmem_wstrb[b])ram[(vmem_addr+b)&16383]<=vmem_wdata[b*8+:8];
   end else begin
    reads<=reads+1;
    for(b=0;b<16;b=b+1)vmem_rdata[b*8+:8]<=ram[(vmem_addr+b)&16383];
   end
  end
 end
 task check(input condition,input string message);
 begin checks=checks+1;if(condition!==1)$fatal(1,"case%0d sew%0d lm%0d mode%0d mask%0d hit%0d: %s",cases,sew,lmul,mode,maskcase,hit,message);end endtask
 task run(input integer expected_hit);
 integer timeout,trims_before;
 begin
  trims_before=trims;
  @(negedge clk);req=1;@(negedge clk);req=0;timeout=0;
  while(!done&&!fault_abort&&!debug_watch_abort_o&&timeout<10000)begin @(negedge clk);timeout=timeout+1;end
  check(timeout<10000,"completion timeout");
  check(!fault_abort,"unexpected fault");
  check(debug_watch_abort_o==(expected_hit>=0),"hit outcome");
  if(expected_hit>=0)begin
   check(debug_watch_index_o==expected_hit,"element restart index");
   check(trims==trims_before,"watchpoint must not trim FF vl");
  end
  @(negedge clk);cases=cases+1;
 end endtask
 initial begin
  for(i=0;i<16384;i=i+1)ram[i]=8'(i^(i>>8));
  repeat(3)@(negedge clk);rst=0;
  for(sew=0;sew<4;sew=sew+1)for(lmul=-3;lmul<4;lmul=lmul+1)
   for(mode=0;mode<4;mode=mode+1)for(maskcase=0;maskcase<3;maskcase=maskcase+1)begin
    // Contiguous, strided, indexed and 2-field segmented accesses.
    // Indexed arrays are independent source data; registergroup starts differ.
    nreg=4'(lmul<0?1:1<<lmul);eew=2'(sew);nf=mode==3?2:1;
    if(nreg*nf>8)nf=1;
    pelem=mode!=0;indexed=mode==2;stride=mode==3?(nf<<sew):(3<<sew);
    idx_eew=0;idx_nreg=1;is_store=0;
    len=(lmul<0?(32>>(-lmul)):(32<<lmul))>>sew;if(len>16)len=16;vl=64'(len);
    vm=maskcase==0;v0mask=256'haaaa;vstart=maskcase==2?1:0;
    for(which=0;which<3;which=which+1)begin
     hit=len==0?0:which==0?0:which==1?len/2:len-1;
     for(i=0;i<64;i=i+1)vrf[i]={16{8'hee}};
     for(i=0;i<32;i=i+1)vrf[48+(i>>4)][(i&15)*8+:8]=8'(i*5);
     base=64'h80001000;
     target=base+(mode==0?(hit<<sew):mode==2?hit*5:hit*stride)+(nf==2?(1<<sew):0);
     watched=target;
     stop=(len!=0&&hit>=vstart&&(vm||v0mask[hit]))?hit:-1;
     run(stop);
     // Every destination element: loaded prefix, undisturbed prestart/mask/tail.
     for(sidx=0;sidx<len;sidx=sidx+1)for(field=0;field<nf;field=field+1)for(b=0;b<(1<<sew);b=b+1)begin
      first=(field*nreg*32)+(sidx<<sew)+b;
      target=base+(mode==0?(sidx<<sew):mode==2?sidx*5:sidx*stride)+(field<<sew)+b;
      check(vrf[16+(first>>4)][(first&15)*8+:8]===
       ((sidx>=vstart&&(vm||v0mask[sidx])&&(stop<0||sidx<stop))?ram[target&16383]:8'hee),"load prefix and undisturbed bytes");
     end
    end
   end
  // Store-side traces, including all segment fields: the matching
  // segment must have no side effects, while all earlier active stores remain.
  for(sew=0;sew<4;sew=sew+1)for(mode=0;mode<4;mode=mode+1)
   for(maskcase=0;maskcase<3;maskcase=maskcase+1)begin
    lmul=0;nreg=1;eew=2'(sew);nf=mode==3?2:1;
    pelem=mode!=0;indexed=mode==2;stride=mode==3?(nf<<sew):(3<<sew);
    idx_eew=0;idx_nreg=1;is_store=1;vl=4;hit=2;
    vm=maskcase==0;v0mask=256'haaaa;vstart=maskcase==2?1:0;
    for(i=0;i<4096;i=i+1)begin ram['h1000+i]=8'hee;expected_ram[i]=8'hee;end
    for(i=0;i<64;i=i+1)vrf[i]={16{8'h5a}};
    for(i=0;i<32;i=i+1)vrf[48+(i>>4)][(i&15)*8+:8]=8'(i*5);
    base=64'h80001000;
    watched=base+(mode==0?(hit<<sew):mode==2?hit*5:hit*stride)+(nf==2?(1<<sew):0);
    stop=(hit>=vstart&&(vm||v0mask[hit]))?hit:-1;
    for(sidx=0;sidx<4;sidx=sidx+1)if(sidx>=vstart&&(vm||v0mask[sidx])&&(stop<0||sidx<stop))
     for(field=0;field<nf;field=field+1)for(b=0;b<(1<<sew);b=b+1)begin
      target=base+(mode==0?(sidx<<sew):mode==2?sidx*5:sidx*stride)+(field<<sew)+b;
      expected_ram[target&4095]=8'h5a;
     end
    run(stop);
    for(i=0;i<128;i=i+1)check(ram['h1000+i]===expected_ram[i],"store prefix and no matching-segment side effects");
   end
  // Fault-only-first uses Debug Mode at all active hit positions, including
  // masked element0, resumed vstart and the last segment; never a silent trim.
  is_store=0;ff=1;eew=0;nreg=1;vl=4;base=64'h80001000;
  for(mode=0;mode<2;mode=mode+1)for(which=0;which<4;which=which+1)begin
   nf=mode==0?1:2;pelem=mode!=0;indexed=0;stride=nf;
   vm=which!=2;v0mask=256'haaaa;vstart=which==3?1:0;
   hit=which==0?0:which==1?1:3;
   watched=base+hit*nf+(mode==0?0:1);run(hit);
  end
  ff=0;
  // Pointer masking is applied to each computed address, including high
  // index/stride arithmetic; the comparator sees exactly the translated VA.
  is_store=0;pelem=0;indexed=0;vm=1;vstart=0;eew=0;nreg=1;nf=1;vl=4;
  for(i=0;i<64;i=i+1)vrf[i]=0;
  dpmlen=7;base=64'hac00000080001000;watched=64'h80001002;run(2);
  dpmlen=16;base=64'habcd000080001000;watched=64'h80001002;run(2);
  dpmlen=0;
  // An actual earlier translation fault in an FF load trims before any later
  // watchpoint is observed. Cache reuse is tested across the 4 KiB boundary.
  base=64'h80000ffc;vl=8;ff=1;fault_at=64'h80001000;watched=64'h80001002;
  @(negedge clk);req=1;@(negedge clk);req=0;
  i=0;while(!done&&!fault_abort&&!debug_watch_abort_o&&i<10000)begin
   @(negedge clk);i=i+1;
   if(trim_req)check(trim_vl==4,"FF earlier fault trims at correct index");
  end
  check(done&&!fault_abort&&!debug_watch_abort_o,"earlier FF fault wins over later watchpoint");
  $display("karudbg vector watchpoint sequencing: PASS %0d cases, %0d checks",cases,checks);$finish;
 end
 initial begin #50000000;$fatal(1,"timeout");end
endmodule

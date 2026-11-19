// tb_sba_xbar.sv -- SBA/core/imem co-simulation through the real VCU118 crossbar.
//
// Random traffic through karudbg_bus (core/SBA arbiter) into karu_ddr_xbar built
// with SIM_TB (X1..X61 DRAM-port contract assertions live), karu_axi4_ram and the
// real CLINT/PLIC/UART/QSPI/Ethernet/boot-memory peripherals. Regression for
// review finding S13: RAM-class SBA requests of every size (8/16/32/64-bit,
// including sub-doubleword offsets) must reach the xbar DRAM master as aligned
// 64-bit size-3 beats with byte strobes, while device-class requests keep their
// exact size.
//
// Models:
//   core  one outstanding transaction per read and write channel (as karu64
//         rd_lock/wr_lock); W only with or after AW (as the karudbg_core
//         splitter); no new request while pause_o; DRAM accesses are 8-byte
//         aligned size 3 (the xbar core contract), with 8-beat line refills.
//   SBA   random reads/writes of size 0..4 over DRAM, scratch, CLINT mtimecmp,
//         the private debug page, a 33-bit DRAM alias, ROM, unmapped space and
//         misaligned addresses.
//   imem  random single-beat DRAM/ROM fetches.
// Scoreboard: byte-level shadow of DRAM/scratch/mtimecmp plus ID, RLAST,
// response-code and liveness checks. karudbg_bus SBAB* checks are live.
//
// Plusargs: +seed=N +cycles=N +sba_rate=N (0: SBA idle) +core_rate=N.
// Prints "PASS SBA crossbar co-simulation" only when the scoreboard is clean,
// no xbar assertion fired, assertions were enabled and the traffic mix covered
// narrow and sub-doubleword DRAM SBA accesses; otherwise ends with $fatal.
// Needs rom.hex (any small $readmemh image) in the working directory.
`timescale 1ns/1ps
`include "karu_axi_defs.vh"
`include "karu_bootmap.vh"
module tb_sba_xbar;
  reg clk=0, rst=1;
  always #5 clk=~clk;
  integer SEED, CYCLES, SBA_RATE, CORE_RATE;
  // ---------------- core-side wires
  reg [3:0] c_arid; reg [31:0] c_araddr; reg [7:0] c_arlen; reg [2:0] c_arsize;
  reg [1:0] c_arburst; reg [2:0] c_arprot; reg c_arvalid; reg c_rready;
  reg [3:0] c_awid; reg [31:0] c_awaddr; reg [7:0] c_awlen; reg [2:0] c_awsize;
  reg [1:0] c_awburst; reg [2:0] c_awprot; reg c_awvalid;
  reg [63:0] c_wdata; reg [7:0] c_wstrb; reg c_wlast; reg c_wvalid; reg c_bready;
  wire c_arready, c_rlast, c_rvalid, c_awready, c_wready, c_bvalid;
  wire [3:0] c_rid, c_bid; wire [63:0] c_rdata; wire [1:0] c_rresp, c_bresp;
  // ---------------- SBA request side
  reg req_valid; wire req_ready; reg [63:0] req_addr, req_data; reg [2:0] req_size; reg req_write;
  wire resp_valid; reg resp_ready; wire [63:0] resp_data; wire [2:0] resp_error;
  wire pause, flush; wire quiet;
  // ---------------- bus -> xbar dmem
  wire [3:0] d_arid, d_awid, d_rid, d_bid; wire [31:0] d_araddr, d_awaddr;
  wire [7:0] d_arlen, d_awlen; wire [2:0] d_arsize, d_awsize, d_arprot, d_awprot;
  wire [1:0] d_arburst, d_awburst, d_rresp, d_bresp;
  wire d_arvalid, d_arready, d_rvalid, d_rready, d_rlast, d_awvalid, d_awready;
  wire [63:0] d_wdata, d_rdata; wire [7:0] d_wstrb; wire d_wlast, d_wvalid, d_wready, d_bvalid, d_bready;
  // ---------------- imem
  reg [3:0] i_arid; reg [31:0] i_araddr; reg i_arvalid; reg i_rready;
  wire i_arready, i_rvalid, i_rlast; wire [3:0] i_rid; wire [63:0] i_rdata; wire [1:0] i_rresp;
  // ---------------- xbar -> ram
  wire [3:0] m_arid, m_awid, m_rid, m_bid; wire [31:0] m_araddr, m_awaddr;
  wire [7:0] m_arlen, m_awlen; wire [2:0] m_arsize, m_awsize, m_arprot, m_awprot;
  wire [1:0] m_arburst, m_awburst, m_rresp, m_bresp;
  wire m_arvalid, m_arready, m_rvalid, m_rready, m_rlast, m_awvalid, m_awready;
  wire [63:0] m_wdata, m_rdata; wire [7:0] m_wstrb; wire m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;

  karudbg_bus #(.NONSECURE(1),.ENABLE(1)) bus (
    .clk(clk),.rst(rst),
    .req_valid_i(req_valid),.req_ready_o(req_ready),.req_addr_i(req_addr),.req_data_i(req_data),
    .req_size_i(req_size),.req_write_i(req_write),.resp_valid_o(resp_valid),.resp_ready_i(resp_ready),
    .resp_data_o(resp_data),.resp_error_o(resp_error),.pause_o(pause),.quiet_i(quiet),.flush_o(flush),
    .c_arid(c_arid),.c_araddr(c_araddr),.c_arlen(c_arlen),.c_arsize(c_arsize),.c_arburst(c_arburst),
    .c_arprot(c_arprot),.c_arvalid(c_arvalid),.c_rready(c_rready),.c_awid(c_awid),.c_awaddr(c_awaddr),
    .c_awlen(c_awlen),.c_awsize(c_awsize),.c_awburst(c_awburst),.c_awprot(c_awprot),.c_awvalid(c_awvalid),
    .c_wdata(c_wdata),.c_wstrb(c_wstrb),.c_wlast(c_wlast),.c_wvalid(c_wvalid),.c_bready(c_bready),
    .c_arready(c_arready),.c_rid(c_rid),.c_rdata(c_rdata),.c_rresp(c_rresp),.c_rlast(c_rlast),.c_rvalid(c_rvalid),
    .c_awready(c_awready),.c_wready(c_wready),.c_bid(c_bid),.c_bresp(c_bresp),.c_bvalid(c_bvalid),
    .m_arid(d_arid),.m_araddr(d_araddr),.m_arlen(d_arlen),.m_arsize(d_arsize),.m_arburst(d_arburst),
    .m_arprot(d_arprot),.m_arvalid(d_arvalid),.m_rready(d_rready),.m_awid(d_awid),.m_awaddr(d_awaddr),
    .m_awlen(d_awlen),.m_awsize(d_awsize),.m_awburst(d_awburst),.m_awprot(d_awprot),.m_awvalid(d_awvalid),
    .m_wdata(d_wdata),.m_wstrb(d_wstrb),.m_wlast(d_wlast),.m_wvalid(d_wvalid),.m_bready(d_bready),
    .m_arready(d_arready),.m_rid(d_rid),.m_rdata(d_rdata),.m_rresp(d_rresp),.m_rlast(d_rlast),.m_rvalid(d_rvalid),
    .m_awready(d_awready),.m_wready(d_wready),.m_bid(d_bid),.m_bresp(d_bresp),.m_bvalid(d_bvalid));

  wire uart_txd, uart_rts, irq_t, irq_s, irq_m, irq_se; wire [63:0] mtime;
  karu_ddr_xbar #(.CPU_CLK_HZ(100000000),.ROM_HEX("rom.hex")) xbar (
    .clk(clk),.rst(rst),
    .imem_arid(i_arid),.imem_araddr(i_araddr),.imem_arlen(8'd0),.imem_arsize(3'd3),.imem_arburst(2'd1),
    .imem_arprot(3'b110),.imem_arvalid(i_arvalid),.imem_arready(i_arready),.imem_rid(i_rid),.imem_rdata(i_rdata),
    .imem_rresp(i_rresp),.imem_rlast(i_rlast),.imem_rvalid(i_rvalid),.imem_rready(i_rready),
    .dmem_arid(d_arid),.dmem_araddr(d_araddr),.dmem_arlen(d_arlen),.dmem_arsize(d_arsize),.dmem_arburst(d_arburst),
    .dmem_arprot(d_arprot),.dmem_arvalid(d_arvalid),.dmem_arready(d_arready),.dmem_rid(d_rid),.dmem_rdata(d_rdata),
    .dmem_rresp(d_rresp),.dmem_rlast(d_rlast),.dmem_rvalid(d_rvalid),.dmem_rready(d_rready),
    .dmem_awid(d_awid),.dmem_awaddr(d_awaddr),.dmem_awlen(d_awlen),.dmem_awsize(d_awsize),.dmem_awburst(d_awburst),
    .dmem_awprot(d_awprot),.dmem_awvalid(d_awvalid),.dmem_awready(d_awready),.dmem_wdata(d_wdata),.dmem_wstrb(d_wstrb),
    .dmem_wlast(d_wlast),.dmem_wvalid(d_wvalid),.dmem_wready(d_wready),.dmem_bid(d_bid),.dmem_bresp(d_bresp),
    .dmem_bvalid(d_bvalid),.dmem_bready(d_bready),
    .m_arid(m_arid),.m_araddr(m_araddr),.m_arlen(m_arlen),.m_arsize(m_arsize),.m_arburst(m_arburst),.m_arprot(m_arprot),
    .m_arvalid(m_arvalid),.m_arready(m_arready),.m_rid(m_rid),.m_rdata(m_rdata),.m_rresp(m_rresp),.m_rlast(m_rlast),
    .m_rvalid(m_rvalid),.m_rready(m_rready),.m_awid(m_awid),.m_awaddr(m_awaddr),.m_awlen(m_awlen),.m_awsize(m_awsize),
    .m_awburst(m_awburst),.m_awprot(m_awprot),.m_awvalid(m_awvalid),.m_awready(m_awready),.m_wdata(m_wdata),
    .m_wstrb(m_wstrb),.m_wlast(m_wlast),.m_wvalid(m_wvalid),.m_wready(m_wready),.m_bid(m_bid),.m_bresp(m_bresp),
    .m_bvalid(m_bvalid),.m_bready(m_bready),
    .uart_txd(uart_txd),.uart_rxd(1'b1),.uart_rts(uart_rts),.uart_cts(1'b0),
    .irq_timer(irq_t),.irq_software(irq_s),.irq_ext_m(irq_m),.irq_ext_s(irq_se),.clint_mtime(mtime),
    .sysreg_re_o(),.sysreg_raddr_o(),.sysreg_rdata_i(64'b0),.sysreg_we_o(),.sysreg_waddr_o(),.sysreg_wdata_o());

  karu_axi4_ram #(.RAM_XADR(16),.MEM_BASE(32'h8000_0000),.RLAT(1),.HEXFILE("")) ram (
    .clk(clk),.rst(rst),
    .s_arid(m_arid),.s_araddr(m_araddr),.s_arlen(m_arlen),.s_arsize(m_arsize),.s_arburst(m_arburst),
    .s_arvalid(m_arvalid),.s_arready(m_arready),.s_rid(m_rid),.s_rdata(m_rdata),.s_rresp(m_rresp),
    .s_rlast(m_rlast),.s_rvalid(m_rvalid),.s_rready(m_rready),
    .s_awid(m_awid),.s_awaddr(m_awaddr),.s_awlen(m_awlen),.s_awsize(m_awsize),.s_awburst(m_awburst),
    .s_awvalid(m_awvalid),.s_awready(m_awready),.s_wdata(m_wdata),.s_wstrb(m_wstrb),.s_wlast(m_wlast),
    .s_wvalid(m_wvalid),.s_wready(m_wready),.s_bid(m_bid),.s_bresp(m_bresp),.s_bvalid(m_bvalid),.s_bready(m_bready));

  // ---------------- shadow memory (byte granular): DRAM 0x8000_0000..+16K,
  // scratch 0x0010_1000..+4K, CLINT mtimecmp 0x0200_4000..+8.
  reg [7:0] shadow [longint];
  function automatic [7:0] sh(input longint a);
    if (shadow.exists(a)) sh = shadow[a]; else sh = 8'h00;
  endfunction
  function automatic [63:0] smask(input [2:0] sz);
    smask = sz==0 ? 64'hff : sz==1 ? 64'hffff : sz==2 ? 64'hffff_ffff : 64'hffff_ffff_ffff_ffff;
  endfunction

  integer errors=0;
  task automatic fail(input string s);
    begin
      $display("FAIL t=%0t %s", $time, s); errors=errors+1;
      if (errors>10) $fatal(1, "FAIL SBA crossbar co-simulation: too many scoreboard errors");
    end
  endtask

  // ---------------- core address pool
  function automatic [31:0] core_addr(input [2:0] sz, output bit expect_err, output bit check);
    integer k; reg [31:0] a; reg [31:0] off;
    k = $urandom%10; off = ($urandom%64)*8 + (($urandom%8) & ~((1<<sz)-1));
    expect_err=0; check=1;
    case (k)
      0,1,2,3: a = 32'h8000_0000 + (off & ~32'h7);
      4,5: a = {`KARU_BOOT_SCRATCH_LO,12'h000} + off;
      6: a = 32'h0200_4000 + (off & 32'h7);
      7: begin a = 32'h0300_0000 + off; expect_err=1; check=0; end   // unmapped: DECERR
      8: begin a = 32'h0000_1000 + off; check=0; end                  // ROM
      default: a = 32'h8000_0000 + off;
    endcase
    core_addr = a;
  endfunction

  // ---------------- core read engine
  reg rd_out; reg [31:0] rd_a; reg [2:0] rd_sz; reg rd_err, rd_chk; reg [7:0] rd_beats;
  reg [3:0] rd_id;
  // ---------------- core write engine
  reg wr_aw_done, wr_w_done, wr_busy; reg [31:0] wr_a; reg [2:0] wr_sz; reg [63:0] wr_d; reg [7:0] wr_s;
  reg wr_err, wr_chk; reg [3:0] wr_id;
  assign quiet = !c_arvalid && !rd_out && !wr_busy;

  integer core_rd_n=0, core_wr_n=0, sba_n=0, imem_n=0;
  integer sba_ram_narrow_r=0, sba_ram_narrow_w=0, sba_ram_subdw=0, sba_dev_ok=0, sba_err_n=0;
  always @(posedge clk) begin
    if (rst) begin
      c_arvalid<=0; c_rready<=0; rd_out<=0; c_awvalid<=0; c_wvalid<=0; c_bready<=0; wr_busy<=0;
      wr_aw_done<=0; wr_w_done<=0;
    end else begin
      // ---- read channel
      c_rready <= (($urandom%4)!=0) || !rd_a[31];
      if (c_arvalid && c_arready) begin c_arvalid<=0; rd_out<=1; end
      if (c_rvalid && !rd_out) fail("core R without outstanding read");
      if (c_rvalid && c_rready) begin
        integer b; reg [63:0] exp; reg [31:0] base;
        if (c_rid !== rd_id) fail($sformatf("core RID %0h exp %0h", c_rid, rd_id));
        if (rd_err && c_rresp != 2'b11) fail($sformatf("core expected DECERR at %h got %0d", rd_a, c_rresp));
        if (!rd_err && c_rresp != 0) fail($sformatf("core unexpected rresp %0d at %h", c_rresp, rd_a));
        if (rd_chk) begin
          base = {rd_a[31:3],3'b0};
          for (b=0;b<8;b=b+1) exp[b*8+:8] = sh(base+b);
          for (b=0;b<8;b=b+1) if (b >= rd_a[2:0] && b < rd_a[2:0]+(1<<rd_sz))
            if (c_rdata[b*8+:8] !== exp[b*8+:8])
              fail($sformatf("core rdata %h byte %0d got %h exp %h", rd_a, b, c_rdata[b*8+:8], exp[b*8+:8]));
        end
        if ((c_rlast!==1'b1) !== (rd_beats!=0)) fail("core RLAST mismatch");
        if (rd_beats!=0) begin rd_beats<=rd_beats-1; rd_a <= rd_a+8; end
        else rd_out<=0;
        core_rd_n=core_rd_n+1;
      end
      if (!c_arvalid && !(rd_out && !(c_rvalid && c_rready && c_rlast)) && !pause &&
          ($urandom%CORE_RATE)==0) begin
        reg [2:0] sz; bit e, ch; reg [31:0] a; reg [3:0] nid;
        sz = $urandom%4;
        a = core_addr(sz, e, ch);
        if (a[31]) begin sz = 3; a = {a[31:3],3'b0}; end
        nid = $urandom;
        c_arvalid<=1; c_araddr<=a; c_arsize<=sz; c_arburst<=1; c_arprot<=3'b010; rd_id<=nid; c_arid<=nid;
        rd_a<=a; rd_sz<=sz; rd_err<=e; rd_chk<=ch;
        // occasional 8-beat line refill from DRAM
        if (a[31] && ($urandom%3)==0) begin
          c_araddr<={a[31:6],6'b0}; rd_a<={a[31:6],6'b0}; c_arlen<=7; rd_beats<=7;
        end else begin c_arlen<=0; rd_beats<=0; end
      end
      // ---- write channel
      c_bready <= ($urandom%3)!=0;
      if (c_awvalid && c_awready) begin c_awvalid<=0; wr_aw_done<=1; end
      if (c_wvalid && c_wready) begin c_wvalid<=0; wr_w_done<=1; end
      if (wr_busy && !c_wvalid && !wr_w_done && (c_awvalid || wr_aw_done) && ($urandom%2)) c_wvalid<=1;
      if (c_bvalid && !(wr_aw_done && wr_w_done)) fail("core B without completed AW/W");
      if (c_bvalid && c_bready) begin
        integer b;
        if (c_bid !== wr_id) fail("core BID mismatch");
        if (wr_err && c_bresp != 2'b11) fail($sformatf("core expected write DECERR at %h got %0d", wr_a, c_bresp));
        if (!wr_err && c_bresp != 0) fail($sformatf("core unexpected bresp %0d at %h", c_bresp, wr_a));
        if (wr_chk && !wr_err) for (b=0;b<8;b=b+1) if (wr_s[b]) shadow[{wr_a[31:3],3'b0}+b] = wr_d[b*8+:8];
        wr_busy<=0; wr_aw_done<=0; wr_w_done<=0; core_wr_n=core_wr_n+1;
      end
      if (!wr_busy && !pause && ($urandom%CORE_RATE)==0) begin
        reg [2:0] sz; bit e, ch; reg [31:0] a; reg [63:0] d; reg [7:0] s; reg [3:0] nid;
        sz = $urandom%4; a = core_addr(sz, e, ch);
        if (a < {`KARU_BOOT_SCRATCH_LO,12'h000} && a >= 32'h1000) begin e=0; ch=0; end // ROM write: dropped with OKAY
        d = {$urandom,$urandom};
        s = ((sz==0)?8'h01:(sz==1)?8'h03:(sz==2)?8'h0f:8'hff) << a[2:0];
        if (a[31]) begin s = $urandom; sz = 3; a = {a[31:3],3'b0}; end
        nid = $urandom;
        c_awvalid<=1; c_awaddr<=a; c_awsize<=sz; c_awlen<=0; c_awburst<=1; c_awprot<=3'b010;
        c_awid<=nid; wr_id<=nid;
        c_wdata<=d; c_wstrb<=s; c_wlast<=1; c_wvalid<=($urandom%2);
        wr_busy<=1; wr_a<=a; wr_sz<=sz; wr_d<=d; wr_s<=s; wr_err<=e; wr_chk<=ch;
      end
    end
  end

  // ---------------- SBA driver
  reg sba_out; reg [63:0] s_a, s_d; reg [2:0] s_sz; reg s_w; reg [2:0] s_experr; reg s_chk; reg s_ram;
  always @(posedge clk) begin
    if (rst) begin req_valid<=0; resp_ready<=0; sba_out<=0; end
    else begin
      resp_ready <= ($urandom%3)!=0;
      if (req_valid && req_ready) begin req_valid<=0; sba_out<=1; end
      if (resp_valid && !sba_out) fail("SBA response without request");
      if (resp_valid && resp_ready) begin
        integer b; reg [63:0] exp;
        if (resp_error !== s_experr)
          fail($sformatf("SBA %s %h sz%0d err %0d exp %0d", s_w?"W":"R", s_a, s_sz, resp_error, s_experr));
        if (!s_w && s_chk && s_experr==0) begin
          for (b=0;b<8;b=b+1) exp[b*8+:8] = sh(s_a[31:0]+b);
          if ((resp_data & smask(s_sz)) !== (exp & smask(s_sz)))
            fail($sformatf("SBA rdata %h sz%0d got %h exp %h", s_a, s_sz, resp_data & smask(s_sz), exp & smask(s_sz)));
        end
        if (s_w && s_chk && s_experr==0) for (b=0;b<8;b=b+1) if (b < (1<<s_sz)) shadow[s_a[31:0]+b] = s_d[b*8+:8];
        sba_out<=0; sba_n=sba_n+1;
        if (s_experr!=0) sba_err_n=sba_err_n+1;
        else if (s_ram && s_sz<3) begin
          if (s_w) sba_ram_narrow_w=sba_ram_narrow_w+1; else sba_ram_narrow_r=sba_ram_narrow_r+1;
          if (s_a[2:0]!=0) sba_ram_subdw=sba_ram_subdw+1;
        end else if (!s_ram) sba_dev_ok=sba_dev_ok+1;
      end
      if (SBA_RATE!=0 && !req_valid && !sba_out && !(resp_valid&&resp_ready) && ($urandom%SBA_RATE)==0) begin
        integer k; reg [63:0] a; reg [2:0] sz, e; reg w, ch; reg [31:0] off;
        sz = ($urandom%16==0) ? 4 : $urandom%4; w = $urandom%2;
        off = ($urandom%64)*8 + (($urandom%8) & ~((1<<(sz>3?3:sz))-1));
        k = $urandom%12; ch=1; e=0;
        case (k)
          0,1,2: a = 64'h8000_0000 + off;                              // DRAM, any size/offset
          3,4: a = {32'b0,`KARU_BOOT_SCRATCH_LO,12'h000} + off;          // scratch
          5: a = 64'h0200_4000 + (off & 7);                            // CLINT mtimecmp
          6: begin a = 64'h0012_0000 + off; e=2; ch=0; end             // private debug page
          7: begin a = 64'h0012_0800; e=2; ch=0; end
          8: begin a = 64'h1_8000_0000 + off; e=2; ch=0; end           // 33-bit alias of DRAM
          9: begin a = 64'h0000_1000 + off; ch=0; if (w) e=2; end      // ROM: read ok, write denied
          10: begin a = 64'h0300_0000 + off; e=2; ch=0; end            // unmapped
          default: a = 64'h8000_0000 + off + 1;                        // DRAM, possibly misaligned
        endcase
        if (sz>3) begin e=4; ch=0; end
        else if ((a[2:0] & ((1<<sz)-1)) != 0) begin e=3; ch=0; end
        req_valid<=1; req_addr<=a; req_data<={$urandom,$urandom}; req_size<=sz; req_write<=w;
        s_a<=a; s_sz<=sz; s_w<=w; s_experr<=e; s_chk<=ch; s_ram<=(a[63:32]==0 && a[31]);
      end
    end
  end
  always @(posedge clk) if (req_valid && req_ready) s_d <= req_data;

  // ---------------- imem random reads: untouched DRAM region 0x8000_8000.. and ROM
  reg i_out; reg [31:0] i_a;
  always @(posedge clk) begin
    if (rst) begin i_arvalid<=0; i_rready<=0; i_out<=0; end
    else begin
      i_rready <= ($urandom%3)!=0;
      if (i_arvalid && i_arready) begin i_arvalid<=0; i_out<=1; end
      if (i_rvalid && !i_out) fail("imem R without outstanding");
      if (i_rvalid && i_rready) begin
        if (i_rresp != 0) fail("imem rresp");
        if (i_a[31] && i_rdata !== {32'h1234_5678, i_a}) fail($sformatf("imem rdata %h got %h", i_a, i_rdata));
        i_out<=0; imem_n=imem_n+1;
      end
      if (!i_arvalid && !i_out && ($urandom%6)==0) begin
        reg [31:0] a;
        a = ($urandom%2) ? 32'h8000_8000 + ($urandom%64)*8 : 32'h0000_1000 + ($urandom%4)*8;
        i_arvalid<=1; i_araddr<=a; i_arid<=0; i_a<=a;
      end
    end
  end

  // ---------------- liveness
  integer idle_cnt=0;
  always @(posedge clk) if (!rst) begin
    if ((c_arvalid||rd_out||wr_busy||req_valid||sba_out||i_out) &&
        !(c_rvalid&&c_rready) && !(c_bvalid&&c_bready) && !(resp_valid&&resp_ready) &&
        !(i_rvalid&&i_rready) && !(req_valid&&req_ready))
      idle_cnt = idle_cnt+1; else idle_cnt = 0;
    if (idle_cnt > 3000)
      $fatal(1, "FAIL SBA crossbar co-simulation: no progress: bus state %0d c_arv %b rd_out %b wr_busy %b reqv %b sba_out %b pause %b quiet %b",
        bus.state, c_arvalid, rd_out, wr_busy, req_valid, sba_out, pause, quiet);
  end

  initial begin
    integer i; string why;
    if (!$value$plusargs("seed=%d", SEED)) SEED=1;
    if (!$value$plusargs("cycles=%d", CYCLES)) CYCLES=100000;
    if (!$value$plusargs("sba_rate=%d", SBA_RATE)) SBA_RATE=4;
    if (!$value$plusargs("core_rate=%d", CORE_RATE)) CORE_RATE=3;
    void'($urandom(SEED));
    for (i=0;i<8192;i=i+1) ram.ram[i] = 0;
    for (i=0;i<64;i=i+1) ram.ram[(32'h8000>>3)+i] = {32'h1234_5678, 32'h8000_8000 + i*8};
    for (i=0;i<8192;i=i+1) xbar.u_boot_mem.sram[i] = 0;
    for (i=0;i<8;i=i+1) shadow[32'h0200_4000+i] = 8'hff;   // mtimecmp resets to all ones
    repeat(8) @(posedge clk); rst=0;
    repeat(CYCLES) @(posedge clk);
    $display("DONE seed=%0d cycles=%0d errors=%0d xbar_fails=%0d core_rd=%0d core_wr=%0d imem=%0d sba=%0d sba_err=%0d sba_dev_ok=%0d sba_ram_narrow_r=%0d sba_ram_narrow_w=%0d sba_ram_subdw=%0d",
      SEED, CYCLES, errors, xbar.u_xbar_assert.fails, core_rd_n, core_wr_n, imem_n, sba_n, sba_err_n,
      sba_dev_ok, sba_ram_narrow_r, sba_ram_narrow_w, sba_ram_subdw);
    why = "";
    if (errors != 0) why = "scoreboard errors";
    else if (xbar.u_xbar_assert.fails != 0) why = "xbar assertion failures";
    else if (!xbar.u_xbar_assert.enabled || !xbar.u_xbar_assert.do_stop) why = "xbar assertions not armed (+no_assert*)";
    else if (core_rd_n == 0 || core_wr_n == 0 || imem_n == 0) why = "no core/imem traffic";
    else if (SBA_RATE == 0 && sba_n != 0) why = "SBA traffic while idle";
    else if (SBA_RATE != 0 && (sba_ram_narrow_r == 0 || sba_ram_narrow_w == 0 || sba_ram_subdw == 0 ||
                               sba_dev_ok == 0 || sba_err_n == 0))
      why = "SBA mix did not cover narrow/sub-doubleword DRAM, device and error cases";
    if (why != "") $fatal(1, "FAIL SBA crossbar co-simulation: %s", why);
    $display("PASS SBA crossbar co-simulation");
    $finish;
  end
endmodule

//  karu64.v
//  Top of the rearchitected RV64 core. Phase 2: single-issue,
//  in-order, AXI4 imem + dmem master ports, modular FUs.
//
//  Front-end decode feeds a one-entry ID/EX packet. Execute/writeback
//  control is driven from that packet, with bypass into the packet latch
//  for adjacent scalar dependencies.

`include "karu_ext.vh"
`include "karu_axi_defs.vh"
`include "karu_uop_defs.vh"
`include "karu_vcfg.vh"

module karu64 #(
    parameter [63:0] RESET_PC = 64'h0000_0000_8000_0000,
    parameter [31:0] RESET_SP = 32'h8001_0000,
    //  EXT_TIME=1: CSR `time` (rdtime, 0xC01) reads the external `time_in` (the SoC's
    //  CLINT mtime) instead of the raw cycle counter -- required so rdtime and the CLINT
    //  mtimecmp share one counter domain (Linux timer deadlines). EXT_TIME=0 (default)
    //  keeps the legacy behaviour (time == cycle counter), so non-CLINT builds are
    //  byte-identical and need not connect time_in.
    parameter        EXT_TIME = 0
) (
    input  wire         clk,
    input  wire         rst,
    output reg          trap    = 0,
    input  wire         irq,
    input  wire         irq_external_m,
    input  wire         irq_external_s,
    input  wire [63:0]  time_in,    //  CLINT mtime for rdtime (used when EXT_TIME=1)

    //  Legacy PMA hook. The ecp5karu profile has no L1 D-cache, so this is
    //  retained for wrapper compatibility and ignored.
    input  wire [31:0]  uncache_page,
    input  wire [31:0]  hpm_events,
    output wire         cache_flush_req,
    output wire         cache_flush_invalidate,
    input  wire         cache_flush_done,

    output wire [`AXI_ID_W-1:0]     imem_arid,
    output wire [`AXI_ADDR_W-1:0]   imem_araddr,
    output wire [`AXI_LEN_W-1:0]    imem_arlen,
    output wire [`AXI_SIZE_W-1:0]   imem_arsize,
    output wire [`AXI_BURST_W-1:0]  imem_arburst,
    output wire [`AXI_PROT_W-1:0]   imem_arprot,
    output wire                     imem_arvalid,
    input  wire                     imem_arready,
    input  wire [`AXI_ID_W-1:0]     imem_rid,
    input  wire [`AXI_DATA_W-1:0]   imem_rdata,
    input  wire [`AXI_RESP_W-1:0]   imem_rresp,
    input  wire                     imem_rlast,
    input  wire                     imem_rvalid,
    output wire                     imem_rready,

    output wire [`AXI_ID_W-1:0]     dmem_arid,
    output wire [`AXI_ADDR_W-1:0]   dmem_araddr,
    output wire [`AXI_LEN_W-1:0]    dmem_arlen,
    output wire [`AXI_SIZE_W-1:0]   dmem_arsize,
    output wire [`AXI_BURST_W-1:0]  dmem_arburst,
    output wire [`AXI_PROT_W-1:0]   dmem_arprot,
    output wire                     dmem_arvalid,
    input  wire                     dmem_arready,
    input  wire [`AXI_ID_W-1:0]     dmem_rid,
    input  wire [`AXI_DATA_W-1:0]   dmem_rdata,
    input  wire [`AXI_RESP_W-1:0]   dmem_rresp,
    input  wire                     dmem_rlast,
    input  wire                     dmem_rvalid,
    output wire                     dmem_rready,
    output wire [`AXI_ID_W-1:0]     dmem_awid,
    output wire [`AXI_ADDR_W-1:0]   dmem_awaddr,
    output wire [`AXI_LEN_W-1:0]    dmem_awlen,
    output wire [`AXI_SIZE_W-1:0]   dmem_awsize,
    output wire [`AXI_BURST_W-1:0]  dmem_awburst,
    output wire [`AXI_PROT_W-1:0]   dmem_awprot,
    output wire                     dmem_awvalid,
    input  wire                     dmem_awready,
    output wire [`AXI_DATA_W-1:0]   dmem_wdata,
    output wire [`AXI_STRB_W-1:0]   dmem_wstrb,
    output wire                     dmem_wlast,
    output wire                     dmem_wvalid,
    input  wire                     dmem_wready,
    input  wire [`AXI_ID_W-1:0]     dmem_bid,
    input  wire [`AXI_RESP_W-1:0]   dmem_bresp,
    input  wire                     dmem_bvalid,
    output wire                     dmem_bready
);
    wire _unused_irq = &{RESET_SP[0], 1'b0};

    //  ==================================================================
    //  IFU + RVC + DEC
    //  ==================================================================
    wire [1:0]  csr_priv;
    wire [63:0] csr_satp;
    wire        csr_status_sum, csr_status_mxr;
    wire [5:0]  csr_dpmlen;     //  Supm data-access pointer-mask length (0/7/16)
    wire        cbo_zero_en, cbo_cf_en, cbo_inval_en;   //  Zicbo per-class enable (priv+envcfg)
    wire        csr_tvm, csr_tw, csr_tsr;               //  mstatus trap-virtualization bits
    wire        sys_sfencevma;

    wire            ifu_valid;
    wire [63:0]     ifu_pc;
    wire [31:0]     ifu_w;
    wire            ifu_take;
    wire            ifu_redir;
    wire [63:0]     ifu_redir_pc;
    wire            ifu_xlate_req;
    wire [63:0]     ifu_xlate_va;
    wire            immu_done;
    wire            immu_fault;
    wire [63:0]     immu_fault_va;
    wire [63:0]     immu_fault_cause;
    wire [63:0]     immu_pa;
    wire            immu_busy;
    wire            ifu_fault_valid;
    wire [63:0]     ifu_fault_va;
    wire [63:0]     ifu_fault_cause;

    wire [`AXI_ID_W-1:0]        ifu_arid, immu_arid;
    wire [`AXI_ADDR_W-1:0]  ifu_araddr, immu_araddr;
    wire [`AXI_LEN_W-1:0]   ifu_arlen, immu_arlen;
    wire [`AXI_SIZE_W-1:0]  ifu_arsize, immu_arsize;
    wire [`AXI_BURST_W-1:0] ifu_arburst, immu_arburst;
    wire [`AXI_PROT_W-1:0]  ifu_arprot, immu_arprot;
    wire                    ifu_arvalid, immu_arvalid;
    wire                    ifu_arready, immu_arready;
    wire                    ifu_rready, immu_rready;
    wire                    immu_rvalid_w;
    //  The IFU's read-response inputs (from imem directly, or from the I-cache
    //  slave when KARU_ICACHE is set).
    wire [`AXI_ID_W-1:0]    ifu_rid_w;
    wire [`AXI_DATA_W-1:0]  ifu_rdata_w;
    wire [`AXI_RESP_W-1:0]  ifu_rresp_w;
    wire                    ifu_rlast_w, ifu_rvalid_w;
    wire                    icache_flush;   //  = sys_fencei (assigned after it is defined)
    //  Fetch-side read master after the optional I-cache. This and the IMMU
    //  share the external imem AXI read channel through the sticky arbiter below.
    wire [`AXI_ID_W-1:0]    ifm_arid;
    wire [`AXI_ADDR_W-1:0]  ifm_araddr;
    wire [`AXI_LEN_W-1:0]   ifm_arlen;
    wire [`AXI_SIZE_W-1:0]  ifm_arsize;
    wire [`AXI_BURST_W-1:0] ifm_arburst;
    wire [`AXI_PROT_W-1:0]  ifm_arprot;
    wire                    ifm_arvalid, ifm_arready, ifm_rready;
    wire                    ifm_rvalid_w;

`ifdef KARU_ICACHE
`ifndef KARU_ICACHE_KB
`define KARU_ICACHE_KB 4
`endif
    //  Optional read-only instruction cache between the IFU and imem.
    karu_icache #(.KB(`KARU_ICACHE_KB)) icache (
        .clk(clk), .rst(rst), .flush(icache_flush), .owns(),
        //  slave: the IFU's AXI read master
        .s_arid(ifu_arid),  .s_araddr(ifu_araddr),  .s_arlen(ifu_arlen),
        .s_arsize(ifu_arsize), .s_arburst(ifu_arburst), .s_arprot(ifu_arprot),
        .s_arvalid(ifu_arvalid), .s_arready(ifu_arready),
        .s_rid(ifu_rid_w),  .s_rdata(ifu_rdata_w),  .s_rresp(ifu_rresp_w),
        .s_rlast(ifu_rlast_w), .s_rvalid(ifu_rvalid_w), .s_rready(ifu_rready),
        //  master: the fetch side of the imem arbiter
        .m_arid(ifm_arid),  .m_araddr(ifm_araddr),  .m_arlen(ifm_arlen),
        .m_arsize(ifm_arsize), .m_arburst(ifm_arburst), .m_arprot(ifm_arprot),
        .m_arvalid(ifm_arvalid), .m_arready(ifm_arready),
        .m_rid(imem_rid),   .m_rdata(imem_rdata),   .m_rresp(imem_rresp),
        .m_rlast(imem_rlast), .m_rvalid(ifm_rvalid_w), .m_rready(ifm_rready)
    );
`else
    //  No I-cache: the IFU drives imem directly (byte-identical).
    assign ifm_arid     = ifu_arid;
    assign ifm_araddr   = ifu_araddr;
    assign ifm_arlen    = ifu_arlen;
    assign ifm_arsize   = ifu_arsize;
    assign ifm_arburst  = ifu_arburst;
    assign ifm_arprot   = ifu_arprot;
    assign ifm_arvalid  = ifu_arvalid;
    assign ifu_arready  = ifm_arready;
    assign ifm_rready   = ifu_rready;
    assign ifu_rid_w    = imem_rid;
    assign ifu_rdata_w  = imem_rdata;
    assign ifu_rresp_w  = imem_rresp;
    assign ifu_rlast_w  = imem_rlast;
    assign ifu_rvalid_w = ifm_rvalid_w;
`endif

    //  -------- imem arbiter with latched read ownership --------
    //  The instruction stream and the instruction-page-table walker share one
    //  AXI read channel. Ownership is latched when a request first asserts, then
    //  held through AR acceptance and RLAST, so an IMMU walk cannot change the
    //  AR payload while an IFU/I-cache request is stalled. Priority: IMMU > IFU.
    reg         im_rd_lock;
    reg         im_ar_done;
    reg         im_own_immu;
    wire        im_any_valid = immu_arvalid || ifm_arvalid;
    wire        im_sel_immu = immu_arvalid;
    wire        im_owner_immu = im_rd_lock ? im_own_immu : im_sel_immu;
    wire        im_owner_arvalid = im_owner_immu ? immu_arvalid : ifm_arvalid;
    wire        im_ar_fire = imem_arvalid && imem_arready;
    wire        im_r_last_fire = imem_rvalid && imem_rready && imem_rlast;

    always @(posedge clk) begin
        if (rst) begin
            im_rd_lock <= 1'b0;
            im_ar_done <= 1'b0;
        end else if (!im_rd_lock) begin
            if (im_any_valid) begin
                im_rd_lock <= 1'b1;
                im_ar_done <= im_ar_fire;
                im_own_immu <= im_sel_immu;
            end
        end else begin
            if (!im_ar_done && im_ar_fire)
                im_ar_done <= 1'b1;
            if ((im_ar_done || im_ar_fire) && im_r_last_fire) begin
                im_rd_lock <= 1'b0;
                im_ar_done <= 1'b0;
            end
        end
    end

    assign imem_arid    = im_owner_immu ? immu_arid     : ifm_arid;
    assign imem_araddr  = im_owner_immu ? immu_araddr   : ifm_araddr;
    assign imem_arlen   = im_owner_immu ? immu_arlen    : ifm_arlen;
    assign imem_arsize  = im_owner_immu ? immu_arsize   : ifm_arsize;
    assign imem_arburst = im_owner_immu ? immu_arburst  : ifm_arburst;
    assign imem_arprot  = im_owner_immu ? immu_arprot   : ifm_arprot;
    assign imem_arvalid = !im_ar_done && (im_rd_lock ? im_owner_arvalid : im_any_valid);
    assign immu_arready = (!im_ar_done &&  im_owner_immu) ? imem_arready : 1'b0;
    assign ifm_arready  = (!im_ar_done && !im_owner_immu) ? imem_arready : 1'b0;
    assign imem_rready  = im_owner_immu ? immu_rready : ifm_rready;
    assign immu_rvalid_w = im_rd_lock &&  im_own_immu && imem_rvalid;
    assign ifm_rvalid_w  = im_rd_lock && !im_own_immu && imem_rvalid;

    karu_ifu #(.RESET_PC(RESET_PC)) ifu (
        .clk(clk), .rst(rst),
        .redir(ifu_redir), .redir_pc(ifu_redir_pc),
        .ins_valid(ifu_valid), .ins_pc(ifu_pc), .ins_w(ifu_w),
        .take(ifu_take),
        .xlate_req(ifu_xlate_req), .xlate_va(ifu_xlate_va),
        .xlate_busy(immu_busy),
        .xlate_done(immu_done), .xlate_fault(immu_fault),
        .xlate_fault_va(immu_fault_va), .xlate_fault_cause(immu_fault_cause),
        .xlate_pa(immu_pa),
        .fault_valid(ifu_fault_valid), .fault_va(ifu_fault_va),
        .fault_cause(ifu_fault_cause),
        .arid(ifu_arid),      .araddr(ifu_araddr),
        .arlen(ifu_arlen),    .arsize(ifu_arsize),
        .arburst(ifu_arburst), .arprot(ifu_arprot),
        .arvalid(ifu_arvalid), .arready(ifu_arready),
        .rid(ifu_rid_w),      .rdata(ifu_rdata_w),
        .rresp(ifu_rresp_w),  .rlast(ifu_rlast_w),
        .rvalid(ifu_rvalid_w), .rready(ifu_rready)
    );

    wire [`AXI_ID_W-1:0]        immu_awid;
    wire [`AXI_ADDR_W-1:0]  immu_awaddr;
    wire [`AXI_LEN_W-1:0]   immu_awlen;
    wire [`AXI_SIZE_W-1:0]  immu_awsize;
    wire [`AXI_BURST_W-1:0] immu_awburst;
    wire [`AXI_PROT_W-1:0]  immu_awprot;
    wire                    immu_awvalid;
    wire                    immu_awready;
    wire [`AXI_DATA_W-1:0]  immu_wdata;
    wire [`AXI_STRB_W-1:0]  immu_wstrb;
    wire                    immu_wlast;
    wire                    immu_wvalid;
    wire                    immu_wready;
    wire                    immu_bready;

`ifdef KARU_EN_S
    karu_sv39 immu (
        .clk(clk), .rst(rst),
        .req(ifu_xlate_req), .va(ifu_xlate_va), .access(2'd0),
        .priv(csr_priv), .satp(csr_satp),
        .status_sum(csr_status_sum), .status_mxr(csr_status_mxr),
        .flush(sys_sfencevma),
        .done(immu_done), .fault(immu_fault),
        .fault_va(immu_fault_va), .fault_cause(immu_fault_cause),
        .pa(immu_pa), .busy(immu_busy),
        .arid(immu_arid), .araddr(immu_araddr), .arlen(immu_arlen),
        .arsize(immu_arsize), .arburst(immu_arburst), .arprot(immu_arprot),
        .arvalid(immu_arvalid), .arready(immu_arready),
        .rid(imem_rid), .rdata(imem_rdata), .rresp(imem_rresp),
        .rlast(imem_rlast), .rvalid(immu_rvalid_w), .rready(immu_rready),
        .awid(immu_awid), .awaddr(immu_awaddr), .awlen(immu_awlen),
        .awsize(immu_awsize), .awburst(immu_awburst), .awprot(immu_awprot),
        .awvalid(immu_awvalid), .awready(immu_awready),
        .wdata(immu_wdata), .wstrb(immu_wstrb), .wlast(immu_wlast),
        .wvalid(immu_wvalid), .wready(immu_wready),
        .bid(dmem_bid), .bresp(dmem_bresp), .bvalid(dmem_bvalid), .bready(immu_bready)
    );
`else
    assign immu_done        = ifu_xlate_req;
    assign immu_fault       = 1'b0;
    assign immu_fault_va    = 64'b0;
    assign immu_fault_cause = 64'b0;
    assign immu_pa          = ifu_xlate_va;
    assign immu_busy        = 1'b0;
    assign immu_arid        = {`AXI_ID_W{1'b0}};
    assign immu_araddr      = {`AXI_ADDR_W{1'b0}};
    assign immu_arlen       = {`AXI_LEN_W{1'b0}};
    assign immu_arsize      = {`AXI_SIZE_W{1'b0}};
    assign immu_arburst     = {`AXI_BURST_W{1'b0}};
    assign immu_arprot      = {`AXI_PROT_W{1'b0}};
    assign immu_arvalid     = 1'b0;
    assign immu_rready      = 1'b0;
    assign immu_awid        = {`AXI_ID_W{1'b0}};
    assign immu_awaddr      = {`AXI_ADDR_W{1'b0}};
    assign immu_awlen       = {`AXI_LEN_W{1'b0}};
    assign immu_awsize      = {`AXI_SIZE_W{1'b0}};
    assign immu_awburst     = {`AXI_BURST_W{1'b0}};
    assign immu_awprot      = {`AXI_PROT_W{1'b0}};
    assign immu_awvalid     = 1'b0;
    assign immu_wdata       = {`AXI_DATA_W{1'b0}};
    assign immu_wstrb       = {`AXI_STRB_W{1'b0}};
    assign immu_wlast       = 1'b0;
    assign immu_wvalid      = 1'b0;
    assign immu_bready      = 1'b0;
`endif

    wire is_c = (ifu_w[1:0] != 2'b11);
    wire [31:0] ins_unc;
`ifdef KARU_EN_C
    karu_rvc64 rvc (.c(ifu_w[15:0]), .out(ins_unc));
`else
    assign ins_unc = ifu_w;
`endif
    wire [31:0] dec_ins = is_c ? ins_unc : ifu_w;

    wire [3:0]  dec_unit;
    wire [4:0]  dec_sub;
    wire [4:0]  dec_rd, dec_rs1, dec_rs2, dec_rs3;
    wire [63:0] dec_imm;
    wire [1:0]  dec_size;
    wire        dec_sign_l, dec_use_imm, dec_use_pc, dec_is_w;
    wire [11:0] dec_csr_addr;
    wire        dec_rs1_is_f, dec_rs2_is_f, dec_rs3_is_f, dec_rd_is_f;
    wire        dec_fp_is_d;
    wire        dec_is_h;
    wire [3:0]  dec_fp_zfa;
    wire        dec_vm;
    wire [2:0]  dec_vfunct3;
    wire [5:0]  dec_vfunct6;

    karu_dec dec (
        .ins(dec_ins),
        .unit(dec_unit),      .sub(dec_sub),
        .rd(dec_rd), .rs1(dec_rs1), .rs2(dec_rs2), .rs3(dec_rs3),
        .imm(dec_imm),
        .size(dec_size),      .sign_l(dec_sign_l),
        .use_imm(dec_use_imm), .use_pc(dec_use_pc),
        .is_w(dec_is_w),      .csr_addr(dec_csr_addr),
        .rs1_is_f(dec_rs1_is_f), .rs2_is_f(dec_rs2_is_f),
        .rs3_is_f(dec_rs3_is_f), .rd_is_f(dec_rd_is_f),
        .fp_is_d(dec_fp_is_d), .is_h(dec_is_h), .fp_zfa(dec_fp_zfa), .vm(dec_vm),
        .vfunct3(dec_vfunct3), .vfunct6(dec_vfunct6)
    );

    //  ==================================================================
    //  Regfiles (integer + floating-point)
    //  ==================================================================
    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [63:0] wb_v;
    wire [63:0] xrs1_v, xrs2_v;

    karu_regfile rf (
        .clk(clk),
        .rs1(dec_rs1), .rs1_v(xrs1_v),
        .rs2(dec_rs2), .rs2_v(xrs2_v),
        .we(wb_we), .rd(wb_rd), .rd_v(wb_v)
    );

    wire        fwb_we;
    wire [4:0]  fwb_rd;
    wire [63:0] fwb_v;
    wire [63:0] frs1_v, frs2_v, frs3_v;

`ifdef KARU_EN_F
    karu_fregfile frf (
        .clk(clk),
        .rs1(dec_rs1), .rs1_v(frs1_v),
        .rs2(dec_rs2), .rs2_v(frs2_v),
        .rs3(dec_rs3), .rs3_v(frs3_v),
        .we(fwb_we), .rd(fwb_rd), .rd_v(fwb_v)
    );
`else
    //  F disabled: no f-regfile. The decoder traps every FP instruction so
    //  dec_*_is_f is always 0 and these reads are never selected.
    assign frs1_v = 64'b0;
    assign frs2_v = 64'b0;
    assign frs3_v = 64'b0;
`endif

    //  Combined source operands: pick f or x per decoder flag.
    wire [63:0] rs1_v = dec_rs1_is_f ? frs1_v : xrs1_v;
    wire [63:0] rs2_v = dec_rs2_is_f ? frs2_v : xrs2_v;

    //  Bypass current-cycle writeback into the ID/EX latch. This is safe
    //  because execute now reads the registered ex_* operands, not decoder
    //  operands, so there is no combinational regfile feedback loop.
    wire [63:0] id_xrs1_v = (wb_we && wb_rd != 5'd0 && wb_rd == dec_rs1) ? wb_v : xrs1_v;
    wire [63:0] id_xrs2_v = (wb_we && wb_rd != 5'd0 && wb_rd == dec_rs2) ? wb_v : xrs2_v;
    wire [63:0] id_frs1_v = (fwb_we && fwb_rd != 5'd0 && fwb_rd == dec_rs1) ? fwb_v : frs1_v;
    wire [63:0] id_frs2_v = (fwb_we && fwb_rd != 5'd0 && fwb_rd == dec_rs2) ? fwb_v : frs2_v;
    wire [63:0] id_frs3_v = (fwb_we && fwb_rd != 5'd0 && fwb_rd == dec_rs3) ? fwb_v : frs3_v;
    wire [63:0] id_rs1_v  = dec_rs1_is_f ? id_frs1_v : id_xrs1_v;
    wire [63:0] id_rs2_v  = dec_rs2_is_f ? id_frs2_v : id_xrs2_v;

    reg         ex_valid;
    reg [63:0]  ex_pc;
    reg [31:0]  ex_w;
    reg [31:0]  ex_ins;
    reg         ex_is_c;
    reg [3:0]   ex_unit;
    reg [4:0]   ex_sub;
    reg [4:0]   ex_rd, ex_rs1, ex_rs2, ex_rs3;
    reg [63:0]  ex_imm;
    reg [1:0]   ex_size;
    reg         ex_sign_l, ex_use_imm, ex_use_pc, ex_is_w;
    reg [11:0]  ex_csr_addr;
    reg         ex_rs1_is_f, ex_rs2_is_f, ex_rs3_is_f, ex_rd_is_f;
    reg         ex_fp_is_d;
    reg         ex_is_h;
    reg [3:0]   ex_fp_zfa;
    reg         ex_vm;
    reg [2:0]   ex_vfunct3;
    reg [5:0]   ex_vfunct6;
    reg [63:0]  ex_xrs1_v, ex_xrs2_v;
    reg [63:0]  ex_rs1_v, ex_rs2_v;
    reg [63:0]  ex_frs1_v, ex_frs2_v, ex_frs3_v;

    //  ==================================================================
    //  CSR
    //  ==================================================================
    wire        csr_req;
    wire [11:0] csr_addr;
    wire [63:0] csr_src;
    wire [4:0]  csr_sub;
    wire [4:0]  csr_rs1;
    wire [63:0] csr_rd_v;
    wire        csr_illegal;        //  unimplemented CSR -> illegal-instruction trap
    wire [63:0] trap_vec, ret_pc;
    wire        trap_req;
    wire [63:0] trap_epc;
    wire [63:0] trap_cause;
    wire [63:0] trap_tval;
    wire        mret_req;
    wire        sret_req;
    wire        csr_irq_pending;
    wire [63:0] csr_irq_cause;

    wire        fflags_set;
    wire [4:0]  fflags_in;
    wire [2:0]  csr_frm;

    //  Performance counters: free-running cycle + retire pulse for
    //  rdcycle / minstret. Driven from issue_* later in the file.
    reg  [63:0] perf_cyc;
    wire        perf_retire;
    always @(posedge clk) begin
        if (rst) perf_cyc <= 64'b0;
        else     perf_cyc <= perf_cyc + 64'b1;
    end
    //  rdtime source: the external CLINT mtime (EXT_TIME=1, CLINT SoCs) so rdtime and
    //  mtimecmp share one domain; else the cycle counter (legacy / non-CLINT builds).
    wire [63:0] csr_time_in = EXT_TIME ? time_in : perf_cyc;

    //  V-extension CSR-side wires (computed further below; declared here so
    //  the csr instance can bind them).
    wire [63:0] v_vl, v_vtype, v_vstart;
    //  vstart clear-on-retire pulse into karu_csr (assigned with the FU active
    //  flags below; declared before the csr instance so the port binds under
    //  iverilog).
    wire        v_op_retire;
    //  fault-only-first vl trim (vle*ff/vlseg*ff): the VLSU preflight found a
    //  fault past element 0, trimmed the op, and writes the reduced vl here
    //  (driven by the vlsu below; declared early for the csr port).
    wire        vlsu_trim_req;
    wire [31:0] vlsu_trim_vl;
    //  mstatus.FS/VS context-state tracking: field values out of the csr,
    //  conservative dirty pulses back in (assigned with the issue_* wires
    //  below; declared early so the csr ports bind under iverilog).
    wire [1:0]  status_fs, status_vs;
    wire        fp_dirty, v_dirty;
    wire [1:0]  v_vxrm;
    wire        varith_vxsat;   //  vector fixed-point op saturated (assigned below)
    wire        vset_req;
    wire [63:0] vset_vtype, vset_vl;

    karu_csr csr (
        .clk(clk), .rst(rst),
        .op_req(csr_req), .op_addr(csr_addr), .op_src(csr_src),
        .op_sub(csr_sub), .op_rs1(csr_rs1), .op_rd_v(csr_rd_v),
        .csr_illegal(csr_illegal),
        .trap_req(trap_req), .trap_epc(trap_epc), .trap_cause(trap_cause), .trap_tval(trap_tval),
        .trap_vec(trap_vec),
        .irq_timer(irq), .irq_external_m(irq_external_m),
        .irq_external_s(irq_external_s),
        .irq_pending(csr_irq_pending), .irq_cause(csr_irq_cause),
        .mret_req(mret_req), .sret_req(sret_req), .ret_pc(ret_pc), .priv_o(csr_priv),
        .satp_o(csr_satp), .status_sum_o(csr_status_sum), .status_mxr_o(csr_status_mxr),
        .dpmlen_o(csr_dpmlen),
        .cbo_zero_en_o(cbo_zero_en), .cbo_cf_en_o(cbo_cf_en), .cbo_inval_en_o(cbo_inval_en),
        .status_tvm_o(csr_tvm), .status_tw_o(csr_tw), .status_tsr_o(csr_tsr),
        .fflags_set(fflags_set), .fflags_in(fflags_in), .frm(csr_frm),
        .retire(perf_retire), .cyc_in(perf_cyc), .time_in(csr_time_in), .hpm_events(hpm_events),
        .vset_req(vset_req), .vset_vtype(vset_vtype), .vset_vl(vset_vl),
        .v_retire(v_op_retire),
        .vl_trim_req(vlsu_trim_req), .vl_trim_val({32'b0, vlsu_trim_vl}),
        .status_fs_o(status_fs), .status_vs_o(status_vs),
        .fp_dirty(fp_dirty), .v_dirty(v_dirty),
        .vl_o(v_vl), .vtype_o(v_vtype), .vstart_o(v_vstart),
        .vxsat_set(varith_vxsat), .vxrm_o(v_vxrm)
    );

    //  ==================================================================
    //  V extension: vset* (config), VRF, vmv.v.*
    //  ==================================================================
    //  -- vset*: decode vtype, compute VLMAX, clamp AVL -> vl --
    wire [10:0] v_vtype_imm = ex_imm[10:0];
    wire [10:0] v_vtype_src = (ex_sub == `VCFG_SETVL) ? ex_xrs2_v[10:0] : v_vtype_imm;
    wire [2:0]  v_vlmul = v_vtype_src[2:0];
    wire [2:0]  v_vsew  = v_vtype_src[5:3];
    wire        v_vta_n = v_vtype_src[6];
    wire        v_vma_n = v_vtype_src[7];
    wire        v_vtype_resv = (v_vtype_src[10:8] != 3'b0)
                           || (v_vsew > 3'b011) || (v_vlmul == 3'b100);
    wire [6:0]  v_base = (`KARU_VLENB) >> v_vsew;   //  VLEN/SEW elements
    reg  [9:0]  v_vlmax;
    always @(*) begin
        if (v_vlmul[2] == 1'b0) v_vlmax = {3'b0, v_base} << v_vlmul[1:0];   //  LMUL 1,2,4,8
        else                    v_vlmax = {3'b0, v_base} >> (3'd4 - v_vlmul[1:0]);  //  1/2,1/4,1/8
    end
    wire        v_vill = v_vtype_resv || (v_vlmax == 0);

    wire        v_rs1_x0 = (ex_rs1 == 5'd0);
    wire        v_rd_x0  = (ex_rd  == 5'd0);
    wire [63:0] v_avl =
        (ex_sub == `VCFG_SETIVLI) ? {59'b0, ex_rs1} :
        (!v_rs1_x0)                ? ex_xrs1_v :
        (!v_rd_x0)                 ? 64'hFFFF_FFFF_FFFF_FFFF :
                                     v_vl;
    wire [63:0] v_vl_new = v_vill ? 64'd0 :
                 ((v_avl > {54'b0, v_vlmax}) ? {54'b0, v_vlmax} : v_avl);
    assign vset_vtype = v_vill ? 64'h8000_0000_0000_0000 : {53'b0, v_vtype_src};
    assign vset_vl    = v_vl_new;

    //  -- VRF --
    wire [`KARU_VLEN-1:0]   vrf_v0;
    //  stage-3 granule source feed (doc/architecture.md)
    wire                    varith_rdu_gran, varith_rdu_vs1g, varith_rdu_vs2g;
    wire                    varith_rdu_voldg;
    wire                    varith_rdu_g1, varith_rdu_g2, varith_rdu_gv;
    wire [`KARU_VBUS_W-1:0] vrf_vs1_g, vrf_vs2_g, vrf_vold_g;
    //  RVV 3.7: a vector *arithmetic* instruction with nonzero vstart may raise
    //  an illegal-instruction exception (spec-permitted; this implementation
    //  takes it for all OP-V-issued execute units). Vector *memory* ops instead
    //  honor vstart inside the VLSU (prestart elements untouched). Declared up
    //  here (not with the issue_* wires) because issue_vkeccak/vcrypto_mode
    //  feed varith ports below and iverilog cannot elaborate that chain when
    //  this wire is declared after the instantiation.
    wire        v_vstart_ill = (ex_unit == `UNIT_VARITH || ex_unit == `UNIT_VFPU ||
                                ex_unit == `UNIT_VKECCAK || ex_unit == `UNIT_VCRYPTO) &&
                               (v_vstart != 64'd0);
    //  karu_varith drives the whole-register read addresses (group offset);
    //  declared here as they feed the VRF.
    wire        varith_req, varith_busy, varith_done, varith_wx;
    wire        varith_vsat;        //  any element saturated this op (valid at done)
    assign      varith_vxsat = varith_done && varith_vsat;
    wire [63:0] varith_x;
    wire [4:0]  varith_r_vs1, varith_r_vs2, varith_r_vold;
    //  karu_varith now also handles vector FP (OPFVV/OPFVF) -- one merged FU
    //  (the lanes carry karu_fpu). FP-specific outputs: fflags + the vfmv.f.s
    //  scalar f-register write.
    wire        varith_ff_set, varith_writes_f;
    wire [4:0]  varith_fflags;
    wire [63:0] varith_f_res;
    wire        varith_fp_lane_active;  //  debug/assert: lane FP unit(s) active
    //  Keccak (vkeccak) is folded into karu_varith (no separate FU): it reads via
    //  varith's r_vold and writes via the same VRF write path as every other op
    //  (the granule g_* port through S_CWB).
    //  Vector memory port <-> karu_mem (unified write-through L1). The scalar
    //  LSU and this 128-bit vector port share one coherent L1; karu_mem drives
    //  v_busy/v_done/v_rdata (instantiated below near the LSU).
    wire            vmem_req, vmem_busy, vmem_is_store, vmem_done;
    wire [63:0]     vmem_addr;      //  64-bit VA from the VLSU (V1); bare/identity
                                    //  today, truncated at the karu_mem physical port
    wire [127:0]    vmem_wdata, vmem_rdata;
    wire [15:0]     vmem_wstrb;

    //  vlsu <-> VRF granule ports. The granule-index width scales with VGRAN so a
    //  wider VLEN/VBUS (e.g. VLEN=512 => VGRAN=4 => 2-bit) is not silently
    //  truncated; karu_vlsu / adapter granule ports are parameterized to match.
    localparam VGW = (`KARU_VGRAN > 1) ? $clog2(`KARU_VGRAN) : 1;
    wire [4:0]  vg_rs, vg_wd;
    wire [VGW-1:0]  vg_rg, vg_wg;   //  granule index (1 bit at VGRAN=2)
    wire [127:0] vg_rdata, vg_wdata;
    wire        vg_we;

    //  karu_varith granule write port (the canonical write: the
    //  hot integer/FP paths write one VBUS_W granule per pulse instead of a
    //  256-bit whole register). (Pre-collapse this was tied off in the
    //  whole-reg vr_* port there). The adapter's single granule write port is
    //  shared varith/vlsu (single-issue: never concurrent) -- muxed by varith_busy.
    wire            varith_g_we, varith_g_wlast;
    wire [4:0]      varith_g_wd;
    wire [VGW-1:0]  varith_g_wg;
    wire [127:0]    varith_g_wdata;
    wire [15:0]     varith_g_wbe;
    //  VRF6 qualifiers (6a): varith reports per-write whether the tail-byte
    //  rule applies; vlsu granule writes stay unqualified (full-BE pre-merged)
    wire            varith_g_wb_vlgov, varith_g_wb_mdest;
    wire [2:0]      varith_g_wb_vsew;
    wire [15:0]     varith_g_wb_epr;
    //  Select by the WRITE SIGNAL, not *_busy: a unit's final granule write fires
    //  on the cycle its _busy drops, so a busy-gated select would lose it. varith
    //  and vlsu granule writes are mutually exclusive (single-issue).
    wire            gw_we    = varith_g_we | vg_we;
    wire [4:0]      gw_wd    = varith_g_we ? varith_g_wd    : vg_wd;
    wire [VGW-1:0]  gw_wg    = varith_g_we ? varith_g_wg    : vg_wg;
    wire [127:0]    gw_wdata = varith_g_we ? varith_g_wdata : vg_wdata;
    wire [15:0]     gw_wbe   = varith_g_we ? varith_g_wbe   : 16'hFFFF; //  vlsu: full granule
    wire            gw_wlast = varith_g_we ? varith_g_wlast : 1'b1;     //  vlsu: every write final
    wire            gw_wb_vlgov = varith_g_we ? varith_g_wb_vlgov : 1'b0;
    wire            gw_wb_mdest = varith_g_we ? varith_g_wb_mdest : 1'b0;
    wire [2:0]      gw_wb_vsew  = varith_g_wb_vsew;
    wire [15:0]     gw_wb_epr   = varith_g_wb_epr;
    //  The granule write port is shared single-issue; a simultaneous varith+vlsu
    //  write would silently drop the vlsu one (varith priority in the mux). This
    //  must never happen -- guard it (sim only; Vivado skips translate_off).
// synthesis translate_off
    always @(posedge clk) if (!rst && varith_g_we && vg_we) begin
        $display("[VRF-BRAM-ASSERT] WGN-MUX varith_g_we && vg_we (granule write collision) @%0t", $time);
        $finish;
    end
    //  Source-qualified rogue-write guards (the adapter can't tell varith from
    //  vlsu once muxed; these catch an idle/cross-unit granule write that the
    //  chk_vlsu attribution would otherwise absorb). A varith granule write while
    //  !varith_busy is legal ONLY as the op's final granule on the busy->idle edge
    //  (varith_busy drops the cycle that write commits). Requiring varith_busy_q
    //  (busy last cycle) catches a spurious idle write even if it falsely asserts
    //  g_wlast. A vlsu granule write must never occur during a varith op.
    reg varith_busy_q;
    always @(posedge clk) varith_busy_q <= !rst && varith_busy;
    always @(posedge clk) if (!rst && varith_g_we && !varith_busy
                               && (!varith_g_wlast || !varith_busy_q)) begin
        $display("[VRF-BRAM-ASSERT] WGN-IDLE rogue idle varith granule write (g_wlast=%b busy_q=%b) @%0t", varith_g_wlast, varith_busy_q, $time);
        $finish;
    end
    always @(posedge clk) if (!rst && vg_we && varith_busy) begin
        $display("[VRF-BRAM-ASSERT] WGN-XUNIT vlsu granule write during a varith op @%0t", $time);
        $finish;
    end
// synthesis translate_on

    //  vlsu_* are read by the KARU_EN_V vrf instance below (vlsu_busy) before the
    //  VLSU block declares them; keep the decl here (default_nettype none).
    wire        vlsu_req, vlsu_busy, vlsu_done;

    //  issue_v{keccak,crypto}_mode are read by the karu_varith instance below
    //  (.is_keccak / .is_vcrypto, ~line 882) before their assigns further down;
    //  hoist the decl so a strict front-end (Genus + default_nettype none) does
    //  not treat the forward port connection as an implicit net. Same reason as
    //  the vlsu_* hoist above; the drivers stay at unconditional module scope.
    wire        issue_vkeccak_mode, issue_vcrypto_mode;

`ifdef KARU_EN_V
    //  BRAM-backed VRF via the sequencing adapter (the only VRF since the
    //  2026-06-12 collapse). The adapter freezes karu_varith (vrf_op_stall)
    //  while it fills the granule operand latches from BRAM. Keyed off the
    //  *_busy outputs (combinational state!=IDLE) so the final-write cycle
    //  commits directly. See doc/architecture.md
    wire vrf_op_stall;
    karu_vrf_bram_wr vrf (
        .clk(clk), .rst(rst),
        .vr_rs(varith_r_vold),  //  old vd
        .vr_rs2(varith_r_vs1),  //  vs1 source
        .vr_rs3(varith_r_vs2),  //  vs2 source
        .vr_v0(vrf_v0),
        .src_g1(varith_rdu_g1), .src_g2(varith_rdu_g2), .src_gv(varith_rdu_gv),
        .src_vs1(varith_rdu_vs1g), .src_vs2(varith_rdu_vs2g),
        .src_vold(varith_rdu_voldg),
        .vs1_g(vrf_vs1_g), .vs2_g(vrf_vs2_g), .vold_g(vrf_vold_g),
        //  writes are granule-only now (g_* port); the whole-register vr_* WRITE
        //  port was deleted with the macro-VRF migration. vr_* READs remain.
        .g_rs(vg_rs), .g_rg(vg_rg), .g_rdata(vg_rdata),
        .g_we(gw_we), .g_wd(gw_wd), .g_wg(gw_wg), .g_wdata(gw_wdata),
        .g_wbe(gw_wbe), .g_wlast(gw_wlast),
        .wb_vlgov(gw_wb_vlgov), .wb_mdest(gw_wb_mdest),
        .wb_vl(v_vl[15:0]), .wb_vsew(gw_wb_vsew),
        .wb_greg(ex_rd), .wb_epr(gw_wb_epr),
        .varith_active(varith_busy), .vlsu_active(vlsu_busy),
        .op_stall(vrf_op_stall)
    );
`else
    assign vrf_v0  = {`KARU_VLEN{1'b0}};
    assign vg_rdata = 128'b0;
`endif

    //  -- vector load/store unit --
    //  mask (vlm/vsm): EEW=8, evl=ceil(vl/8), tail-agnostic.
    //  whole-reg (vl1re/vs1r): EEW=8, evl=VLENB (whole register).
    wire        vlsu_st = (ex_sub == `VLSU_VSE) || (ex_sub == `VLSU_VSM)
                        || (ex_sub == `VLSU_VSR) || (ex_sub == `VLSU_VSSE)
                        || (ex_sub == `VLSU_VSXE) || (ex_sub == `VLSU_VSSG);
    wire        vlsu_mask  = (ex_sub == `VLSU_VLM) || (ex_sub == `VLSU_VSM);
    wire        vlsu_whole = (ex_sub == `VLSU_VLR) || (ex_sub == `VLSU_VSR);
    wire        vlsu_indexed = (ex_sub == `VLSU_VLXE) || (ex_sub == `VLSU_VSXE);
    wire        vlsu_unitseg = (ex_sub == `VLSU_VLSG) || (ex_sub == `VLSU_VSSG);
    wire        vlsu_strided = (ex_sub == `VLSU_VLSE) || (ex_sub == `VLSU_VSSE) || vlsu_unitseg;
    wire        vlsu_pelem   = vlsu_indexed || vlsu_strided;    //  per-element engine
    //  segment field count nf (1..8) from the insn (vector LS is never RVC).
    //  For non-per-element ops the engine ignores it.
    wire [3:0]  vlsu_nf = {1'b0, ex_ins[31:29]} + 4'd1;
    //  data EEW: indexed uses vtype.SEW; strided/unit use the insn width field.
    //  mask/whole are byte streams (EEW=8).
    wire [1:0]  vlsu_eew = (vlsu_mask || vlsu_whole) ? 2'd0 :
                           vlsu_indexed ? v_vtype[4:3] : ex_size;
    wire [1:0]  vlsu_idx_eew = ex_size;                 //  index EEW (indexed only)
    wire [63:0] vlsu_vl  = vlsu_whole ? ({59'b0, vlsu_nf} * `KARU_VLENB) :  //  vl<nf>re: nf regs
                           vlsu_mask  ? ((v_vl + 64'd7) >> 3) : v_vl;
    //  vstart for the VLSU (prestart elements untouched, RVV 3.7). The unit
    //  counts it in its own EEW elements, so two op classes rescale:
    //  whole-register ops run as EEW=8 byte streams but architecturally count
    //  vstart in the *encoded* EEW (vl1re32 vstart=2 -> skip 8 bytes); mask
    //  ops (vlm/vsm) already count in bytes (EEW=8 elements). Anything past
    //  2^21 cannot index a real element (VLMAX max is 8*VLEN/8) -> saturate
    //  instead of letting the <<eew shift alias back into range.
    wire [31:0] vlsu_vstart = (|v_vstart[63:21]) ? 32'hFFFF_FFFF :
                              vlsu_whole ? (v_vstart[31:0] << ex_size) :
                                           v_vstart[31:0];
    //  mask loads (vlm): bytes past evl=ceil(vl/8) are left undisturbed (the
    //  ACT4 golden keeps the old register there and the length-suite check
    //  compares them as active at VLMAX). Other loads use vtype.vta.
    wire        vlsu_vta = vlsu_mask ? 1'b0 : v_vtype[6];
    //  register-group count = EMUL = (EEW/SEW) * LMUL. For indexed the data
    //  EMUL = LMUL (data EEW = SEW); for strided/unit it follows the insn EEW.
    //  Whole-reg = nf registers; mask = 1.
    wire [2:0]  vlsu_vlmul = v_vtype[2:0];
    wire signed [4:0] vlsu_lmul_s = vlsu_vlmul[2]
                        ? ($signed({3'b0, vlsu_vlmul[1:0]}) - 5'sd4)
                        : $signed({3'b0, vlsu_vlmul[1:0]});     //  000..011=0..3, 101..111=-3..-1
    wire signed [4:0] vlsu_deew_s = vlsu_indexed ? $signed({3'b0, v_vtype[4:3]})
                                                 : $signed({3'b0, ex_size});
    wire signed [4:0] vlsu_emul_s = vlsu_deew_s - $signed({2'b0, v_vtype[5:3]}) + vlsu_lmul_s;
    wire [3:0]  vlsu_nreg = vlsu_mask  ? 4'd1 :
                        vlsu_whole ? vlsu_nf :
                        (vlsu_emul_s <= 0) ? 4'd1 : (4'd1 << vlsu_emul_s[1:0]);
    //  index group register count (indexed): EMUL at the index EEW.
    wire signed [4:0] vlsu_iemul_s =
                        $signed({3'b0, ex_size}) - $signed({2'b0, v_vtype[5:3]}) + vlsu_lmul_s;
    wire [3:0]  vlsu_idx_nreg = (vlsu_iemul_s <= 0) ? 4'd1 : (4'd1 << vlsu_iemul_s[1:0]);
    //  stride: strided uses x[rs2] (full 64-bit, signed); unit-stride segment
    //  uses nf*EEW_bytes. (64-bit since phase V1 of doc/architecture.md.)
    wire [63:0] vlsu_stride = vlsu_unitseg ? ({60'b0, vlsu_nf} << vlsu_eew) : ex_xrs2_v;

    //  ---- targeted reserved-encoding checks (issue-time cause-2 traps) ----
    //  (a) vill: executing any vtype-dependent vector instruction with
    //  vtype.vill set raises illegal-instruction (RVV 3.4.4). The ONLY
    //  exemptions the spec grants are vset* (UNIT_VCFG, exempt by unit) and
    //  whole-register loads/stores -- NOT whole-register moves (vmv<nr>r.v
    //  traps with vill; spike agrees) and NOT vlm/vsm (they depend on vl).
    wire        v_vill_ill  = v_vtype[63] && (
                    (ex_unit == `UNIT_VARITH || ex_unit == `UNIT_VFPU ||
                     ex_unit == `UNIT_VKECCAK || ex_unit == `UNIT_VCRYPTO) ||
                    (ex_unit == `UNIT_VLSU && !vlsu_whole));
    //  (b) RVV 5.2 register-group overlap, indexed LOADS: vd (data EEW = SEW)
    //  overlapping vs2 (index EEW = insn width) is reserved unless the EEWs
    //  are equal (any overlap legal), the index is narrower with EMUL >= 1
    //  sitting in the highest-numbered part of the dest group, or the dest is
    //  narrower sitting in the lowest-numbered part of the index group.
    //  Indexed SEGMENT loads (nf > 1) allow no dest/index overlap at all
    //  (7.8.3). Matches spike (e.g. vluxei8 v4,(x),v4 at e32 is reserved:
    //  index EMUL = 1/4 < 1). Stores only read -> no overlap hazard.
    wire [6:0]  v_d_span   = {3'b0, vlsu_nf} * {3'b0, vlsu_nreg};   //  segment dest span
    wire [6:0]  v_d_end    = {2'b0, ex_rd}  + v_d_span;
    wire [6:0]  v_i_end    = {2'b0, ex_rs2} + {3'b0, vlsu_idx_nreg};
    wire        v_idx_ovl  = ({2'b0, ex_rd} < v_i_end) && ({2'b0, ex_rs2} < v_d_end);
    wire        v_ovl_eq   = (vlsu_eew == vlsu_idx_eew);
    wire        v_ovl_high = (vlsu_eew > vlsu_idx_eew) && (vlsu_iemul_s >= 0)
                          && (v_i_end == v_d_end);
    wire        v_ovl_low  = (vlsu_eew < vlsu_idx_eew) && (ex_rd == ex_rs2);
    wire        v_idxov_ill = (ex_unit == `UNIT_VLSU) && vlsu_indexed && !vlsu_st
                          && v_idx_ovl
                          && ((vlsu_nf != 4'd1) || !(v_ovl_eq || v_ovl_high || v_ovl_low));
    wire        v_resv_ill  = v_vill_ill || v_idxov_ill;
    //  ---- vector-FP SEW legality (Zvfhmin scope, 2026-06-13) ----
    //  The FP datapath supports SEW=32 (F) and SEW=64 (D). e8 is never legal.
    //  e16 is legal ONLY for the two Zvfhmin conversions (vfwcvt.f.f.v /
    //  vfncvt.f.f.w = VFUNARY0 .v, vs1[2:1]==10 f.f, vs1[4:3]==01 widen or 10
    //  narrow); full Zvfh arithmetic is NOT implemented and traps. (Closes a
    //  latent gap: e16 FP used to be silently mis-run as FP32 -- ACT4 never
    //  emits e16 FP, so it was never caught.)
    wire [2:0]  v_fp_sew    = v_vtype[5:3];
    //  EXACT vs1. Zvfhmin = {vfwcvt.f.f.v (01100), vfncvt.f.f.w (10100)} ONLY
    //  (confirmed against spike rv64gcv_zvfhmin). The e16 vfncvt.rod.f.f.w
    //  (10101) is round-to-odd narrowing -- full Zvfh, NOT Zvfhmin -> traps
    //  (base-V e64->e32 vfncvt.rod.f.f.w is separate and unaffected).
    //  vfwcvt.rod.f.f.v (01101) doesn't exist (widening is exact) -> traps.
    wire        v_is_zvfhmin = (ex_unit == `UNIT_VFPU) && (ex_vfunct3 == 3'b001)
                             && (ex_vfunct6 == 6'b010010)
                             && ((ex_rs1 == 5'b01100) || (ex_rs1 == 5'b10100));
    wire        v_fpsew_ill = (ex_unit == `UNIT_VFPU)
                           && ((v_fp_sew == 3'd0)                           //  e8: never
                            || ((v_fp_sew == 3'd1) && !v_is_zvfhmin));      //  e16: Zvfhmin only
    //  ---- V2 translation-preflight plumbing (doc/architecture.md) ----
    //  The VLSU translates every access through the shared DMMU before any
    //  side effect; the response wires are assigned at the dmmu block below
    //  (declared here so the vlsu ports bind under iverilog).
    wire        vxlate_req, vxlate_st;
    wire [63:0] vxlate_va;
    wire        vxlate_done, vxlate_fault;
    wire [63:0] vxlate_pa;
    wire        vlsu_fault_abort;
    //  fault-only-first qualifier straight from the encoding (lumop 10000 on
    //  a vector load): vle*ff decodes as VLSU_VLE and vlseg*ff as VLSU_VLSG,
    //  so no decoder change is needed -- the VLSU trims instead of trapping
    //  when a fault lands past element 0.
    wire        vlsu_ff = (ex_ins[6:0] == 7'b0000111) && (ex_ins[27:26] == 2'b00)
                        && (ex_ins[24:20] == 5'b10000);
`ifdef KARU_EN_V
    //  Supm pointer masking of the vector base (same transform as the scalar EA).
    wire [63:0] vlsu_base_pm =
        (csr_dpmlen == 6'd16) ? {{16{ex_xrs1_v[47]}}, ex_xrs1_v[47:0]} :
        (csr_dpmlen == 6'd7)  ? {{7{ex_xrs1_v[56]}}, ex_xrs1_v[56:0]} :
                                ex_xrs1_v;
    karu_vlsu vlsu (
        .clk(clk), .rst(rst),
        .req(vlsu_req), .busy(vlsu_busy),
        .is_store(vlsu_st),
        //  Supm: the vector base pointer is pointer-masked like a scalar data
        //  address (per-element offsets are then added to the masked base).
        .base(vlsu_base_pm), .vd(ex_rd), .eew(vlsu_eew),
        .vl(vlsu_vl), .vstart(vlsu_vstart), .vta(vlsu_vta),
        .vm(ex_vm), .vma(v_vtype[7]), .nreg(vlsu_nreg), .v0mask(vrf_v0), .done(vlsu_done),
        .pelem(vlsu_pelem), .indexed(vlsu_indexed), .stride(vlsu_stride), .nf(vlsu_nf),
        .idx_vs(ex_rs2), .idx_eew(vlsu_idx_eew), .idx_nreg(vlsu_idx_nreg),
        .ff(vlsu_ff),
        .xlate_req(vxlate_req), .xlate_va(vxlate_va), .xlate_st(vxlate_st),
        .xlate_done(vxlate_done), .xlate_fault(vxlate_fault), .xlate_pa(vxlate_pa),
        .fault_abort(vlsu_fault_abort),
        .trim_req(vlsu_trim_req), .trim_vl(vlsu_trim_vl),
        .vmem_req(vmem_req), .vmem_busy(vmem_busy), .vmem_is_store(vmem_is_store),
        .vmem_addr(vmem_addr), .vmem_wdata(vmem_wdata), .vmem_wstrb(vmem_wstrb),
        .vmem_done(vmem_done), .vmem_rdata(vmem_rdata),
        .vg_rs(vg_rs), .vg_rg(vg_rg), .vg_rdata(vg_rdata),
        .vg_we(vg_we), .vg_wd(vg_wd), .vg_wg(vg_wg), .vg_wdata(vg_wdata)
    );
`else
    //  V disabled: vlsu absent. issue_vlsu is permanently 0, so vlsu_active
    //  never sets; tie off the signals consumed elsewhere (vmem master port
    //  backend, VRF granule write port, DMMU share, trim/fault paths).
    assign vlsu_busy = 1'b0;
    assign vlsu_done = 1'b0;
    assign vmem_req = 1'b0; assign vmem_is_store = 1'b0;
    assign vmem_addr = 64'b0; assign vmem_wdata = 128'b0; assign vmem_wstrb = 16'b0;
    assign vg_rs = 5'b0; assign vg_rg = {VGW{1'b0}};
    assign vg_we = 1'b0; assign vg_wd = 5'b0; assign vg_wg = {VGW{1'b0}}; assign vg_wdata = 128'b0;
    assign vxlate_req = 1'b0; assign vxlate_st = 1'b0; assign vxlate_va = 64'b0;
    assign vlsu_fault_abort = 1'b0;
    assign vlsu_trim_req = 1'b0; assign vlsu_trim_vl = 32'b0;
    wire _unused_vlsu_ff = vlsu_ff;
`endif

    //  -- vector integer/mask arithmetic (multi-cycle: one group reg / cycle) --
    //  number of registers in the group (LMUL); fractional LMUL -> 1
    wire [2:0]  varith_vlmul = v_vtype[2:0];
    wire [3:0]  varith_nreg = varith_vlmul[2] ? 4'd1 : (4'd1 << varith_vlmul[1:0]);
`ifdef KARU_EN_V
    karu_varith varith_u (
        .clk(clk), .rst(rst), .req(varith_req), .busy(varith_busy), .done(varith_done),
        .vfunct3(ex_vfunct3), .vfunct6(ex_vfunct6),
        .vsew(v_vtype[5:3]), .vlmul(varith_vlmul), .vl(v_vl[31:0]), .vta(v_vtype[6]), .vma(v_vtype[7]),
        .vxrm(v_vxrm), .vsat(varith_vsat),
        .vm(ex_vm), .imm(ex_imm), .rs1_v(ex_xrs1_v), .nreg(varith_nreg), .v0(vrf_v0),
        .vd_base(ex_rd), .vs1_base(ex_rs1), .vs2_base(ex_rs2),
        .r_vs1(varith_r_vs1), .r_vs2(varith_r_vs2), .r_vold(varith_r_vold),
        .writes_x(varith_wx), .x_res(varith_x),
        //  -- vector FP (OPFVV/OPFVF) --
        .frm(csr_frm), .frs1_v(ex_frs1_v),
        .fflags_set(varith_ff_set), .fflags(varith_fflags),
        .writes_f(varith_writes_f), .f_res(varith_f_res),
        .fp_lane_active(varith_fp_lane_active),
        //  -- experimental single-instruction Keccak-f1600 (vkeccak), folded in --
        .is_keccak(issue_vkeccak_mode),
        //  -- standard vector crypto (Zvk*) -- registered ex_sub, NOT dec_sub,
        //  so the cop selector is stable for the whole multi-cycle op --
        .is_vcrypto(issue_vcrypto_mode), .vcrypto_cop(ex_sub)
        , .op_stall(vrf_op_stall)   //  BRAM-VRF operand-fill freeze
        //  canonical granule write port (hot integer/FP paths)
        , .g_we(varith_g_we), .g_wd(varith_g_wd), .g_wg(varith_g_wg)
        , .g_wdata(varith_g_wdata), .g_wbe(varith_g_wbe), .g_wlast(varith_g_wlast)
        , .g_wb_vlgov(varith_g_wb_vlgov), .g_wb_mdest(varith_g_wb_mdest)
        , .g_wb_vsew(varith_g_wb_vsew), .g_wb_epr(varith_g_wb_epr)
        //  stage-3 granule source feed
        , .rdu_gran(varith_rdu_gran), .rdu_vs1_g(varith_rdu_vs1g)
        , .rdu_vs2_g(varith_rdu_vs2g), .rdu_vold_g(varith_rdu_voldg)
        , .rdu_g1(varith_rdu_g1), .rdu_g2(varith_rdu_g2), .rdu_gv(varith_rdu_gv)
        , .vs1_g(vrf_vs1_g), .vs2_g(vrf_vs2_g), .vold_g(vrf_vold_g)
    );
`else
    //  V disabled: vector arith absent. issue_varith permanently 0.
    assign varith_busy = 1'b0;  assign varith_done = 1'b0;
    assign varith_vsat = 1'b0;
    assign varith_wx = 1'b0;    assign varith_x = 64'b0;
    assign varith_r_vs1 = 5'b0; assign varith_r_vs2 = 5'b0; assign varith_r_vold = 5'b0;
    assign varith_ff_set = 1'b0;    assign varith_fflags = 5'b0;
    assign varith_writes_f = 1'b0;  assign varith_f_res = 64'b0;
    assign varith_fp_lane_active = 1'b0;
    //  granule write port: absent without vector, but varith_g_we feeds the
    //  karu_assert checker (bind + htif instance) unconditionally -- tie the
    //  whole port off so the scalar build has no undriven nets / X into the SVA.
    assign varith_g_we = 1'b0;          assign varith_g_wlast = 1'b0;
    assign varith_g_wd = 5'b0;          assign varith_g_wg = {VGW{1'b0}};
    assign varith_g_wdata = 128'b0;     assign varith_g_wbe = 16'b0;
    assign varith_g_wb_vlgov = 1'b0;    assign varith_g_wb_mdest = 1'b0;
    assign varith_g_wb_vsew = 3'b0;     assign varith_g_wb_epr = 16'b0;
`endif

    //  -- experimental single-instruction Keccak-f1600 (vkeccak) --
    //  No separate FU: folded into karu_varith as a keccak mode (is_keccak),
    //  using its VRF read/write ports. One isolated 1600-bit permutation,
    //  instantiated inside karu_varith under KARU_EN_KECCAK.

    //  ==================================================================
    //  ALU (combinational)
    //  ==================================================================
    wire [63:0] alu_op1 = ex_use_pc ? ex_pc : ex_rs1_v;
    wire [63:0] alu_op2 = ex_use_imm ? ex_imm : ex_rs2_v;
    wire [63:0] alu_out;

    karu_alu alu (.op1(alu_op1), .op2(alu_op2), .sub(ex_sub),
                 .is_w(ex_is_w), .out(alu_out));

    //  scalar bitmanip (Zba/Zbb/Zbs) -- single-cycle peer of the ALU; op1=rs1
    //  (never pc), op2 reuses the ALU's imm/rs2 select for the immediate forms.
    wire [63:0] bm_out;
`ifdef KARU_EN_B
    karu_bitmanip bm (.op1(ex_rs1_v), .op2(alu_op2), .sub(ex_sub),
                 .is_w(ex_is_w), .out(bm_out));
`else
    assign bm_out = 64'b0;
`endif

    //  ==================================================================
    //  BRU
    //  ==================================================================
    wire        eq   = (ex_rs1_v == ex_rs2_v);
    wire        ltu  = (ex_rs1_v <  ex_rs2_v);
    wire        lts  = (ex_rs1_v[63] == 1'b1 && ex_rs2_v[63] == 1'b0) ||
                       ((ex_rs1_v[63] == ex_rs2_v[63]) && ltu);
    reg         bru_taken;
    always @(*) begin
        case (ex_sub)
            `BRU_BEQ:   bru_taken = eq;
            `BRU_BNE:   bru_taken = !eq;
            `BRU_BLT:   bru_taken = lts;
            `BRU_BGE:   bru_taken = !lts;
            `BRU_BLTU:  bru_taken = ltu;
            `BRU_BGEU:  bru_taken = !ltu;
            `BRU_JAL:   bru_taken = 1'b1;
            `BRU_JALR:  bru_taken = 1'b1;
            default:    bru_taken = 1'b0;
        endcase
    end
    wire [63:0] bru_target =
        (ex_sub == `BRU_JALR) ? ((ex_rs1_v + ex_imm) & ~64'b1) :
                                  (ex_pc + ex_imm);
    wire [63:0] pc_next = ex_pc + (ex_is_c ? 64'd2 : 64'd4);

    //  ==================================================================
    //  LSU
    //  ==================================================================
    wire        lsu_req;
    wire        lsu_req_pa;
    wire        lsu_busy;
    wire        lsu_done;
    wire [63:0] lsu_rd_v;
    wire        dmmu_req;
    wire        dmmu_done;
    wire        dmmu_fault;
    wire [63:0] dmmu_fault_va;
    wire [63:0] dmmu_fault_cause;
    wire [63:0] dmmu_pa;
    wire        dmmu_busy;
    reg [63:0]  lsu_pa_q;
    reg         lsu_xlate_active;
    //  --- cross-page misaligned: second-page (beat-2) translation ---
    //  A misaligned access whose two 64-bit beats straddle a 4 KiB page must
    //  translate the SECOND page separately; otherwise karu_lsu's beat-2
    //  (addr & ~7)+8 lands on the physically-adjacent frame, not translate(VA+8).
    reg         lsu_xlate2_active;  //  beat-2 page walk in progress
    reg         lsu_walk2_armed;    //  beat-2 walk request not yet issued
    reg         lsu_xpage_q;        //  latched: the access straddles a page
    reg [63:0]  lsu_va2_q;          //  latched: beat-2 VA = (lsu_addr & ~7) + 8
    reg [1:0]   lsu_acc2_q;         //  latched: DMMU access type for the beat-2 walk
    wire [63:0] lsu_pa_w;   //  assigned after lsu_addr (bare-mode uses VA directly)

    wire        lsu_is_store = (ex_sub == `LSU_STORE) || (ex_sub == `LSU_FSTORE);
    wire        lsu_is_cboz  = (ex_sub == `LSU_CBOZERO);    //  cbo.zero (store-class)
    wire        lsu_is_cbocf    = (ex_sub == `LSU_CBOCF);   //  cbo.clean/flush (R|W)
    wire        lsu_is_cboinval = (ex_sub == `LSU_CBOINVAL);    //  cbo.inval (store-class)
    wire        lsu_is_cbo   = lsu_is_cboz || lsu_is_cbocf || lsu_is_cboinval;
    wire        lsu_is_fload = (ex_sub == `LSU_FLOAD);
    //  For A-extension: address is just rs1 (no displacement). All other
    //  LSU ops use rs1 + imm.
    wire        lsu_is_atomic = (ex_sub == `LSU_LR) || (ex_sub == `LSU_SC)
        || (ex_sub >= `LSU_AMOSWAP && ex_sub <= `LSU_AMOMAXU);
    wire [63:0] lsu_addr_raw = lsu_is_atomic ? ex_xrs1_v : (ex_xrs1_v + ex_imm);
    //  Supm pointer masking: for explicit data accesses (loads/stores/AMO/cbo),
    //  the top PMLEN bits of the effective address are replaced with bit
    //  (XLEN-1-PMLEN) -- a canonical sign-extension that lets software tag the
    //  high bits. Applied here, before translation; never to instruction fetch.
    wire [63:0] lsu_addr =
        (csr_dpmlen == 6'd16) ? {{16{lsu_addr_raw[47]}}, lsu_addr_raw[47:0]} :
        (csr_dpmlen == 6'd7)  ? {{7{lsu_addr_raw[56]}}, lsu_addr_raw[56:0]} :
                                lsu_addr_raw;
    //  Bare-mode data access: no translation, PA=VA. When S-mode/Sv39 is
    //  compiled out this is always true, letting hierarchy prune the DMMU.
`ifdef KARU_EN_S
    //  Bypass the registered DMMU handshake so the LSU starts in the issue cycle
    //  (~1 cycle/op saved -- the common case for M-mode firmware/CoreMark).
    //  Condition matches karu_sv39's bare_mode exactly.
    wire        lsu_bare = (csr_priv == 2'd3) || (csr_satp[63:60] != 4'd8);
`else
    wire        lsu_bare = 1'b1;
`endif
    //  Beat-1 PA. Cross-page: PA1 was captured into lsu_pa_q at walk-1 done and
    //  must NOT be re-taken from dmmu_pa (which now holds the walk-2 result, PA2).
    assign      lsu_pa_w = lsu_bare    ? lsu_addr :
                           lsu_xpage_q ? lsu_pa_q  :
                                         (dmmu_done ? dmmu_pa : lsu_pa_q);
    //  Beat-2 base PA for a misaligned access whose two halves straddle an
    //  8-byte boundary. Within one 4 KiB page (or bare) this is just the next
    //  aligned 8-byte block, (PA & ~7) + 8; a page-crossing access uses the
    //  SECOND page's translation (PA2 = dmmu_pa at walk-2 done, when the LSU
    //  latches addr2 via lsu_req_pa).
    wire [63:0] lsu_pa2_samepage = {lsu_pa_w[63:3], 3'b000} + 64'd8;
    wire [63:0] lsu_addr2 = lsu_xpage_q ? dmmu_pa : lsu_pa2_samepage;
    //  FSW writes the low 32 bits of the f-reg; FSD writes all 64.
    wire [63:0] lsu_wdata    = (ex_sub == `LSU_FSTORE)
        ? (ex_fp_is_d ? ex_frs2_v : {32'b0, ex_frs2_v[31:0]})
        : ex_xrs2_v;
    wire [1:0]  lsu_size     = ex_size;
    wire        lsu_sign     = ex_sign_l;

    //  DMMU access type for this op (load=1 / store=2 / R|W cbo.clean-flush=3),
    //  matching the inline mux at the dmmu instance; latched for the beat-2 walk.
    wire [1:0]  lsu_acc = lsu_is_cbocf ? 2'd3 :
                (lsu_is_store || lsu_is_atomic || lsu_is_cboz || lsu_is_cboinval)
                    ? 2'd2 : 2'd1;
    //  The access straddles a 4 KiB page iff offset + size > 0x1000 (translated
    //  mode only). size = 1<<lsu_size bytes. A page cross is always also an
    //  8-byte-beat cross, so karu_lsu takes its two-beat path and needs PA2.
    wire [12:0] lsu_acc_end = {1'b0, lsu_addr[11:0]} + (13'd1 << lsu_size);
    wire        lsu_xpage   = !lsu_bare && (lsu_acc_end > 13'h1000);

    //  Pulse a SECOND scalar walk for the beat-2 page of a cross-page access:
    //  the first idle cycle after walk-1 completed (armed, region active).
    //  (Declared here, not inside the KARU_EN_S DMMU block, because dmmu_req_lsu
    //  below references it in every build; dmmu_busy is tied 0 under KARU_NO_S
    //  and lsu_xlate2_active never sets there, so this is a constant 0.)
    wire        lsu_walk2_start = lsu_xlate2_active && lsu_walk2_armed && !dmmu_busy;
    //  Expected scalar DMMU VA this cycle (walk-1: masked EA; walk-2: latched
    //  beat-2 VA) -- consumed by karu_assert INV29.
    wire [63:0] lsu_dmmu_va_exp = lsu_walk2_start ? lsu_va2_q : lsu_addr;

    reg         lsu_active;
    reg [4:0]   lsu_rd_pending;
    reg         lsu_was_store;
    reg         lsu_was_fload;
    reg         lsu_was_fload_d;    //  1 if FLD (no NaN-box on writeback)
    reg         lsu_was_fload_h;    //  1 if FLH (Zfhmin: NaN-box upper 48)

    wire [`AXI_ID_W-1:0]        lsu_arid, dmmu_arid;
    wire [`AXI_ADDR_W-1:0]  lsu_araddr, dmmu_araddr;
    wire [`AXI_LEN_W-1:0]   lsu_arlen, dmmu_arlen;
    wire [`AXI_SIZE_W-1:0]  lsu_arsize, dmmu_arsize;
    wire [`AXI_BURST_W-1:0] lsu_arburst, dmmu_arburst;
    wire [`AXI_PROT_W-1:0]  lsu_arprot, dmmu_arprot;
    wire                    lsu_arvalid, dmmu_arvalid;
    wire                    dmmu_arready;
    wire                    lsu_rready, dmmu_rready;
    wire [`AXI_ID_W-1:0]        lsu_awid, dmmu_awid;
    wire [`AXI_ADDR_W-1:0]  lsu_awaddr, dmmu_awaddr;
    wire [`AXI_LEN_W-1:0]   lsu_awlen, dmmu_awlen;
    wire [`AXI_SIZE_W-1:0]  lsu_awsize, dmmu_awsize;
    wire [`AXI_BURST_W-1:0] lsu_awburst, dmmu_awburst;
    wire [`AXI_PROT_W-1:0]  lsu_awprot, dmmu_awprot;
    wire                    lsu_awvalid, dmmu_awvalid;
    wire                    dmmu_awready;
    wire [`AXI_DATA_W-1:0]  lsu_wdata_o, dmmu_wdata;
    wire [`AXI_STRB_W-1:0]  lsu_wstrb, dmmu_wstrb;
    wire                    lsu_wlast, dmmu_wlast;
    wire                    lsu_wvalid, dmmu_wvalid;
    wire                    dmmu_wready;
    wire                    lsu_bready, dmmu_bready;
    //  karu_mem (unified write-through L1) master, arbitrated onto dmem below.
    //  The scalar LSU and vector port go THROUGH karu_mem; the dmmu/immu page-
    //  table walkers bypass it (PTW reads are physical, and write-through keeps
    //  memory coherent so the walkers see the latest PTEs without snooping).
    wire [`AXI_ID_W-1:0]    km_arid;
    wire [`AXI_ADDR_W-1:0]  km_araddr;
    wire [`AXI_LEN_W-1:0]   km_arlen;
    wire [`AXI_SIZE_W-1:0]  km_arsize;
    wire [`AXI_BURST_W-1:0] km_arburst;
    wire [`AXI_PROT_W-1:0]  km_arprot;
    wire                    km_arvalid, km_arready, km_rready;
    wire [`AXI_ID_W-1:0]    km_awid;
    wire [`AXI_ADDR_W-1:0]  km_awaddr;
    wire [`AXI_LEN_W-1:0]   km_awlen;
    wire [`AXI_SIZE_W-1:0]  km_awsize;
    wire [`AXI_BURST_W-1:0] km_awburst;
    wire [`AXI_PROT_W-1:0]  km_awprot;
    wire                    km_awvalid, km_awready;
    wire [`AXI_DATA_W-1:0]  km_wdata;
    wire [`AXI_STRB_W-1:0]  km_wstrb;
    wire                    km_wlast, km_wvalid, km_wready, km_bready;
    //  karu_mem slave-side responses back to the scalar LSU.
    wire [`AXI_ID_W-1:0]    km_s_rid, km_s_bid;
    wire [`AXI_DATA_W-1:0]  km_s_rdata;
    wire [`AXI_RESP_W-1:0]  km_s_rresp, km_s_bresp;
    wire                    km_s_rlast, km_s_rvalid, km_s_arready;
    wire                    km_s_awready, km_s_wready, km_s_bvalid;

    //  -------- dmem arbiter with latched per-channel ownership --------
    //  Read masters: dmmu (PTW line reads) and km (L1). Write masters: dmmu and
    //  immu (PTE A/D writeback) and km (write-through). immu never READS on dmem
    //  (it reads PTEs via the imem master). Ownership is latched when a request
    //  first asserts, not when AR/AW is accepted, so a higher-priority PTW cannot
    //  change the AXI payload while VALID is held against downstream backpressure.
    //  The grant is then held until RLAST / B for response routing. Grant priority:
    //  dmmu > immu > km. Read and write channels are independent (the dmem slave
    //  handles concurrent R and W).
    reg         rd_lock;        //  a read grant is active
    reg         rd_ar_done;     //  active read AR has been accepted
    reg         rd_own_dmmu;    //  owner when locked: 1=dmmu, 0=km
    reg         wr_lock;        //  a write grant is active
    reg         wr_aw_done;     //  active write AW has been accepted
    reg [1:0]   wr_own;         //  owner when locked: 2=dmmu, 1=immu, 0=km
    wire        rd_any_valid = dmmu_arvalid || km_arvalid;
    wire        wr_any_valid = dmmu_awvalid || immu_awvalid || km_awvalid;
    wire        rd_sel_dmmu = dmmu_arvalid;                 //  read grant: dmmu over km
    wire [1:0]  wr_sel = dmmu_awvalid ? 2'd2 : immu_awvalid ? 2'd1 : 2'd0;
    wire        rd_owner_dmmu = rd_lock ? rd_own_dmmu : rd_sel_dmmu;
    wire [1:0]  wr_owner      = wr_lock ? wr_own      : wr_sel;
    wire        rd_owner_arvalid = rd_owner_dmmu ? dmmu_arvalid : km_arvalid;
    wire        wr_owner_awvalid = (wr_owner == 2'd2) ? dmmu_awvalid :
                                 (wr_owner == 2'd1) ? immu_awvalid : km_awvalid;
    wire        rd_ar_fire = dmem_arvalid && dmem_arready;
    wire        rd_r_last_fire = dmem_rvalid && dmem_rready && dmem_rlast;
    wire        wr_aw_fire = dmem_awvalid && dmem_awready;
    wire        wr_b_fire = dmem_bvalid && dmem_bready;

    always @(posedge clk) begin
        if (rst) begin
            rd_lock <= 1'b0;
            rd_ar_done <= 1'b0;
            wr_lock <= 1'b0;
            wr_aw_done <= 1'b0;
        end else begin
            if (!rd_lock) begin
                if (rd_any_valid) begin
                    rd_lock <= 1'b1;
                    rd_ar_done <= rd_ar_fire;
                    rd_own_dmmu <= rd_sel_dmmu;
                end
            end else begin
                if (!rd_ar_done && rd_ar_fire)
                    rd_ar_done <= 1'b1;
                if ((rd_ar_done || rd_ar_fire) && rd_r_last_fire) begin
                    rd_lock <= 1'b0;
                    rd_ar_done <= 1'b0;
                end
            end
            if (!wr_lock) begin
                if (wr_any_valid) begin
                    wr_lock <= 1'b1;
                    wr_aw_done <= wr_aw_fire;
                    wr_own <= wr_sel;
                end
            end else begin
                if (!wr_aw_done && wr_aw_fire)
                    wr_aw_done <= 1'b1;
                if ((wr_aw_done || wr_aw_fire) && wr_b_fire) begin
                    wr_lock <= 1'b0;
                    wr_aw_done <= 1'b0;
                end
            end
        end
    end

    //  ---- read address + data (dmmu / km) ----
    assign dmem_arid    = rd_owner_dmmu ? dmmu_arid    : km_arid;
    assign dmem_araddr  = rd_owner_dmmu ? dmmu_araddr  : km_araddr;
    assign dmem_arlen   = rd_owner_dmmu ? dmmu_arlen   : km_arlen;
    assign dmem_arsize  = rd_owner_dmmu ? dmmu_arsize  : km_arsize;
    assign dmem_arburst = rd_owner_dmmu ? dmmu_arburst : km_arburst;
    assign dmem_arprot  = rd_owner_dmmu ? dmmu_arprot  : km_arprot;
    assign dmem_arvalid = !rd_ar_done && (rd_lock ? rd_owner_arvalid : rd_any_valid);
    assign dmmu_arready = (!rd_ar_done &&  rd_owner_dmmu) ? dmem_arready : 1'b0;
    assign km_arready   = (!rd_ar_done && !rd_owner_dmmu) ? dmem_arready : 1'b0;
    assign dmem_rready  = rd_owner_dmmu ? dmmu_rready  : km_rready;

    //  ---- write address / data / response (dmmu / immu / km) ----
    assign dmem_awid    = (wr_owner == 2'd2) ? dmmu_awid    : (wr_owner == 2'd1) ? immu_awid    : km_awid;
    assign dmem_awaddr  = (wr_owner == 2'd2) ? dmmu_awaddr  : (wr_owner == 2'd1) ? immu_awaddr  : km_awaddr;
    assign dmem_awlen   = (wr_owner == 2'd2) ? dmmu_awlen   : (wr_owner == 2'd1) ? immu_awlen   : km_awlen;
    assign dmem_awsize  = (wr_owner == 2'd2) ? dmmu_awsize  : (wr_owner == 2'd1) ? immu_awsize  : km_awsize;
    assign dmem_awburst = (wr_owner == 2'd2) ? dmmu_awburst : (wr_owner == 2'd1) ? immu_awburst : km_awburst;
    assign dmem_awprot  = (wr_owner == 2'd2) ? dmmu_awprot  : (wr_owner == 2'd1) ? immu_awprot  : km_awprot;
    assign dmem_awvalid = !wr_aw_done && (wr_lock ? wr_owner_awvalid : wr_any_valid);
    assign dmmu_awready = (!wr_aw_done && wr_owner == 2'd2) ? dmem_awready : 1'b0;
    assign immu_awready = (!wr_aw_done && wr_owner == 2'd1) ? dmem_awready : 1'b0;
    assign km_awready   = (!wr_aw_done && wr_owner == 2'd0) ? dmem_awready : 1'b0;
    assign dmem_wdata   = (wr_owner == 2'd2) ? dmmu_wdata  : (wr_owner == 2'd1) ? immu_wdata  : km_wdata;
    assign dmem_wstrb   = (wr_owner == 2'd2) ? dmmu_wstrb  : (wr_owner == 2'd1) ? immu_wstrb  : km_wstrb;
    assign dmem_wlast   = (wr_owner == 2'd2) ? dmmu_wlast  : (wr_owner == 2'd1) ? immu_wlast  : km_wlast;
    assign dmem_wvalid  = (wr_owner == 2'd2) ? dmmu_wvalid : (wr_owner == 2'd1) ? immu_wvalid : km_wvalid;
    assign dmmu_wready  = (wr_owner == 2'd2) ? dmem_wready : 1'b0;
    assign immu_wready  = (wr_owner == 2'd1) ? dmem_wready : 1'b0;
    assign km_wready    = (wr_owner == 2'd0) ? dmem_wready : 1'b0;
    assign dmem_bready  = (wr_owner == 2'd2) ? dmmu_bready : (wr_owner == 2'd1) ? immu_bready : km_bready;

    //  ---- shared DMMU (phases V1/V2, doc/architecture.md) ----
    //  The scalar LSU and the VLSU preflight translator time-share the walk
    //  port. Single-issue guarantees the two never have walks in flight at
    //  once (the VLSU is the active FU during its preflight, so no scalar
    //  load/store can issue meanwhile); the owner latch routes done/fault/pa
    //  to the right consumer. vxlate_* is declared/driven at the vlsu above.
    //  scalar-LSU translation request (= issue_lsu; assigned with the issue_*
    //  wires below -- declared here so the dmmu port muxes bind under iverilog)
    wire        dmmu_req_lsu;
`ifdef KARU_EN_S
    reg         dmmu_own_v;                 //  current walk belongs to the VLSU
    always @(posedge clk) begin
        if (rst)               dmmu_own_v <= 1'b0;
        else if (dmmu_req_lsu) dmmu_own_v <= 1'b0;
        else if (vxlate_req)   dmmu_own_v <= 1'b1;
    end
    assign      vxlate_done  = dmmu_own_v && dmmu_done;
    assign      vxlate_fault = vxlate_done && dmmu_fault;
    assign      vxlate_pa    = dmmu_pa;

    karu_sv39 dmmu (
        .clk(clk), .rst(rst),
        //  walk-2 (beat-2 page) translates the latched second-page VA + access;
        //  walk-1 and the VLSU path are unchanged.
        .req(dmmu_req),
        .va(lsu_walk2_start ? lsu_va2_q : (dmmu_req_lsu ? lsu_addr : vxlate_va)),
        //  cbo.clean/flush translate as R|W (access 3); zero/inval as store;
        //  other CBO and plain stores/atomics as store; loads as load.
        .access(lsu_walk2_start ? lsu_acc2_q :
            dmmu_req_lsu
            ? (lsu_is_cbocf ? 2'd3 :
               (lsu_is_store || lsu_is_atomic || lsu_is_cboz || lsu_is_cboinval) ? 2'd2 : 2'd1)
            : (vxlate_st ? 2'd2 : 2'd1)),
        .priv(csr_priv), .satp(csr_satp),
        .status_sum(csr_status_sum), .status_mxr(csr_status_mxr),
        .flush(sys_sfencevma),
        .done(dmmu_done), .fault(dmmu_fault),
        .fault_va(dmmu_fault_va), .fault_cause(dmmu_fault_cause),
        .pa(dmmu_pa), .busy(dmmu_busy),
        .arid(dmmu_arid), .araddr(dmmu_araddr), .arlen(dmmu_arlen),
        .arsize(dmmu_arsize), .arburst(dmmu_arburst), .arprot(dmmu_arprot),
        .arvalid(dmmu_arvalid), .arready(dmmu_arready),
        .rid(dmem_rid), .rdata(dmem_rdata), .rresp(dmem_rresp),
        .rlast(dmem_rlast), .rvalid(dmem_rvalid), .rready(dmmu_rready),
        .awid(dmmu_awid), .awaddr(dmmu_awaddr), .awlen(dmmu_awlen),
        .awsize(dmmu_awsize), .awburst(dmmu_awburst), .awprot(dmmu_awprot),
        .awvalid(dmmu_awvalid), .awready(dmmu_awready),
        .wdata(dmmu_wdata), .wstrb(dmmu_wstrb), .wlast(dmmu_wlast),
        .wvalid(dmmu_wvalid), .wready(dmmu_wready),
        .bid(dmem_bid), .bresp(dmem_bresp), .bvalid(dmem_bvalid), .bready(dmmu_bready)
    );
`else
    wire        dmmu_own_v = 1'b0;
    assign      vxlate_done  = vxlate_req;
    assign      vxlate_fault = 1'b0;
    assign      vxlate_pa    = vxlate_va;
    assign dmmu_done        = 1'b0;
    assign dmmu_fault       = 1'b0;
    assign dmmu_fault_va    = 64'b0;
    assign dmmu_fault_cause = 64'b0;
    assign dmmu_pa          = 64'b0;
    assign dmmu_busy        = 1'b0;
    assign dmmu_arid        = {`AXI_ID_W{1'b0}};
    assign dmmu_araddr      = {`AXI_ADDR_W{1'b0}};
    assign dmmu_arlen       = {`AXI_LEN_W{1'b0}};
    assign dmmu_arsize      = {`AXI_SIZE_W{1'b0}};
    assign dmmu_arburst     = {`AXI_BURST_W{1'b0}};
    assign dmmu_arprot      = {`AXI_PROT_W{1'b0}};
    assign dmmu_arvalid     = 1'b0;
    assign dmmu_rready      = 1'b0;
    assign dmmu_awid        = {`AXI_ID_W{1'b0}};
    assign dmmu_awaddr      = {`AXI_ADDR_W{1'b0}};
    assign dmmu_awlen       = {`AXI_LEN_W{1'b0}};
    assign dmmu_awsize      = {`AXI_SIZE_W{1'b0}};
    assign dmmu_awburst     = {`AXI_BURST_W{1'b0}};
    assign dmmu_awprot      = {`AXI_PROT_W{1'b0}};
    assign dmmu_awvalid     = 1'b0;
    assign dmmu_wdata       = {`AXI_DATA_W{1'b0}};
    assign dmmu_wstrb       = {`AXI_STRB_W{1'b0}};
    assign dmmu_wlast       = 1'b0;
    assign dmmu_wvalid      = 1'b0;
    assign dmmu_bready      = 1'b0;
`endif

    //  No D-cache here: the scalar LSU drives physical accesses after
    //  Sv39 translation. Loads/stores/AMOs are single in-flight 64-bit beat
    //  accesses; misaligned accesses crossing a beat are split by karu_lsu.
    //  The scalar LSU is an AXI master into karu_mem's slave port (km_s_*);
    //  karu_mem (the unified write-through L1) forwards to dmem. Its address is
    //  already physical (Sv39-translated via lsu_pa_w).
    karu_lsu lsu (
        .clk(clk), .rst(rst),
        .req(lsu_req_pa), .busy(lsu_busy),
        .is_store(lsu_is_store), .sub_in(ex_sub),
        .addr(lsu_pa_w), .addr2(lsu_addr2), .wdata(lsu_wdata),
        .size(lsu_size), .sign_l(lsu_sign),
        .done(lsu_done), .rd_v(lsu_rd_v),
        .arid(lsu_arid),      .araddr(lsu_araddr),
        .arlen(lsu_arlen),    .arsize(lsu_arsize),
        .arburst(lsu_arburst), .arprot(lsu_arprot),
        .arvalid(lsu_arvalid), .arready(km_s_arready),
        .rid(km_s_rid),       .rdata(km_s_rdata),
        .rresp(km_s_rresp),   .rlast(km_s_rlast),
        .rvalid(km_s_rvalid), .rready(lsu_rready),
        .awid(lsu_awid),      .awaddr(lsu_awaddr),
        .awlen(lsu_awlen),    .awsize(lsu_awsize),
        .awburst(lsu_awburst), .awprot(lsu_awprot),
        .awvalid(lsu_awvalid), .awready(km_s_awready),
        .wdata_o(lsu_wdata_o), .wstrb(lsu_wstrb),
        .wlast(lsu_wlast),    .wvalid(lsu_wvalid),
        .wready(km_s_wready),
        .bid(km_s_bid),       .bresp(km_s_bresp),
        .bvalid(km_s_bvalid), .bready(lsu_bready)
    );

`ifdef KARU_EN_MEM
    //  Unified write-through L1: scalar LSU (s_* slave) + 128-bit vector port
    //  (v_*) share one coherent cache and one dmem master (m_* -> arbitrated
    //  km_* above). uncache_page bypasses the HTIF/MMIO page.
    karu_mem dmem_l1 (
        .clk(clk), .rst(rst), .uncache_page(uncache_page),
        .s_arid(lsu_arid),      .s_araddr(lsu_araddr),
        .s_arlen(lsu_arlen),    .s_arsize(lsu_arsize),
        .s_arburst(lsu_arburst), .s_arprot(lsu_arprot),
        .s_arvalid(lsu_arvalid), .s_arready(km_s_arready),
        .s_rid(km_s_rid),       .s_rdata(km_s_rdata),
        .s_rresp(km_s_rresp),   .s_rlast(km_s_rlast),
        .s_rvalid(km_s_rvalid), .s_rready(lsu_rready),
        .s_awid(lsu_awid),      .s_awaddr(lsu_awaddr),
        .s_awlen(lsu_awlen),    .s_awsize(lsu_awsize),
        .s_awburst(lsu_awburst), .s_awprot(lsu_awprot),
        .s_awvalid(lsu_awvalid), .s_awready(km_s_awready),
        .s_wdata(lsu_wdata_o),  .s_wstrb(lsu_wstrb),
        .s_wlast(lsu_wlast),    .s_wvalid(lsu_wvalid), .s_wready(km_s_wready),
        .s_bid(km_s_bid),       .s_bresp(km_s_bresp),
        .s_bvalid(km_s_bvalid), .s_bready(lsu_bready),
        .v_req(vmem_req),       .v_busy(vmem_busy), .v_is_store(vmem_is_store),
        //  the L1/dmem fabric is 32-bit physical (RAM in the low 4 GiB, like
        //  the scalar path); the vector port carries a PA there -- bare today,
        //  the V2 preflight translation later -- so truncation is exact.
        .v_addr(vmem_addr[31:0]),   .v_wdata(vmem_wdata), .v_wstrb(vmem_wstrb),
        .v_done(vmem_done),     .v_rdata(vmem_rdata),
        .m_arid(km_arid),       .m_araddr(km_araddr),
        .m_arlen(km_arlen),     .m_arsize(km_arsize),
        .m_arburst(km_arburst), .m_arprot(km_arprot),
        .m_arvalid(km_arvalid), .m_arready(km_arready),
        .m_rid(dmem_rid),       .m_rdata(dmem_rdata),
        .m_rresp(dmem_rresp),   .m_rlast(dmem_rlast),
        .m_rvalid(dmem_rvalid), .m_rready(km_rready),
        .m_awid(km_awid),       .m_awaddr(km_awaddr),
        .m_awlen(km_awlen),     .m_awsize(km_awsize),
        .m_awburst(km_awburst), .m_awprot(km_awprot),
        .m_awvalid(km_awvalid), .m_awready(km_awready),
        .m_wdata(km_wdata),     .m_wstrb(km_wstrb),
        .m_wlast(km_wlast),     .m_wvalid(km_wvalid), .m_wready(km_wready),
        .m_bid(dmem_bid),       .m_bresp(dmem_bresp),
        .m_bvalid(dmem_bvalid), .m_bready(km_bready)
    );
`else
    //  Scalar CPU-only synthesis profile: bypass the L1/cache wrapper and feed
    //  the LSU's physical AXI transactions directly into the existing dmem
    //  arbiter. Vector builds force KARU_EN_MEM in karu_ext.vh because the VLSU
    //  needs karu_mem's 128-bit vector port.
    assign km_arid      = lsu_arid;
    assign km_araddr    = lsu_araddr;
    assign km_arlen     = lsu_arlen;
    assign km_arsize    = lsu_arsize;
    assign km_arburst   = lsu_arburst;
    assign km_arprot    = lsu_arprot;
    assign km_arvalid   = lsu_arvalid;
    assign km_s_arready = km_arready;
    assign km_s_rid     = dmem_rid;
    assign km_s_rdata   = dmem_rdata;
    assign km_s_rresp   = dmem_rresp;
    assign km_s_rlast   = dmem_rlast;
    assign km_s_rvalid  = !rd_owner_dmmu && dmem_rvalid;
    assign km_rready    = lsu_rready;

    assign km_awid      = lsu_awid;
    assign km_awaddr    = lsu_awaddr;
    assign km_awlen     = lsu_awlen;
    assign km_awsize    = lsu_awsize;
    assign km_awburst   = lsu_awburst;
    assign km_awprot    = lsu_awprot;
    assign km_awvalid   = lsu_awvalid;
    assign km_s_awready = km_awready;
    assign km_wdata     = lsu_wdata_o;
    assign km_wstrb     = lsu_wstrb;
    assign km_wlast     = lsu_wlast;
    assign km_wvalid    = lsu_wvalid;
    assign km_s_wready  = km_wready;
    assign km_s_bid     = dmem_bid;
    assign km_s_bresp   = dmem_bresp;
    assign km_s_bvalid  = (wr_owner == 2'd0) && dmem_bvalid;
    assign km_bready    = lsu_bready;

    assign vmem_busy    = 1'b0;
    assign vmem_done    = 1'b0;
    assign vmem_rdata   = 128'b0;
    wire _unused_no_mem = &{uncache_page[0], vmem_req, vmem_is_store,
                            vmem_addr[0], vmem_wdata[0], vmem_wstrb[0], 1'b0};
`endif

    //  ==================================================================
    //  M (multiply / divide)
    //  ==================================================================
    wire        m_req;
    wire        m_busy;
    wire        m_done;
    wire [63:0] m_rd_v;

    reg         m_active;
    reg [4:0]   m_rd_pending;

`ifdef KARU_EN_M
    karu_m m (
        .clk(clk), .rst(rst),
        .req(m_req), .busy(m_busy),
        .sub(ex_sub), .is_w(ex_is_w),
        .op1(ex_xrs1_v), .op2(ex_xrs2_v),
        .done(m_done), .rd_v(m_rd_v)
    );
`else
    //  M disabled: the decoder traps M instructions, so these are never active.
    assign m_busy = 1'b0;
    assign m_done = 1'b0;
    assign m_rd_v = 64'b0;
`endif

    //  ==================================================================
    //  FPU -- floating-point unit (RV32F NaN-boxed in 64-bit f-regs)
    //  ==================================================================
    wire        fpu_req;
    wire        fpu_done;
    wire [63:0] fpu_res;
    wire [4:0]  fpu_flags;

    //  Instruction-level rounding mode (DYN = use fcsr.frm)
    wire [2:0]  inst_rm = ex_ins[14:12];
    wire [2:0]  fpu_rm  = (inst_rm == 3'b111) ? csr_frm : inst_rm;

    reg         fpu_active;
    reg [4:0]   fpu_rd_pending;
    reg         fpu_rd_is_f_q;      //  target regfile of pending FPU op
    reg         vlsu_active;        //  vector load/store in flight
    reg         varith_active;      //  vector arith in flight
    reg [4:0]   varith_rd_pending;  //  vfirst.m x-dest
    reg         varith_wx_q;        //  pending varith writes x (vfirst.m)

`ifdef KARU_EN_F
    karu_fpu fpu (
        .clk(clk), .rst(rst),
        .req(fpu_req),
        .busy(),
        .sub(ex_sub), .rm(fpu_rm), .is_d(ex_fp_is_d), .is_h(ex_is_h),
        .fp_zfa(ex_fp_zfa),
        //  fli's "operand" is its 5-bit index, carried in ex_imm (FPZ_FLI=4'd8).
        .op1((ex_fp_zfa == 4'd8) ? ex_imm : ex_rs1_v),
        .op2(ex_rs2_v), .op3(ex_frs3_v),
        .done(fpu_done), .res(fpu_res), .fflags(fpu_flags)
    );
`else
    //  F disabled: no FPU. issue_fpu is permanently 0 (decoder traps FP),
    //  so fpu_active never sets; these outputs just need defined values.
    assign fpu_done  = 1'b0;
    assign fpu_res   = 64'b0;
    assign fpu_flags = 5'b0;
`endif

    //  ==================================================================
    //  Issue / writeback (combinational control)
    //  ==================================================================
    reg         cacheop_active;
    reg         cacheop_fencei;

    wire exec_busy = lsu_active || m_active || fpu_active || vlsu_active ||
                     varith_active || cacheop_active;

    //  A completed vector instruction zeroes vstart (RVV 3.7). vset* clears it
    //  inside karu_csr already; this pulse covers every other vector op (arith
    //  incl. keccak/crypto, and loads/stores -- which may have *consumed* a
    //  nonzero vstart). A trapped issue never activates the FU, so vstart
    //  survives the trap, as the spec requires.
    assign v_op_retire = (varith_active && varith_done) || (vlsu_active && vlsu_done);
    wire issuing    = ex_valid && !exec_busy;

    //  ---- mstatus.FS/VS context-state gating (Linux FP/vector prerequisite) ----
    //  With the field Off, executing any op of that class -- including its CSR
    //  accesses -- raises a vectoring cause-2 illegal-instruction exception, so
    //  an OS can lazily allocate/enable the context. Permitted ops pulse
    //  fp_dirty/v_dirty into karu_csr (conservative whole-class Dirty).
    wire ex_is_fpcsr  = (ex_unit == `UNIT_CSR) &&
                        (ex_csr_addr >= 12'h001 && ex_csr_addr <= 12'h003); //  fflags/frm/fcsr
    wire ex_is_vcsr   = (ex_unit == `UNIT_CSR) &&
                        ((ex_csr_addr >= 12'h008 && ex_csr_addr <= 12'h00A) ||  //  vstart/vxsat/vxrm
                         ex_csr_addr == 12'h00F ||                              //  vcsr
                         (ex_csr_addr >= 12'hC20 && ex_csr_addr <= 12'hC22));   //  vl/vtype/vlenb
    wire ex_is_fp_lsu = (ex_unit == `UNIT_LSU) &&
                        (ex_sub == `LSU_FLOAD || ex_sub == `LSU_FSTORE);
    wire fs_off_ill   = (status_fs == 2'b00) &&
                        ((ex_unit == `UNIT_FPU) || ex_is_fp_lsu || ex_is_fpcsr);
    wire vs_off_ill   = (status_vs == 2'b00) &&
                        ((ex_unit == `UNIT_VARITH || ex_unit == `UNIT_VFPU ||
                          ex_unit == `UNIT_VKECCAK || ex_unit == `UNIT_VCRYPTO ||
                          ex_unit == `UNIT_VLSU || ex_unit == `UNIT_VCFG) || ex_is_vcsr);
    wire fsvs_ill     = fs_off_ill || vs_off_ill;
    wire fsvs_trap    = issuing && fsvs_ill;

    //  Zicbom/Zicboz privilege+envcfg gating: a CBO whose class is not enabled
    //  in the current privilege raises illegal-instruction (cause 2) instead of
    //  executing/translating.
    wire cbo_ill = issuing && (ex_unit == `UNIT_LSU) &&
        ( (lsu_is_cboz     && !cbo_zero_en) ||
          (lsu_is_cbocf    && !cbo_cf_en)   ||
          (lsu_is_cboinval && !cbo_inval_en) );

    wire issue_alu  = issuing && ex_unit == `UNIT_ALU;
`ifdef KARU_EN_B
    wire issue_bm   = issuing && ex_unit == `UNIT_BITMANIP;
`else
    wire issue_bm   = 1'b0;
`endif
    wire issue_bru  = issuing && ex_unit == `UNIT_BRU;
    wire issue_lsu  = issuing && ex_unit == `UNIT_LSU && !fs_off_ill && !cbo_ill;
    wire issue_csr  = issuing && ex_unit == `UNIT_CSR && !fsvs_ill;
    wire issue_sys  = issuing && ex_unit == `UNIT_SYS;
    wire issue_m    = issuing && ex_unit == `UNIT_M;
    wire issue_fpu  = issuing && ex_unit == `UNIT_FPU && !fs_off_ill;
    wire issue_vcfg   = issuing && ex_unit == `UNIT_VCFG && !vs_off_ill;
    //  one merged vector-exec FU: integer-V (UNIT_VARITH), FP-V (UNIT_VFPU) and
    //  the folded-in Keccak (UNIT_VKECCAK) all issue to karu_varith, which
    //  dispatches on vfunct3 (OPFVV/OPFVF) / is_keccak.
    //  SHA-2 at SEW=64 is legal only with Zvknhb (SHA-512); with Zvknha-only it
    //  traps. (Registered ex_* operands, not dec_*: the ID/EX latch holds them
    //  stable for the whole multi-cycle op -- see the operand-stability note.)
`ifdef KARU_EN_ZVK
    //  Zvk element-width (SEW) legality (vector-crypto.adoc SEW table). Every
    //  vector-crypto op is reserved unless SEW=32 (v_vtype[5:3]==3'd2 = e32),
    //  EXCEPT SHA-2 (vsha2ch/cl/ms), which also allows SEW=64 (3'd3 = e64) but
    //  ONLY when Zvknhb is present (Zvknha-only => SHA-512 reserved). e8/e16 are
    //  always reserved for crypto. AES/SM3/SM4/GHASH at non-e32 now trap too
    //  (previously only SHA-2 e64 was checked). The decode is width-agnostic, so
    //  the check lives here beside the other vector reserved-encoding traps.
    wire ex_vcrypto_is_sha2 = (ex_sub == `VCRYPTO_SHA2CH ||
                               ex_sub == `VCRYPTO_SHA2CL ||
                               ex_sub == `VCRYPTO_SHA2MS);
`ifdef KARU_EN_ZVKNHB
    wire vcrypto_sha2_e64_ok = 1'b1;
`else
    wire vcrypto_sha2_e64_ok = 1'b0;
`endif
    wire vcrypto_sew_illegal =
        (ex_unit == `UNIT_VCRYPTO) &&
        ((v_vtype[5:3] == 3'd2) ? 1'b0 :                            //  e32: always legal
         (v_vtype[5:3] == 3'd3) ? !(ex_vcrypto_is_sha2 && vcrypto_sha2_e64_ok) :    //  e64: SHA-2 + Zvknhb only
         1'b1);                                                     //  e8/e16: reserved
`else
    wire vcrypto_sew_illegal = 1'b0;
`endif
    //  v_vstart_ill is declared up by the VRF wires (iverilog elaboration
    //  order); the trap vectors as a normal cause-2 exception (like
    //  csr_ill_trap) so an OS can handle it. vstart is left unchanged by the
    //  trap (3.7: only a completed vector instruction zeroes it).
    //  v_resv_ill (vill-set execution + reserved indexed-load overlap, by the
    //  VLSU wires) traps the same way.
    wire v_vstart_trap = issuing && v_vstart_ill && !vs_off_ill;    //  VS gate first
    wire v_resv_trap   = issuing && v_resv_ill && !vs_off_ill;
    wire v_fpsew_trap  = issuing && v_fpsew_ill && !vs_off_ill;
    wire issue_vcrypto_trap = issuing && vcrypto_sew_illegal && !v_vstart_ill && !v_resv_ill && !vs_off_ill;
    assign issue_vkeccak_mode = issuing && ex_unit == `UNIT_VKECCAK && !v_vstart_ill && !vs_off_ill;
    assign issue_vcrypto_mode = issuing && ex_unit == `UNIT_VCRYPTO &&
                              !vcrypto_sew_illegal && !v_vstart_ill && !vs_off_ill;
    wire issue_varith = issuing && !v_vstart_ill && !v_resv_ill && !vs_off_ill && !v_fpsew_ill &&
                                   (ex_unit == `UNIT_VARITH || ex_unit == `UNIT_VFPU
                                   || ex_unit == `UNIT_VKECCAK ||
                                   (ex_unit == `UNIT_VCRYPTO && !vcrypto_sew_illegal));
    wire issue_vlsu   = issuing && ex_unit == `UNIT_VLSU && !v_resv_ill && !vs_off_ill;
    //  conservative Dirty: any LEGALLY ISSUED FP/vector op or FP/vector CSR
    //  access. Derived strictly from the issue_* wires (review finding: the
    //  first version used raw unit matches, so an op trapping at issue --
    //  e.g. SHA-2-e64-without-Zvknhb, or an illegal CSR access -- still
    //  dirtied the state; a SIGILL/probe must not gain architectural side
    //  effects). issue_varith already excludes every issue-time trap; the
    //  CSR terms exclude csr_illegal. An op that issues and faults LATER
    //  (page fault) still dirties -- a legal over-approximation.
    assign fp_dirty = issue_fpu || (issue_lsu && ex_is_fp_lsu)
                    || (issue_csr && ex_is_fpcsr && !csr_illegal);
    assign v_dirty  = issue_vcfg || issue_varith || issue_vlsu
                    || (issue_csr && ex_is_vcsr && !csr_illegal);
    wire issue_cacheop = issue_sys &&
        (ex_sub == `SYS_FENCE || ex_sub == `SYS_FENCEI);
    assign vlsu_req = issue_vlsu;

    //  vset* writes vl/vtype the cycle it issues (single-cycle, serialising
    //  like CSR -- single-issue already drains everything before it).
    assign vset_req = issue_vcfg;

    //  vector arith is multi-cycle; it drives the VRF write port directly.
    //  vfirst.m writes an x-reg instead (integer writeback below, on done).
    assign varith_req = issue_varith;

    wire issue_long = issue_lsu || issue_m || issue_fpu || issue_vlsu ||
                      issue_varith || issue_cacheop;
    wire ifu_page_fault = ifu_fault_valid;
    //  !dmmu_own_v: single-issue already prevents a scalar walk overlapping a
    //  vector walk, but the owner qualifier keeps the response routing
    //  correct-by-construction rather than correct-by-schedule.
    //  A fault on EITHER the beat-1 walk or the beat-2 (cross-page) walk traps as
    //  a load/store page fault. The DMMU's fault_va/cause hold the faulting walk's
    //  VA (beat-2 walk -> lsu_va2_q) and kind, so stval/cause are correct for both.
    wire lsu_page_fault = (lsu_xlate_active  && !dmmu_own_v && dmmu_done && dmmu_fault)
                       || (lsu_xlate2_active && !lsu_walk2_armed && !dmmu_own_v
                           && dmmu_done && dmmu_fault);
    //  V2/V3: the VLSU preflight hit a translation fault and aborted with no
    //  architectural side effects (precise; vstart stays 0). Trap exactly
    //  like a scalar load/store page fault: cause/tval come from the DMMU
    //  (its fault_va/fault_cause regs hold until the next walk, which cannot
    //  start before the trap -- the VLSU still owns the FU this cycle).
    wire vlsu_page_fault = vlsu_active && vlsu_fault_abort;
    wire irq_take = csr_irq_pending && !exec_busy && !ex_valid && !ifu_page_fault;

    //  IFU/ID: advance one instruction when the ID/EX slot can accept it.
    //  Do not predecode behind a just-issued long-latency instruction; that
    //  would latch stale operands for load/M/F/V dependencies.
    wire id_accept = ifu_valid && !ifu_redir && !irq_take && !exec_busy
        && (!ex_valid || (issuing && !issue_long));
    assign ifu_take   = id_accept;

    //  Redirect on taken branch, ECALL/EBREAK or xRET.
    wire sys_trap_ent = issue_sys &&
        (ex_sub == `SYS_ECALL || ex_sub == `SYS_EBREAK);
    //  Genuinely-illegal opcode (decode SYS_TRAP): a vectoring cause-2
    //  illegal-instruction exception (tval = the faulting instruction word, set by
    //  trap_tval/ill_insn_tval like the other cause-2 illegal traps), NOT a core
    //  halt -- Linux must be able to recognize it (insn_is_vector for RVV first-use)
    //  and SIGILL/handle it.
    wire sys_ill_trap = issue_sys && ex_sub == `SYS_TRAP;
    //  Unimplemented-CSR access -> proper illegal-instruction exception (cause 2)
    //  to mtvec/stvec, so M-mode firmware can catch it (e.g. OpenSBI's optional-
    //  extension probes). Like the SYS_TRAP illegal opcode above, this vectors as
    //  cause-2 (neither halts the core; both carry the faulting insn in tval).
    wire csr_ill_trap = issue_csr && csr_illegal;
    //  Privileged SYSTEM ops are privilege-checked: executing them with too
    //  little privilege raises an illegal-instruction exception (cause 2)
    //  instead of the privileged effect. Required for U/S isolation -- a
    //  U-mode mret must not escalate. csr_priv: 3=M, 1=S, 0=U.
    //  TSR/TVM/TW (mstatus trap-virtualization), exposed from karu_csr:
    //    TSR -> sret traps in S; TVM -> sfence.vma (and satp, in karu_csr) trap
    //    in S; TW -> wfi traps below M.
    wire sys_mret_raw    = issue_sys && ex_sub == `SYS_MRET;
    wire sys_sret_raw    = issue_sys && ex_sub == `SYS_SRET;
    wire sys_sfence_raw  = issue_sys && ex_sub == `SYS_SFENCEVMA;
    wire sys_wfi_raw     = issue_sys && ex_sub == `SYS_WFI;
    wire mret_ill   = sys_mret_raw   && (csr_priv != 2'd3); //  mret: M only
`ifdef KARU_EN_S
    wire sret_ill   = sys_sret_raw   && ((csr_priv == 2'd0) //  sret: traps in U
                                      || (csr_priv == 2'd1 && csr_tsr));    //  or S with TSR
    wire sfence_ill = sys_sfence_raw && ((csr_priv == 2'd0) //  sfence.vma: traps in U
                                      || (csr_priv == 2'd1 && csr_tvm));    //  or S with TVM
`else
    wire sret_ill   = sys_sret_raw;
    wire sfence_ill = sys_sfence_raw;
`endif
    wire wfi_ill    = sys_wfi_raw    && (csr_priv != 2'd3) && csr_tw;   //  wfi below M with TW
    wire sys_priv_ill = mret_ill || sret_ill || sfence_ill || wfi_ill;
    //  effective (gated) -- the privileged effect fires only when legal:
    wire sys_mret     = sys_mret_raw && !mret_ill;
    wire sys_sret     = sys_sret_raw && !sret_ill;
    wire sys_fence    = issue_sys && ex_sub == `SYS_FENCE;
    //  FENCE.I: refetch from the next PC so the IFU prefetch buffers (which may
    //  hold pre-store, stale instructions) are flushed -- self-modifying code.
    wire sys_fencei   = issue_sys && ex_sub == `SYS_FENCEI;
    assign icache_flush = sys_fencei;   //  FENCE.I invalidates the I-cache (Zifencei)
    assign sys_sfencevma = sys_sfence_raw && !sfence_ill;
    wire _unused_sv39 = &{csr_satp[0], csr_status_sum, csr_status_mxr, 1'b0};
    //  sfence.vma redirects the IFU to the next PC: it flushes the prefetch
    //  buffers and drops any in-flight IMMU walk via the IFU discard path, so
    //  the post-sfence stream is translated after the TLB/PWC flush.
    assign ifu_redir  = (issue_bru && bru_taken) || sys_trap_ent || csr_ill_trap || sys_priv_ill || v_vstart_trap || v_resv_trap || v_fpsew_trap || fsvs_trap || cbo_ill || sys_ill_trap || issue_vcrypto_trap || ifu_page_fault || lsu_page_fault || vlsu_page_fault || irq_take
                     || sys_mret || sys_sret || sys_sfencevma || (cacheop_active && cacheop_fencei && cache_flush_done);
    assign ifu_redir_pc = (sys_mret || sys_sret) ? ret_pc  :
                           (sys_trap_ent || csr_ill_trap || sys_priv_ill || v_vstart_trap || v_resv_trap || v_fpsew_trap || fsvs_trap || cbo_ill || sys_ill_trap || issue_vcrypto_trap || ifu_page_fault || lsu_page_fault || vlsu_page_fault || irq_take) ? trap_vec :
                           (sys_sfencevma || (cacheop_active && cacheop_fencei && cache_flush_done)) ? pc_next :
                                          bru_target;

    //  CSR request
    assign csr_req  = issue_csr;
    assign csr_addr = ex_csr_addr;
    assign csr_src  = ex_use_imm ? ex_imm : ex_rs1_v;
    assign csr_sub  = ex_sub;
    assign csr_rs1  = ex_rs1;

    //  Trap / mret
    assign trap_req = sys_trap_ent || csr_ill_trap || sys_priv_ill || v_vstart_trap || v_resv_trap || v_fpsew_trap || fsvs_trap || cbo_ill || sys_ill_trap || issue_vcrypto_trap || ifu_page_fault || lsu_page_fault || vlsu_page_fault || irq_take;
    //  Instruction page-fault EPC must be the *instruction* VA (ifu_pc), so the
    //  OS sret resumes at the faulting instruction. The IFU translates the
    //  8-byte-aligned fetch quad (e.g. 0x22aa0 while fetching the instruction at
    //  0x22aa4), so ifu_fault_va is the aligned quad address -- correct for tval
    //  but 4 bytes too low for EPC. Using it as EPC made Linux resume 4 bytes
    //  early after demand-paging a code page on the first cross-page jump.
    assign trap_epc = irq_take ? ifu_pc :
        ifu_page_fault ? ifu_pc : ex_pc;
    assign trap_cause = irq_take ? csr_irq_cause :
        ifu_page_fault ? ifu_fault_cause :
        (lsu_page_fault || vlsu_page_fault) ? dmmu_fault_cause :    //  13/15 by access kind
        (csr_ill_trap || sys_priv_ill || v_vstart_trap || v_resv_trap || v_fpsew_trap || fsvs_trap
         || cbo_ill || sys_ill_trap || issue_vcrypto_trap) ? 64'd2 :    //  illegal instruction
        (ex_sub == `SYS_ECALL) ?
        (csr_priv == 2'd3 ? 64'd11 : csr_priv == 2'd1 ? 64'd9 : 64'd8) : 64'd3;
    //  Illegal-instruction (cause-2) traps: write the FAULTING INSTRUCTION WORD to
    //  mtval/stval (RVC -> zero-extended 16-bit raw word), matching spike. Linux's
    //  lazy RVV first-use handler (riscv_v_first_use_handler) reads regs->badaddr
    //  (= stval) AS the instruction and calls insn_is_vector(insn): a zero stval
    //  makes insn_is_vector(0)=false, so it delivers SIGILL on the first userspace
    //  vector op (VS=Off trap) instead of enabling VS and retrying. The faulting
    //  insn is the EX-stage one (same as trap_epc=ex_pc). Page faults keep the
    //  fault VA; IRQ keeps 0.
    wire [63:0] ill_insn_tval = ex_is_c ? {48'b0, ex_w[15:0]} : {32'b0, ex_w};
    assign trap_tval = irq_take ? 64'b0 :
                       ifu_page_fault ? ifu_fault_va :
                       (lsu_page_fault || vlsu_page_fault) ? dmmu_fault_va :
                       (csr_ill_trap || sys_priv_ill || v_vstart_trap || v_resv_trap
                        || v_fpsew_trap || fsvs_trap || cbo_ill || sys_ill_trap
                        || issue_vcrypto_trap) ? ill_insn_tval : 64'b0;
    assign mret_req = sys_mret;
    assign sret_req = sys_sret;
`ifdef KARU_DBG_TRAP
    always @(posedge clk) if (!rst) begin
        if (trap_req)
            $display("[DBG-TRAP] cause=%h epc=%h priv=%0d satp=%h ifu_pf=%b lsu_pf=%b csrill=%b sysent=%b irq=%b",
                trap_cause, trap_epc, csr_priv, csr_satp, ifu_page_fault, lsu_page_fault, csr_ill_trap, sys_trap_ent, irq_take);
        if (sys_mret || sys_sret)
            $display("[DBG-XRET] mret=%b sret=%b ret_pc=%h priv(before)=%0d", sys_mret, sys_sret, ret_pc, csr_priv);
        if (ifu_fault_valid)
            $display("[DBG-IFUPF] ifu_fault_va=%h ifu_fault_cause=%h immu_fault=%b immu_done=%b satp=%h priv=%0d",
                ifu_fault_va, ifu_fault_cause, immu_fault, immu_done, csr_satp, csr_priv);
    end
`endif

    //  LSU / M / FPU request: pulse for one cycle when we issue
    //  Bare LSU ops skip translation -> never request the DMMU. A cross-page
    //  access pulses a SECOND request (lsu_walk2_start) for the beat-2 page.
    assign dmmu_req_lsu = (issue_lsu && !lsu_bare) || lsu_walk2_start;
    assign dmmu_req = dmmu_req_lsu || vxlate_req;   //  shared walk port (V1 arbiter)
    //  Walk-1 done (no fault). For a cross-page access this only ARMS the
    //  beat-2 walk; the LSU starts at walk-2 done instead (lsu_walk2_done).
    wire lsu_walk1_done = lsu_xlate_active && !dmmu_own_v && dmmu_done && !dmmu_fault;
    wire lsu_walk2_done = lsu_xlate2_active && !lsu_walk2_armed && !dmmu_own_v
                          && dmmu_done && !dmmu_fault;
    //  Bare: the LSU starts in the issue cycle with PA=VA (lsu_pa_w). Translated:
    //  it starts when the relevant DMMU walk completes (no fault) -- walk-1 for a
    //  same-page access, walk-2 for a page-crossing one.
    assign lsu_req_pa = lsu_bare ? issue_lsu
                      : ((lsu_walk1_done && !lsu_xpage_q) || lsu_walk2_done);
    assign lsu_req  = issue_lsu;
    assign m_req    = issue_m;
    assign fpu_req  = issue_fpu;
    assign cache_flush_req = issue_cacheop;
    assign cache_flush_invalidate = sys_fencei;

    //  ---- Integer regfile writeback ----
    wire wb_alu   = issue_alu && ex_rd != 5'd0;
    wire wb_bm    = issue_bm  && ex_rd != 5'd0;
    wire wb_bru   = issue_bru && (ex_sub == `BRU_JAL || ex_sub == `BRU_JALR) && ex_rd != 5'd0;
    wire wb_csr_  = issue_csr && ex_rd != 5'd0 && !csr_ill_trap;
    wire wb_load  = lsu_active && lsu_done && !lsu_was_store
                 && !lsu_was_fload && lsu_rd_pending != 5'd0;
    wire wb_m     = m_active   && m_done   && m_rd_pending  != 5'd0;
    wire wb_fpu_x = fpu_active && fpu_done && !fpu_rd_is_f_q
                 && fpu_rd_pending != 5'd0;
    //  vset* writes vl into rd (an x-reg); x0,x0 form writes nothing.
    wire wb_vcfg  = issue_vcfg && ex_rd != 5'd0;
    //  vfirst.m writes its index/-1 result into rd (an x-reg), on completion.
    wire wb_vfirst = varith_active && varith_done && varith_wx_q && varith_rd_pending != 5'd0;

    assign wb_we = wb_alu || wb_bm || wb_bru || wb_csr_ || wb_load || wb_m || wb_fpu_x
                || wb_vcfg || wb_vfirst;
    assign wb_rd = wb_load  ? lsu_rd_pending :
                   wb_m     ? m_rd_pending   :
                   wb_fpu_x ? fpu_rd_pending :
                   wb_vfirst ? varith_rd_pending : ex_rd;
    assign wb_v  = wb_load  ? lsu_rd_v :
                   wb_m     ? m_rd_v   :
                   wb_fpu_x ? fpu_res :
                   wb_csr_  ? csr_rd_v :
                   wb_vcfg  ? v_vl_new :
                   wb_vfirst ? varith_x :
                   wb_bru   ? pc_next :
                   wb_bm    ? bm_out :
                              alu_out;

    //  ---- F regfile writeback ----
    wire wb_fload = lsu_active && lsu_done && lsu_was_fload;
    wire wb_fpu_f = fpu_active && fpu_done && fpu_rd_is_f_q;
    //  vfmv.f.s: the merged vector FU writes a scalar f-register.
    wire wb_vfpu_f = varith_active && varith_done && varith_writes_f;
    assign fwb_we = wb_fload || wb_fpu_f || wb_vfpu_f;
    assign fwb_rd = wb_fload  ? lsu_rd_pending :
                    wb_vfpu_f ? varith_rd_pending : fpu_rd_pending;
    //  FLH NaN-boxes a half (upper 48 = 1s); FLW a single (upper 32 = 1s);
    //  FLD writes the full 64.
    assign fwb_v  = wb_fload   ? (lsu_was_fload_h ? {48'hFFFF_FFFF_FFFF, lsu_rd_v[15:0]}
                                 : lsu_was_fload_d ? lsu_rd_v
                                 :                   {32'hFFFF_FFFF, lsu_rd_v[31:0]})
                  : wb_vfpu_f  ? varith_f_res
                  :              fpu_res;

    //  ---- retirement pulse: drives perf_retire used by csr (minstret) ----
    //  RISC-V Zicntr: minstret counts every retired (committed) instruction
    //  exactly once. Single-cycle units (ALU/BRU/CSR/VCFG and non-trapping
    //  SYS) commit in their issue cycle -- counted regardless of rd, so stores'
    //  siblings (rd==0 ALU), conditional branches, and jumps without a link all
    //  count. Multi-cycle units (LSU incl. stores+AMOs, M, FPU, V*) commit on
    //  their done pulse. Illegal-instruction traps (SYS_TRAP) do not retire.
    //  Single-issue in-order => at most one retire per cycle, so a 1-bit pulse
    //  is exact.
    wire retire_issue = issuing &&
        (ex_unit == `UNIT_ALU  || issue_bm || ex_unit == `UNIT_BRU ||
         (ex_unit == `UNIT_CSR && !csr_ill_trap && !fsvs_ill) ||
         (ex_unit == `UNIT_VCFG && !vs_off_ill) ||
         (ex_unit == `UNIT_SYS && ex_sub != `SYS_TRAP && !sys_priv_ill &&
          ex_sub != `SYS_FENCE && ex_sub != `SYS_FENCEI));
    assign perf_retire = retire_issue
        || (lsu_active    && lsu_done)          //  loads, stores, AMOs
        || (m_active      && m_done)
        || (fpu_active    && fpu_done)
        || (vlsu_active   && vlsu_done)
        || (varith_active && varith_done)   //  keccak retires via varith_done (folded in)
        || (cacheop_active && cache_flush_done);

    //  ---- fflags accumulation: any FPU op done sets sticky fflags ----
    //  (scalar FPU or the merged vector FU; single-issue => never same cycle)
    assign fflags_set = wb_fpu_f || wb_fpu_x
                     || (fpu_active && fpu_done)    //  even for store-target (none) ops
                     || (varith_active && varith_done && varith_ff_set);
    assign fflags_in  = (varith_active && varith_done && varith_ff_set) ? varith_fflags : fpu_flags;

    //  ==================================================================
    //  Sequential state
    //  ==================================================================
`ifdef PDEBUG_ISS
    always @(posedge clk) begin
        if (!rst && issuing)
            $display("[ISS] pc=%h ins=%h unit=%h sub=%h rd=%d rs1=%d rs2=%d rs1_v=%h rs2_v=%h imm=%h alu=%h redir=%b -> %h",
                ex_pc, ex_ins, ex_unit, ex_sub, ex_rd, ex_rs1, ex_rs2,
                ex_rs1_v, ex_rs2_v, ex_imm, alu_out, ifu_redir, ifu_redir_pc);
    end
`endif

    always @(posedge clk) begin
        if (rst) begin
            trap            <= 0;
            ex_valid        <= 0;
            lsu_active      <= 0;
            lsu_xlate_active <= 0;
            lsu_xlate2_active <= 0;
            lsu_walk2_armed <= 0;
            lsu_xpage_q     <= 0;
            lsu_pa_q        <= 0;
            lsu_rd_pending  <= 0;
            lsu_was_store   <= 0;
            lsu_was_fload   <= 0;
            m_active        <= 0;
            m_rd_pending    <= 0;
            fpu_active      <= 0;
            fpu_rd_pending  <= 0;
            fpu_rd_is_f_q   <= 0;
            vlsu_active     <= 0;
            varith_active   <= 0;
            cacheop_active  <= 0;
            cacheop_fencei  <= 0;
        end else begin
            if (issuing)
                ex_valid <= 1'b0;
            if (id_accept) begin
                ex_valid        <= 1'b1;
                ex_pc           <= ifu_pc;
                ex_w            <= ifu_w;
                ex_ins          <= dec_ins;
                ex_is_c         <= is_c;
                ex_unit         <= dec_unit;
                ex_sub          <= dec_sub;
                ex_rd           <= dec_rd;
                ex_rs1          <= dec_rs1;
                ex_rs2          <= dec_rs2;
                ex_rs3          <= dec_rs3;
                ex_imm          <= dec_imm;
                ex_size         <= dec_size;
                ex_sign_l       <= dec_sign_l;
                ex_use_imm      <= dec_use_imm;
                ex_use_pc       <= dec_use_pc;
                ex_is_w         <= dec_is_w;
                ex_csr_addr     <= dec_csr_addr;
                ex_rs1_is_f     <= dec_rs1_is_f;
                ex_rs2_is_f     <= dec_rs2_is_f;
                ex_rs3_is_f     <= dec_rs3_is_f;
                ex_rd_is_f      <= dec_rd_is_f;
                ex_fp_is_d      <= dec_fp_is_d;
                ex_is_h         <= dec_is_h;
                ex_fp_zfa       <= dec_fp_zfa;
                ex_vm           <= dec_vm;
                ex_vfunct3      <= dec_vfunct3;
                ex_vfunct6      <= dec_vfunct6;
                ex_xrs1_v       <= id_xrs1_v;
                ex_xrs2_v       <= id_xrs2_v;
                ex_rs1_v        <= id_rs1_v;
                ex_rs2_v        <= id_rs2_v;
                ex_frs1_v       <= id_frs1_v;
                ex_frs2_v       <= id_frs2_v;
                ex_frs3_v       <= id_frs3_v;
            end

            if (issue_lsu) begin
                lsu_active      <= 1'b1;
                lsu_xlate_active <= !lsu_bare;  //  bare: no translation phase
                lsu_xlate2_active <= 1'b0;
                lsu_walk2_armed <= 1'b0;
                lsu_xpage_q     <= lsu_xpage;   //  straddles a 4 KiB page
                lsu_va2_q       <= {lsu_addr[63:3], 3'b000} + 64'd8;    //  beat-2 VA
                lsu_acc2_q      <= lsu_acc;     //  beat-2 walk access type
                lsu_rd_pending  <= ex_rd;
                lsu_was_store   <= lsu_is_store;
                lsu_was_fload   <= lsu_is_fload;
                lsu_was_fload_d <= lsu_is_fload && ex_fp_is_d;
                lsu_was_fload_h <= lsu_is_fload && ex_is_h;
            end else if (lsu_page_fault) begin
                lsu_active      <= 1'b0;
                lsu_xlate_active <= 1'b0;
                lsu_xlate2_active <= 1'b0;
                lsu_walk2_armed <= 1'b0;
            end else if (lsu_xlate_active && dmmu_done) begin
                //  walk-1 done (no fault: a fault would have hit lsu_page_fault).
                lsu_xlate_active <= 1'b0;
                lsu_pa_q        <= dmmu_pa;     //  PA1 (beat-1)
                if (lsu_xpage_q) begin          //  arm the beat-2 page walk
                    lsu_xlate2_active <= 1'b1;
                    lsu_walk2_armed <= 1'b1;
                end
            end else if (lsu_xlate2_active && !lsu_walk2_armed && dmmu_done) begin
                //  walk-2 done (no fault); the LSU starts this cycle (lsu_req_pa).
                lsu_xlate2_active <= 1'b0;
            end else if (lsu_active && lsu_done) begin
                lsu_active      <= 1'b0;
            end
            //  beat-2 walk request accepted -> disarm (this fires in a cycle when
            //  none of the exclusive branches above touch lsu_walk2_armed).
            if (lsu_walk2_start) lsu_walk2_armed <= 1'b0;

            if (issue_m) begin
                m_active        <= 1'b1;
                m_rd_pending    <= ex_rd;
            end else if (m_active && m_done) begin
                m_active        <= 1'b0;
            end

            if (issue_fpu) begin
                fpu_active      <= 1'b1;
                fpu_rd_pending  <= ex_rd;
                fpu_rd_is_f_q   <= ex_rd_is_f;
            end else if (fpu_active && fpu_done) begin
                fpu_active      <= 1'b0;
            end

            if (issue_vlsu) begin
                vlsu_active     <= 1'b1;
            end else if (vlsu_active && (vlsu_done || vlsu_fault_abort)) begin
                //  fault_abort: the op trapped (no done -> no retire, no
                //  commit-log line, vstart untouched); the FU still frees.
                vlsu_active     <= 1'b0;
            end

            if (issue_varith) begin
                varith_active       <= 1'b1;
                varith_rd_pending   <= ex_rd;   //  vfirst.m x-dest / vfmv.f.s f-dest
                varith_wx_q         <= varith_wx;   //  0 for FP ops
            end else if (varith_active && varith_done) begin
                varith_active       <= 1'b0;
            end

            if (issue_cacheop) begin
                cacheop_active  <= 1'b1;
                cacheop_fencei  <= sys_fencei;
            end else if (cacheop_active && cache_flush_done) begin
                cacheop_active  <= 1'b0;
                cacheop_fencei  <= 1'b0;
            end

            //  Genuinely-illegal opcodes and illegal vector-crypto encodings
            //  now VECTOR as cause-2 illegal-instruction exceptions (sys_ill_trap
            //  / issue_vcrypto_trap in the trap terms above) so an OS can SIGILL
            //  the offender -- the old halt-the-core behavior (trap <= 1, "as in
            //  vk") is retired; the `trap` output remains for the testbenches but
            //  is never set. A bad mtvec now ends a sim by timeout, not halt.
        end
    end

`ifdef CORE_COMMIT_LOG
    //  Spike-style per-retired-instruction log. Format matches what
    //  `spike --log-commits` produces (priv=3 lines), so flow/diff_test.sh
    //  can diff us against spike to localise divergence.
    //
    //  $fwrite (not $fstrobe) is intentional: inside posedge clk it
    //  captures the values at the moment of the edge, before any NB
    //  updates apply -- i.e. the state of the instruction we're issuing
    //  right now, not the next one.
    integer commitf;
    reg [1023:0] commit_log_file;
    initial begin
        if (!$value$plusargs("commit_log=%s", commit_log_file))
            commit_log_file = "_build/karu.log";
        commitf = $fopen(commit_log_file, "w");
    end

    //  Deferred-load latches: load commit prints when lsu_done fires
    //  with the captured rd value, several cycles after issue.
    reg [63:0]  log_lpc;
    reg [31:0]  log_lins;
    reg [15:0]  log_lins16;
    reg         log_lc;
    reg [4:0]   log_lrd;
    reg [63:0]  log_laddr;
    reg         log_lpending = 0;

    //  Deferred-M latches: M-extension commit prints when m_done fires,
    //  ~64 cycles after issue.
    reg [63:0]  log_mpc;
    reg [31:0]  log_mins;
    reg [15:0]  log_mins16;
    reg         log_mc;
    reg [4:0]   log_mrd;
    reg         log_mpending = 0;

    task automatic log_rd;
        input [63:0] pc; input [31:0] ins; input [15:0] ins16;
        input        c;  input [4:0]  rd;  input [63:0] val;
        begin
            if (c) begin
                if (rd < 10)
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%04h) x%0d  0x%016h\n", pc, ins16, rd, val);
                else
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%04h) x%0d 0x%016h\n",  pc, ins16, rd, val);
            end else begin
                if (rd < 10)
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%08h) x%0d  0x%016h\n", pc, ins,   rd, val);
                else
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%08h) x%0d 0x%016h\n",  pc, ins,   rd, val);
            end
        end
    endtask

    task automatic log_nord;
        input [63:0] pc; input [31:0] ins; input [15:0] ins16; input c;
        begin
            if (c)
                $fwrite(commitf, "core   0: 3 0x%016h (0x%04h)\n", pc, ins16);
            else
                $fwrite(commitf, "core   0: 3 0x%016h (0x%08h)\n", pc, ins);
        end
    endtask

    task automatic log_store;
        input [63:0] pc; input [31:0] ins; input [15:0] ins16; input c;
        input [63:0] addr; input [63:0] val;
        begin
            if (c)
                $fwrite(commitf, "core   0: 3 0x%016h (0x%04h) mem 0x%016h 0x%016h\n", pc, ins16, addr, val);
            else
                $fwrite(commitf, "core   0: 3 0x%016h (0x%08h) mem 0x%016h 0x%016h\n", pc, ins,   addr, val);
        end
    endtask

    task automatic log_load;
        input [63:0] pc; input [31:0] ins; input [15:0] ins16;
        input        c;  input [4:0]  rd;  input [63:0] val; input [63:0] addr;
        begin
            if (c) begin
                if (rd < 10)
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%04h) x%0d  0x%016h mem 0x%016h\n", pc, ins16, rd, val, addr);
                else
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%04h) x%0d 0x%016h mem 0x%016h\n",  pc, ins16, rd, val, addr);
            end else begin
                if (rd < 10)
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%08h) x%0d  0x%016h mem 0x%016h\n", pc, ins,   rd, val, addr);
                else
                    $fwrite(commitf, "core   0: 3 0x%016h (0x%08h) x%0d 0x%016h mem 0x%016h\n",  pc, ins,   rd, val, addr);
            end
        end
    endtask

    reg [63:0]  log_fpc;
    reg [31:0]  log_fins;
    reg [15:0]  log_fins16;
    reg         log_fc;
    reg [4:0]   log_frd;
    reg         log_frd_is_f;
    reg         log_fpending = 0;

    always @(posedge clk) begin
        if (rst) begin
            log_lpending <= 1'b0;
            log_mpending <= 1'b0;
            log_fpending <= 1'b0;
        end else begin
            //  Deferred LOAD commit -- emit when the LSU returns data.
            if (log_lpending && lsu_done && !lsu_was_store) begin
                log_load(log_lpc, log_lins, log_lins16, log_lc,
                         log_lrd, lsu_rd_v, log_laddr);
                log_lpending <= 1'b0;
            end

            //  Deferred M-extension commit -- emit when m_done fires.
            if (log_mpending && m_done) begin
                if (log_mrd != 5'd0)
                    log_rd(log_mpc, log_mins, log_mins16, log_mc,
                           log_mrd, m_rd_v);
                else
                    log_nord(log_mpc, log_mins, log_mins16, log_mc);
                log_mpending <= 1'b0;
            end

            //  Deferred FPU commit (for X-write ops -- we don't emit the
            //  F-write ops yet; spike's log lines for those use a "f<rd>"
            //  form we don't reproduce here).
            if (log_fpending && fpu_done) begin
                if (log_frd_is_f) begin
                    //  F-target ops: emit as "f<rd>" style line (skip for now)
                    log_nord(log_fpc, log_fins, log_fins16, log_fc);
                end else if (log_frd != 5'd0) begin
                    log_rd(log_fpc, log_fins, log_fins16, log_fc,
                           log_frd, fpu_res);
                end else begin
                    log_nord(log_fpc, log_fins, log_fins16, log_fc);
                end
                log_fpending <= 1'b0;
            end

            if (issuing) begin
                if (issue_alu) begin
                    if (ex_rd != 5'd0)
                        log_rd(ex_pc, ex_ins, ex_w[15:0], ex_is_c, ex_rd, alu_out);
                    else
                        log_nord(ex_pc, ex_ins, ex_w[15:0], ex_is_c);
                end else if (issue_bm) begin
                    if (ex_rd != 5'd0)
                        log_rd(ex_pc, ex_ins, ex_w[15:0], ex_is_c, ex_rd, bm_out);
                    else
                        log_nord(ex_pc, ex_ins, ex_w[15:0], ex_is_c);
                end else if (issue_bru) begin
                    if ((ex_sub == `BRU_JAL || ex_sub == `BRU_JALR) && ex_rd != 5'd0)
                        log_rd(ex_pc, ex_ins, ex_w[15:0], ex_is_c,
                               ex_rd, pc_next);
                    else
                        log_nord(ex_pc, ex_ins, ex_w[15:0], ex_is_c);
                end else if (issue_csr) begin
                    if (ex_rd != 5'd0)
                        log_rd(ex_pc, ex_ins, ex_w[15:0], ex_is_c,
                               ex_rd, csr_rd_v);
                    else
                        log_nord(ex_pc, ex_ins, ex_w[15:0], ex_is_c);
                end else if (issue_sys) begin
                    log_nord(ex_pc, ex_ins, ex_w[15:0], ex_is_c);
                end else if (issue_lsu) begin
                    if (lsu_is_store) begin
                        log_store(ex_pc, ex_ins, ex_w[15:0], ex_is_c,
                                  lsu_addr, lsu_wdata);
                    end else if (lsu_is_cbo) begin
                        log_nord(ex_pc, ex_ins, ex_w[15:0], ex_is_c);
                    end else if (ex_rd != 5'd0) begin
                        log_lpc      <= ex_pc;
                        log_lins     <= ex_ins;
                        log_lins16   <= ex_w[15:0];
                        log_lc       <= ex_is_c;
                        log_lrd      <= ex_rd;
                        log_laddr    <= lsu_addr;
                        log_lpending <= 1'b1;
                    end
                end else if (issue_m) begin
                    log_mpc      <= ex_pc;
                    log_mins     <= ex_ins;
                    log_mins16   <= ex_w[15:0];
                    log_mc       <= ex_is_c;
                    log_mrd      <= ex_rd;
                    log_mpending <= 1'b1;
                end else if (issue_fpu) begin
                    log_fpc       <= ex_pc;
                    log_fins      <= ex_ins;
                    log_fins16    <= ex_w[15:0];
                    log_fc        <= ex_is_c;
                    log_frd       <= ex_rd;
                    log_frd_is_f  <= ex_rd_is_f;
                    log_fpending  <= 1'b1;
                end
            end
        end
    end
`endif

endmodule

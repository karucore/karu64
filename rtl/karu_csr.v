//  karu_csr.v
//  Machine/Supervisor CSR file. This is intentionally still small: enough
//  M/S privilege state for an M-mode firmware to enter S-mode and delegate
//  synchronous traps, plus the CSRs Linux expects during early boot.
//
//  The op interface is sequential: assert `req` with the CSR addr,
//  source value, and operation; result and write-back are valid the
//  cycle after `req` (single-cycle CSR access).
//
//  Trap entry / mret are separate signals so the core's BRU/SYS unit
//  can drive them in parallel with normal CSR traffic.

`include "karu_ext.vh"
`include "karu_uop_defs.vh"
`include "karu_vcfg.vh"

module karu_csr (
    input  wire         clk,
    input  wire         rst,

    //  -- CSR access (csrrw/s/c[i]) --
    input  wire         op_req,
    input  wire [11:0]  op_addr,
    input  wire [63:0]  op_src,         //  rs1 or zext(imm)
    input  wire [4:0]   op_sub,         //  CSR_RW/RS/RC/RWI/RSI/RCI
    input  wire [4:0]   op_rs1,         //  for RS/RC gating (rs1==0 -> read only)
    output wire [63:0]  op_rd_v,        //  old CSR value -> rd
    output wire         csr_illegal,    //  1: addressed CSR is unimplemented -> illegal-instruction trap

    //  -- trap entry (ECALL/EBREAK/illegal) --
    input  wire         trap_req,
    input  wire [63:0]  trap_epc,
    input  wire [63:0]  trap_cause,
    input  wire [63:0]  trap_tval,
    output wire [63:0]  trap_vec,
    input  wire         irq_timer,
    input  wire         irq_external_m,
    input  wire         irq_external_s,
    output wire         irq_pending,
    output wire [63:0]  irq_cause,

    //  -- xret --
    input  wire         mret_req,
    input  wire         sret_req,
    output wire [63:0]  ret_pc,
    output wire [1:0]   priv_o,
    output wire [63:0]  satp_o,
    output wire         status_sum_o,
    output wire         status_mxr_o,
    output wire [5:0]   dpmlen_o,       //  Supm: data-access pointer-mask length (0/7/16)
    output wire         cbo_zero_en_o,  //  Zicboz cbo.zero permitted in current priv
    output wire         cbo_cf_en_o,    //  Zicbom cbo.clean/flush permitted
    output wire         cbo_inval_en_o, //  Zicbom cbo.inval permitted
    output wire         status_tvm_o,   //  mstatus.TVM (trap satp/sfence.vma in S)
    output wire         status_tw_o,    //  mstatus.TW  (trap wfi below M)
    output wire         status_tsr_o,   //  mstatus.TSR (trap sret in S)

    //  -- FP CSRs (fflags/frm/fcsr at 0x001/0x002/0x003) --
    input  wire         fflags_set,     //  pulse to OR fflags_in into fflags
    input  wire [4:0]   fflags_in,
    output wire [2:0]   frm,            //  current rounding mode for FPU

    //  -- Performance counters (free-running) --
    input  wire         retire,         //  pulse for every retired instruction
    input  wire [63:0]  cyc_in,         //  core-side cycle counter for cycle/mcycle reads
    input  wire [63:0]  time_in,        //  `time` counter for rdtime (0xC01) -- the CLINT
                                        //  mtime in CLINT builds, else = cyc_in (see karu64
                                        //  EXT_TIME). Must match mtimecmp's domain for Linux.
    input  wire [31:0]  hpm_events,     //  implementation-defined event pulses

    //  -- Vector CSRs (V extension) --
    input  wire         vset_req,       //  pulse: a vset* writes vl/vtype
    input  wire [63:0]  vset_vtype,     //  new vtype (vill in bit63)
    input  wire [63:0]  vset_vl,        //  new vl
    input  wire         v_retire,       //  pulse: a non-vset* vector op completed -> vstart <= 0
    input  wire         vl_trim_req,    //  pulse: fault-only-first trimmed vl (writes vl only)
    input  wire [63:0]  vl_trim_val,

    //  -- mstatus.FS/VS context-state tracking (Linux FP/vector prerequisite) --
    output wire [1:0]   status_fs_o,    //  2'b00 = Off -> the core traps FP ops/CSRs
    output wire [1:0]   status_vs_o,    //  2'b00 = Off -> the core traps vector ops/CSRs
    input  wire         fp_dirty,       //  pulse: a permitted FP op/CSR access issued
    input  wire         v_dirty,        //  pulse: a permitted vector op/CSR access issued
    output wire [63:0]  vl_o,           //  current vl  (for the vector units)
    output wire [63:0]  vtype_o,        //  current vtype
    output wire [63:0]  vstart_o,

    //  -- fixed-point CSRs (vxsat/vxrm) for the vector arith unit --
    input  wire         vxsat_set,      //  pulse: an op saturated (sticky OR into vxsat)
    output wire [1:0]   vxrm_o          //  current fixed-point rounding mode
);

    //  Local counters. mhpmcounter3..31 use mhpmevent3..31 as simple event IDs:
    //  a non-zero selector N increments on hpm_events[N].
    reg [63:0] csr_mcycle;
    reg [63:0] csr_instret;
    reg [63:0] csr_mcountinhibit;
`ifdef KARU_EN_HPM
    reg [63:0] csr_hpmcounter [0:28];
    reg [63:0] csr_mhpmevent  [0:28];
`endif
    reg [63:0] csr_mstatus;
    reg [63:0] csr_misa;
    reg [63:0] csr_medeleg;
    reg [63:0] csr_mideleg;
    reg [63:0] csr_mie;
    reg [63:0] csr_mtvec;
    reg [63:0] csr_mcounteren;
    reg [63:0] csr_mscratch;
    reg [63:0] csr_mepc;
    reg [63:0] csr_mcause;
    reg [63:0] csr_mtval;
    reg [63:0] csr_mip;
    reg [63:0] csr_scounteren;
    reg [63:0] csr_stvec;
    reg [63:0] csr_sscratch;
    reg [63:0] csr_sepc;
    reg [63:0] csr_scause;
    reg [63:0] csr_stval;
    reg [63:0] csr_satp;
    //  Supm pointer masking: PMM field of menvcfg (controls S-mode, Smnpm) and
    //  senvcfg (controls U-mode, Ssnpm). WARL 00=PMLEN0 / 10=PMLEN7 / 11=PMLEN16
    //  (01 reserved -> 00). Other envcfg bits stay read-0 (see note above).
    reg [1:0]  menvcfg_pmm;
    reg [1:0]  senvcfg_pmm;
    //  Zicbom/Zicboz envcfg enables: CBZE(7)/CBCFE(6)/CBIE(5:4) in menvcfg
    //  (gates S and U) and senvcfg (further gates U).
    reg        menvcfg_cbze, menvcfg_cbcfe; reg [1:0] menvcfg_cbie;
    reg        senvcfg_cbze, senvcfg_cbcfe; reg [1:0] senvcfg_cbie;
`ifdef KARU_EN_SSTATEEN
    //  Smstateen/Ssstateen. mstateen0 has two implemented gate bits: SE0(63, gates
    //  S access to sstateen0) and ENVCFG(62, gates S access to senvcfg). All other
    //  bits read-0 (their gated features are absent). Per the Smstateen spec, writable
    //  bits reset to 0 (deny) -- M-firmware opens what it delegates. ENVCFG is an
    //  mstateen0 bit (gates senvcfg), NOT an sstateen0 bit. sstateen0..3 and
    //  mstateen1..3 carry no implemented bits here, so they EXIST (access is WARL,
    //  not a trap) but read 0 and ignore writes -- only mstateen0 needs storage.
    //  Per-register SE: bit 63 of mstateenN gates sstateenN; mstateen1..3 are
    //  hardwired 0, so sstateen1..3 always trap from S (only sstateen0 is delegable).
    reg [63:0] csr_mstateen0;
    localparam [63:0] MSTATEEN0_WMASK = 64'hC000_0000_0000_0000;    //  [63]SE0 [62]ENVCFG
`endif
`ifdef KARU_EN_SMCNTRPMF
    //  Smcntrpmf: per-privilege inhibit of the fixed counters. mcyclecfg(0x321) and
    //  minstretcfg(0x322) carry MINH(62)/SINH(61)/UINH(60) -- when the bit for the
    //  current privilege is set, that counter does not increment. Mode bits for
    //  unimplemented privilege modes are read-only 0: SINH is writable only when S is
    //  present (U and M always are). VSINH/VUINH read 0 (no H). OF (bit 63) reads 0 --
    //  the fixed counters never raise LCOFI; Sscofpmf's OF is for the programmable
    //  mhpmevent counters, not these. Reset 0 (count all modes).
    reg [63:0] csr_mcyclecfg;
    reg [63:0] csr_minstretcfg;
`ifdef KARU_EN_S
    localparam [63:0] CNTRCFG_WMASK = 64'h7000_0000_0000_0000;  //  [62]MINH [61]SINH [60]UINH
`else
    localparam [63:0] CNTRCFG_WMASK = 64'h5000_0000_0000_0000;  //  [62]MINH [60]UINH (no S: SINH r/o 0)
`endif
`endif
`ifdef KARU_EN_SSCOFPMF
    //  Sscofpmf mhpmevent3..31 writable bits: OF(63) overflow + the Smcntrpmf-shared
    //  MINH(62)/SINH(61)/UINH(60) inhibit (SINH only with S; VSINH/VUINH no H) + the
    //  5-bit event selector [4:0]. All other bits read-0.
`ifdef KARU_EN_S
    localparam [63:0] MHPMEVENT_WMASK = 64'hF000_0000_0000_001F;    //  OF|MINH|SINH|UINH|evt
`else
    localparam [63:0] MHPMEVENT_WMASK = 64'hD000_0000_0000_001F;    //  OF|MINH|UINH|evt (no S)
`endif
`endif
    reg [1:0]  priv;
    localparam [1:0] PRIV_U = 2'd0;
    localparam [1:0] PRIV_S = 2'd1;
    localparam [1:0] PRIV_M = 2'd3;
    assign priv_o = priv;
`ifdef KARU_EN_S
    assign satp_o = csr_satp;
    assign status_sum_o = csr_mstatus[18];
    assign status_mxr_o = csr_mstatus[19];
    //  mstatus trap-virtualization bits (enforced in karu64): TVM(20)/TW(21)/TSR(22).
    assign status_tvm_o = csr_mstatus[20];
    assign status_tsr_o = csr_mstatus[22];
`else
    assign satp_o = 64'b0;
    assign status_sum_o = 1'b0;
    assign status_mxr_o = 1'b0;
    assign status_tvm_o = 1'b0;
    assign status_tsr_o = 1'b0;
`endif
    assign status_tw_o  = csr_mstatus[21];

    //  Data-access PMLEN for the CURRENT privilege (Smnpm in S, Ssnpm in U;
    //  M-mode masking via mseccfg is not implemented -> PMLEN 0). Fetch is never
    //  masked.
    function [5:0] pmm2len; input [1:0] pmm; begin
        pmm2len = (pmm == 2'b10) ? 6'd7 : (pmm == 2'b11) ? 6'd16 : 6'd0;
    end endfunction
`ifdef KARU_EN_S
    assign dpmlen_o = (priv == PRIV_U) ? pmm2len(senvcfg_pmm)
                    : (priv == PRIV_S) ? pmm2len(menvcfg_pmm) : 6'd0;

    //  CBO per-class enable for the CURRENT privilege (M always; S needs
    //  menvcfg; U needs both menvcfg and senvcfg). inval is enabled when
    //  CBIE != 00 (01=inval, 11=flush; 10 reserved).
    assign cbo_zero_en_o = (priv == PRIV_M)
        || (priv == PRIV_S && menvcfg_cbze)
        || (priv == PRIV_U && menvcfg_cbze && senvcfg_cbze);
    assign cbo_cf_en_o = (priv == PRIV_M)
        || (priv == PRIV_S && menvcfg_cbcfe)
        || (priv == PRIV_U && menvcfg_cbcfe && senvcfg_cbcfe);
    assign cbo_inval_en_o = (priv == PRIV_M)
        || (priv == PRIV_S && (menvcfg_cbie != 2'b00))
        || (priv == PRIV_U && (menvcfg_cbie != 2'b00) && (senvcfg_cbie != 2'b00));
`else
    assign dpmlen_o = 6'd0;
    assign cbo_zero_en_o = (priv == PRIV_M);
    assign cbo_cf_en_o = (priv == PRIV_M);
    assign cbo_inval_en_o = (priv == PRIV_M);
`endif
    assign status_fs_o  = csr_mstatus[14:13];
    assign status_vs_o  = csr_mstatus[10:9];

    //  mip bits driven by hardware (MTIP/SEIP/MEIP from irq_timer/external) are
    //  read-only: a CSRRS/CSRRC read-modify-write must NOT latch them back into
    //  csr_mip (e.g. OpenSBI's csr_set(mip, STIP) while MTIP is pending would
    //  otherwise stick MTIP high and wedge the timer).
    localparam [63:0] MIP_HW = 64'h0000_0000_0000_0a80; //  MTIP(7)|SEIP(9)|MEIP(11)
    //  FS (14:13) and VS (10:9) are writable only when the matching extension
    //  exists (read-only 0 otherwise); XS (16:15) is read-only 0 (no custom
    //  stateful extensions); SD (63) is derived read-only from FS/VS/XS dirty
    //  (sd_w below). Base masks exclude all four fields; the fsvs census case
    //  pins every expected-writable bit and the read-only XS field.
    localparam [63:0] MSTATUS_WMASK = 64'h0000_0000_007e_19aa
`ifdef KARU_EN_F
        | 64'h0000_0000_0000_6000       //  FS
`endif
`ifdef KARU_EN_V
        | 64'h0000_0000_0000_0600       //  VS
`endif
        ;
    localparam [63:0] SSTATUS_WMASK = 64'h0000_0000_000c_0122
`ifdef KARU_EN_F
        | 64'h0000_0000_0000_6000
`endif
`ifdef KARU_EN_V
        | 64'h0000_0000_0000_0600
`endif
        ;
    localparam [63:0] SSTATUS_RMASK = SSTATUS_WMASK | 64'h8000_0000_0000_0000;
`ifdef KARU_EN_S
    localparam [63:0] MSTATUS_XLEN  = 64'h0000_000a_0000_0000;  //  SXL=UXL=64
`else
    localparam [63:0] MSTATUS_XLEN  = 64'h0000_0002_0000_0000;  //  UXL=64
`endif
    localparam [63:0] SSTATUS_XLEN  = 64'h0000_0002_0000_0000;  //  UXL=64
    localparam [63:0] MISA_RESET =
        64'h8000_0000_0000_0000 |   //  MXL=2 (RV64)
        64'h0000_0000_0010_0104 |   //  U, I, C
`ifdef KARU_EN_S
        64'h0000_0000_0004_0000 |   //  S
`endif
`ifdef KARU_EN_A
        64'h0000_0000_0000_0001 |
`endif
`ifdef KARU_EN_B
        64'h0000_0000_0000_0002 |
`endif
`ifdef KARU_EN_M
        64'h0000_0000_0000_1000 |
`endif
`ifdef KARU_EN_F
        64'h0000_0000_0000_0020 |
`endif
`ifdef KARU_EN_D
        64'h0000_0000_0000_0008 |
`endif
`ifdef KARU_EN_V
        64'h0000_0000_0020_0000 |
`endif
        64'b0;

    //  SD (63): read-only, derived -- some context state is Dirty. The stored
    //  bit 63 is never written (excluded from both write masks, reset 0), so
    //  the read views just OR the derived value in.
    wire        sd_w = (csr_mstatus[14:13] == 2'b11) || (csr_mstatus[16:15] == 2'b11)
                    || (csr_mstatus[10:9]  == 2'b11);
    wire [63:0] sd_v = {sd_w, 63'b0};
    wire [63:0] mstatus_v = (csr_mstatus & ~MSTATUS_XLEN) | MSTATUS_XLEN | sd_v;
`ifdef KARU_EN_S
    wire [63:0] sstatus_v = ((csr_mstatus | sd_v) & SSTATUS_RMASK) | SSTATUS_XLEN;
`endif
    wire [63:0] mip_v = csr_mip |
        (irq_timer      ? 64'h0000_0000_0000_0080 : 64'b0) |
`ifdef KARU_EN_S
        (irq_external_s ? 64'h0000_0000_0000_0200 : 64'b0) |
`endif
        (irq_external_m ? 64'h0000_0000_0000_0800 : 64'b0);
`ifdef KARU_EN_S
    wire [63:0] sie_v = csr_mie & csr_mideleg;
    wire [63:0] sip_v = mip_v & csr_mideleg;
    wire        trap_deleg = priv != PRIV_M &&
        (trap_cause[63] ? csr_mideleg[trap_cause[5:0]] :
                           csr_medeleg[trap_cause[5:0]]);
    wire [63:0] irq_pend = mip_v & csr_mie;
    wire [63:0] irq_m_pend = irq_pend & ~csr_mideleg;
    wire [63:0] irq_s_pend = irq_pend &  csr_mideleg;
    wire        irq_m_enable = (priv != PRIV_M) || csr_mstatus[3];  //  MIE
    wire        irq_s_enable = (priv == PRIV_U) ||
                               (priv == PRIV_S && csr_mstatus[1]);  //  SIE
    wire        irq_meip = irq_m_enable && irq_m_pend[11];
    wire        irq_msip = irq_m_enable && irq_m_pend[3];
    wire        irq_mtip = irq_m_enable && irq_m_pend[7];
    wire        irq_seip = irq_s_enable && irq_s_pend[9];
    wire        irq_ssip = irq_s_enable && irq_s_pend[1];
    wire        irq_stip = irq_s_enable && irq_s_pend[5];
`ifdef KARU_EN_SSCOFPMF
    wire        irq_mlcofi = irq_m_enable && irq_m_pend[13];    //  LCOFI -> M
    wire        irq_slcofi = irq_s_enable && irq_s_pend[13];    //  LCOFI -> S (delegated)
`endif
    assign irq_pending = irq_meip || irq_msip || irq_mtip ||
                         irq_seip || irq_ssip || irq_stip
`ifdef KARU_EN_SSCOFPMF
                         || irq_mlcofi || irq_slcofi
`endif
                         ;
    assign irq_cause =
        irq_meip ? 64'h8000_0000_0000_000b :
        irq_msip ? 64'h8000_0000_0000_0003 :
        irq_mtip ? 64'h8000_0000_0000_0007 :
`ifdef KARU_EN_SSCOFPMF
        //  M-destined LCOFI: lowest of the M-destined group (below MTI) but still
        //  above ALL S-destined interrupts, since M delivery outranks S delivery.
        irq_mlcofi ? 64'h8000_0000_0000_000d :
`endif
        irq_seip ? 64'h8000_0000_0000_0009 :
        irq_ssip ? 64'h8000_0000_0000_0001 :
`ifdef KARU_EN_SSCOFPMF
        //  S-destined LCOFI: lowest of the S-destined group (below delegated STIP).
        irq_stip ? 64'h8000_0000_0000_0005 :
        irq_slcofi ? 64'h8000_0000_0000_000d :
                   64'h8000_0000_0000_000d;
`else
                   64'h8000_0000_0000_0005; //  STIP (default)
`endif
`else
    wire        trap_deleg = 1'b0;
    wire [63:0] irq_pend = mip_v & csr_mie;
    wire        irq_m_enable = (priv != PRIV_M) || csr_mstatus[3];  //  MIE
    wire        irq_meip = irq_m_enable && irq_pend[11];
    wire        irq_msip = irq_m_enable && irq_pend[3];
    wire        irq_mtip = irq_m_enable && irq_pend[7];
`ifdef KARU_EN_SSCOFPMF
    wire        irq_mlcofi = irq_m_enable && irq_pend[13];  //  LCOFI -> M
`endif
    assign irq_pending = irq_meip || irq_msip || irq_mtip
`ifdef KARU_EN_SSCOFPMF
                         || irq_mlcofi
`endif
                         ;
    assign irq_cause =
        irq_meip ? 64'h8000_0000_0000_000b :
        irq_msip ? 64'h8000_0000_0000_0003 :
`ifdef KARU_EN_SSCOFPMF
        irq_mtip ? 64'h8000_0000_0000_0007 :
        irq_mlcofi ? 64'h8000_0000_0000_000d :  //  LCOFI = 13
                   64'h8000_0000_0000_000d;
`else
                   64'h8000_0000_0000_0007;
`endif
`endif

    //  FP CSRs: fflags = sticky exception flags, frm = rounding mode.
    //  fcsr is the concat: {24'b0, frm, fflags} read at 0x003.
    reg [4:0]  csr_fflags;
    reg [2:0]  csr_frm;
    assign     frm = csr_frm;

    //  Vector CSRs.
    reg [63:0] csr_vtype;   //  vill in bit63
    reg [63:0] csr_vl;
    reg [63:0] csr_vstart;
    reg        csr_vxsat;
    reg [1:0]  csr_vxrm;
    assign vl_o     = csr_vl;
    assign vtype_o  = csr_vtype;
    assign vstart_o = csr_vstart;
    assign vxrm_o   = csr_vxrm;

    wire hpm_csr_addr = (op_addr >= 12'hB03 && op_addr <= 12'hB1F) ||
                        (op_addr >= 12'hC03 && op_addr <= 12'hC1F) ||
                        (op_addr >= 12'h323 && op_addr <= 12'h33F);

`ifdef KARU_EN_HPM
    function hpm_event_hit;
        input [63:0] event_id;
        begin
`ifdef KARU_EN_SSCOFPMF
            //  Sscofpmf uses [63:58] for OF/inhibit -- match only the event selector
            //  [4:0] (reserved [57:5] must be 0); ignore the OF/MINH/SINH/UINH bits.
            hpm_event_hit = (event_id[57:5] == 0) ? hpm_events[event_id[4:0]] : 1'b0;
`else
            hpm_event_hit = (event_id[63:5] == 0) ? hpm_events[event_id[4:0]] : 1'b0;
`endif
        end
    endfunction
`ifdef KARU_EN_SSCOFPMF
    //  Sscofpmf per-privilege inhibit for an HPM counter, from its mhpmevent
    //  MINH(62)/SINH(61)/UINH(60) bits at the CURRENT privilege.
    function hpm_pinh;
        input [63:0] ev;
        begin
            hpm_pinh = (priv == PRIV_M) ? ev[62]
                     : (priv == PRIV_S) ? ev[61]
                     :                    ev[60];
        end
    endfunction
`endif

    function [63:0] read_hpm;
        input [11:0] addr;
        integer idx;
        begin
            if (addr >= 12'hB03 && addr <= 12'hB1F) begin
                idx = addr - 12'hB03;
                read_hpm = csr_hpmcounter[idx];
            end else if (addr >= 12'hC03 && addr <= 12'hC1F) begin
                idx = addr - 12'hC03;
                read_hpm = csr_hpmcounter[idx];
            end else if (addr >= 12'h323 && addr <= 12'h33F) begin
                idx = addr - 12'h323;
                read_hpm = csr_mhpmevent[idx];
            end else begin
                read_hpm = 64'b0;
            end
        end
    endfunction
`ifdef KARU_EN_SSCOFPMF
    //  scountovf: bit N (N=3..31) = mhpmevent[N-3].OF (bit 63); bits 0..2, 32..63 = 0.
    //  Combinational net, NOT a function: Vivado synth rejects a zero-input function
    //  (Synth 8-10738), while iverilog/verilator accept it. An always @(*) over the
    //  module-scope mhpmevent array is identical logic and portable across all three.
    reg  [63:0] scountovf_bits;
    integer     scov_k;
    always @(*) begin
        scountovf_bits = 64'b0;
        for (scov_k = 0; scov_k < 29; scov_k = scov_k + 1)
            scountovf_bits[scov_k + 3] = csr_mhpmevent[scov_k][63];
    end
`endif
    wire [63:0] hpm_rd_v = read_hpm(op_addr);
`else
    wire [63:0] hpm_rd_v = 64'b0;
`endif

    //  -- read value (combinational) --
    wire [63:0] rd_v_w =
        op_addr == 12'h001 ? {59'b0, csr_fflags} :
        op_addr == 12'h002 ? {61'b0, csr_frm}    :
        op_addr == 12'h003 ? {56'b0, csr_frm, csr_fflags} :
`ifdef KARU_EN_S
        op_addr == 12'h100 ? sstatus_v    :
        op_addr == 12'h104 ? sie_v        :
        op_addr == 12'h105 ? csr_stvec    :
        op_addr == 12'h106 ? csr_scounteren :
        op_addr == 12'h140 ? csr_sscratch :
        op_addr == 12'h141 ? csr_sepc     :
        op_addr == 12'h142 ? csr_scause   :
        op_addr == 12'h143 ? csr_stval    :
        op_addr == 12'h144 ? sip_v        :
        op_addr == 12'h180 ? csr_satp     :
        op_addr == 12'h30A ? {30'b0, menvcfg_pmm, 24'b0, menvcfg_cbze, menvcfg_cbcfe, menvcfg_cbie, 4'b0} : //  menvcfg
        op_addr == 12'h10A ? {30'b0, senvcfg_pmm, 24'b0, senvcfg_cbze, senvcfg_cbcfe, senvcfg_cbie, 4'b0} : //  senvcfg
`ifdef KARU_EN_SSTATEEN
        op_addr == 12'h30C ? csr_mstateen0 :    //  mstateen0 (sstateen0..3/mstateen1..3 read 0)
`endif
`endif
        op_addr == 12'h300 ? mstatus_v    :
        op_addr == 12'h301 ? csr_misa     :
`ifdef KARU_EN_S
        op_addr == 12'h302 ? csr_medeleg  :
        op_addr == 12'h303 ? csr_mideleg  :
`endif
        op_addr == 12'h304 ? csr_mie      :
        op_addr == 12'h305 ? csr_mtvec    :
        op_addr == 12'h306 ? csr_mcounteren :
        op_addr == 12'h320 ? csr_mcountinhibit :
`ifdef KARU_EN_SMCNTRPMF
        op_addr == 12'h321 ? csr_mcyclecfg   :  //  mcyclecfg
        op_addr == 12'h322 ? csr_minstretcfg :  //  minstretcfg
`endif
`ifdef KARU_EN_SSCOFPMF
        op_addr == 12'hDA0 ? (scountovf_bits &
            ((priv == PRIV_M) ? 64'hFFFF_FFFF_FFFF_FFFF : csr_mcounteren)) :    //  scountovf (M:all, S:mcounteren-gated)
`endif
        op_addr == 12'h340 ? csr_mscratch :
        op_addr == 12'h341 ? csr_mepc     :
        op_addr == 12'h342 ? csr_mcause   :
        op_addr == 12'h343 ? csr_mtval    :
        op_addr == 12'h344 ? mip_v        :
        op_addr == 12'hf11 ? 64'b0        : //  mvendorid
        op_addr == 12'hf12 ? 64'b0        : //  marchid
        op_addr == 12'hf13 ? 64'b0        : //  mimpid
        op_addr == 12'hf14 ? 64'b0        : //  mhartid
        op_addr == 12'hC00 ? csr_mcycle   : //  cycle (user-mode shadow)
        op_addr == 12'hC01 ? time_in      : //  time (rdtime) -- CLINT mtime domain
        op_addr == 12'hC02 ? csr_instret  : //  instret
        op_addr == 12'hB00 ? csr_mcycle   : //  mcycle
        op_addr == 12'hB02 ? csr_instret  : //  minstret
        hpm_csr_addr ? hpm_rd_v :
        op_addr == 12'h008 ? csr_vstart   : //  vstart
        op_addr == 12'h009 ? {63'b0, csr_vxsat}        :    //  vxsat
        op_addr == 12'h00A ? {62'b0, csr_vxrm}         :    //  vxrm
        op_addr == 12'h00F ? {61'b0, csr_vxrm, csr_vxsat} : //  vcsr
        op_addr == 12'hC20 ? csr_vl       : //  vl
        op_addr == 12'hC21 ? csr_vtype    : //  vtype
        op_addr == 12'hC22 ? `KARU_VLENB  : //  vlenb (VLEN/8, read-only)
                             64'b0;

    //  === CSR legality gate ===
    //  Absent CSRs must raise an illegal-instruction trap, not silently read 0:
    //  M-mode firmware probes optional extensions by touching their CSRs under a
    //  trap handler, so "no trap" reads as "present". Concretely, OpenSBI reads
    //  mtopi (0xFB0) to detect Smaia; if that returns 0 it routes the M-timer
    //  through the AIA mtopi dispatch, which also reads 0, so the timer is never
    //  serviced and Linux wedges at sched_clock. (The same non-trapping behaviour
    //  falsely advertised Sstc/Sdtrig; Smstateen is real under KARU_EN_SSTATEEN.) The whitelist below is every
    //  CSR this core implements as a real or WARL(read-0) value; everything else
    //  traps. Also enforce minimum privilege (csr[9:8]) and read-only (csr[11:10]
    //  == 2'b11) on actual writes.
    //  NOTE: menvcfg(0x30A)/senvcfg(0x10A)/mconfigptr(0xF15) are deliberately
    //  WARL read-0 (writes dropped). This lets OpenSBI see Priv v1.12, which is
    //  harmless here because every config bit -- including menvcfg.STCE -- reads
    //  0, so no feature (Sstc, Svpbmt, ...) is ever enabled through them. The
    //  timer-breaking detections (Smaia via mtopi, Sstc via stimecmp) are absent
    //  and trap.
    function csr_present;
        input [11:0] a;
        begin
            case (a)
                12'h001, 12'h002, 12'h003,                  //  fflags/frm/fcsr
                12'h008, 12'h009, 12'h00A, 12'h00F,         //  vstart/vxsat/vxrm/vcsr
                12'hC20, 12'hC21, 12'hC22,                  //  vl/vtype/vlenb
`ifdef KARU_EN_S
                12'h100, 12'h104, 12'h105, 12'h106, 12'h10A,//  sstatus/sie/stvec/scounteren/senvcfg
                12'h140, 12'h141, 12'h142, 12'h143, 12'h144, 12'h180,
                12'h302, 12'h303,                           //  medeleg/mideleg
`ifdef KARU_EN_SSTATEEN
                12'h10C, 12'h10D, 12'h10E, 12'h10F,         //  sstateen0 SE0-gated; sstateen1..3 S-trap/read-0
                12'h30C, 12'h30D, 12'h30E, 12'h30F,         //  mstateen0..3 (1..3 read-0)
`endif
`endif
                12'h300, 12'h301, 12'h304, 12'h305, 12'h306,
`ifdef KARU_EN_S
                12'h30A,                                    //  menvcfg
`endif
                12'h320,                                    //  mcountinhibit
`ifdef KARU_EN_SMCNTRPMF
                12'h321, 12'h322,                           //  mcyclecfg/minstretcfg (Smcntrpmf)
`endif
`ifdef KARU_EN_SSCOFPMF
                12'hDA0,                                    //  scountovf (Sscofpmf, read-only)
`endif
                12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
                12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hF15,//  mvendorid/marchid/mimpid/mhartid/mconfigptr
                12'hC00, 12'hC01, 12'hC02, 12'hB00, 12'hB02:
                    csr_present = 1'b1;
                default:
                    csr_present =
`ifdef KARU_EN_HPM
                        (a >= 12'hB03 && a <= 12'hB1F) ||   //  mhpmcounter3..31
                        (a >= 12'hC03 && a <= 12'hC1F) ||   //  hpmcounter3..31
                        (a >= 12'h323 && a <= 12'h33F) ||   //  mhpmevent3..31
`endif
                        (a >= 12'h3A0 && a <= 12'h3AF) ||   //  pmpcfg0..15  (WARL, reads 0)
                        (a >= 12'h3B0 && a <= 12'h3EF);     //  pmpaddr0..63 (WARL, reads 0)
            endcase
        end
    endfunction

    wire [63:0] new_v_w =
        op_sub == `CSR_RW || op_sub == `CSR_RWI ? op_src               :
        op_sub == `CSR_RS || op_sub == `CSR_RSI ? rd_v_w |  op_src     :
        op_sub == `CSR_RC || op_sub == `CSR_RCI ? rd_v_w & ~op_src     :
                                                  rd_v_w;

    //  Write enable: RW always writes; RS/RC write only if source is
    //  non-zero (rs1 != x0 for reg form, imm != 0 for I form). We
    //  approximate with rs1 != 0 -- the I-form imm is uimm[4:0] so it
    //  being zero is the same condition.
    wire wen_w =
        (op_sub == `CSR_RW || op_sub == `CSR_RWI) ||
        ((op_sub == `CSR_RS || op_sub == `CSR_RC ||
          op_sub == `CSR_RSI || op_sub == `CSR_RCI) && op_rs1 != 5'd0);

    //  CSR legality: unimplemented CSR, insufficient privilege (csr[9:8] is the
    //  minimum mode), or a write to a read-only CSR (csr[11:10]==2'b11) that the
    //  instruction actually performs (wen_w).
    //  Zihpm/Zicntr counter-enable gating (privileged spec): the user counter
    //  shadows cycle/time/instret (0xC00-0xC02) and hpmcounter3..31 (0xC03-0xC1F)
    //  trap in S unless mcounteren[idx], and in U unless BOTH mcounteren[idx] and
    //  scounteren[idx]. (M-mode counters 0xB.. are already M-only via priv[9:8].)
    wire        ctr_is = (op_addr >= 12'hC00) && (op_addr <= 12'hC1F);
    wire [4:0]  ctr_idx = op_addr[4:0];
    wire        ctr_blocked = ctr_is && (priv != PRIV_M)
        && (!csr_mcounteren[ctr_idx]
`ifdef KARU_EN_S
            || (priv == PRIV_U && !csr_scounteren[ctr_idx])
`endif
            );

    //  TVM: when mstatus.TVM=1, an S-mode access to satp (read or write) is
    //  illegal (forces the OS to trap to M for address-space changes).
`ifdef KARU_EN_S
    wire satp_tvm_block = (op_addr == 12'h180) && (priv == PRIV_S) && csr_mstatus[20];
`else
    wire satp_tvm_block = 1'b0;
`endif

    //  Smstateen: when an mstateen0 gate bit is 0, S-mode access to the gated
    //  extension CSR traps illegal (senvcfg via ENVCFG[62]; sstateen0 via SE0[63]).
    //  mstateen0 itself is M-only (priv check) and the gated CSRs are S-min, so U is
    //  already blocked by priv -- no U-side term needed for the current feature set.
`ifdef KARU_EN_SSTATEEN
    wire stateen_block = (priv == PRIV_S) &&
        ( ((op_addr == 12'h10A) && !csr_mstateen0[62])      //  senvcfg via mstateen0.ENVCFG
        ||((op_addr == 12'h10C) && !csr_mstateen0[63])      //  sstateen0 via mstateen0.SE0
        ||((op_addr >= 12'h10D) && (op_addr <= 12'h10F)) ); //  sstateen1..3: mstateen1..3[63]=0 -> always trap from S
`else
    wire stateen_block = 1'b0;
`endif

    assign csr_illegal =
        !csr_present(op_addr) ||
        (priv < op_addr[9:8]) ||
        ctr_blocked ||
        satp_tvm_block ||
        stateen_block ||
        ((op_addr[11:10] == 2'b11) && wen_w);

    //  An illegal CSR access traps and must NOT modify architectural state, so
    //  the actual write fires only when the access is legal.
    wire csr_w_fire = op_req && wen_w && !csr_illegal;

    //  Smcntrpmf per-privilege inhibit for the CURRENT privilege: when set, the
    //  matching fixed counter is frozen this cycle (mcycle uses the cycle's priv;
    //  minstret the retiring instruction's priv -- both = the current `priv` reg,
    //  which updates only on next cycle's trap/xret).
`ifdef KARU_EN_SMCNTRPMF
    wire cyc_pinh = (priv == PRIV_M) ? csr_mcyclecfg[62]
                  : (priv == PRIV_S) ? csr_mcyclecfg[61]
                  :                    csr_mcyclecfg[60];
    wire ir_pinh  = (priv == PRIV_M) ? csr_minstretcfg[62]
                  : (priv == PRIV_S) ? csr_minstretcfg[61]
                  :                    csr_minstretcfg[60];
`else
    wire cyc_pinh = 1'b0;
    wire ir_pinh  = 1'b0;
`endif

`ifdef KARU_EN_HPM
    integer hpm_i;
`ifdef KARU_EN_SSCOFPMF
    reg         lcofi_set;  //  some HPM counter overflowed this cycle (-> set mip[13])
    reg [28:0]  hpm_ovf;    //  per-counter overflow this cycle (-> set that counter's OF)
`endif
`endif
    always @(posedge clk) begin
        if (rst) begin
            csr_mcycle   <= 0;
            csr_instret  <= 0;
            csr_mcountinhibit <= 0;
`ifdef KARU_EN_HPM
            for (hpm_i = 0; hpm_i < 29; hpm_i = hpm_i + 1) begin
                csr_hpmcounter[hpm_i] <= 64'b0;
                csr_mhpmevent[hpm_i] <= 64'b0;
            end
`endif
            csr_mstatus  <= 0;
            csr_misa     <= MISA_RESET;
            csr_medeleg  <= 0;
            csr_mideleg  <= 0;
            csr_mie      <= 0;
            csr_mtvec    <= 0;
            csr_mcounteren <= 0;
            csr_mscratch <= 0;
            csr_mepc     <= 0;
            csr_mcause   <= 0;
            csr_mtval    <= 0;
            csr_mip      <= 0;
            csr_scounteren <= 0;
            csr_stvec    <= 0;
            csr_sscratch <= 0;
            csr_sepc     <= 0;
            csr_scause   <= 0;
            csr_stval    <= 0;
            csr_satp     <= 0;
            menvcfg_pmm  <= 2'b00;
            senvcfg_pmm  <= 2'b00;
            menvcfg_cbze <= 1'b0; menvcfg_cbcfe <= 1'b0; menvcfg_cbie <= 2'b00;
            senvcfg_cbze <= 1'b0; senvcfg_cbcfe <= 1'b0; senvcfg_cbie <= 2'b00;
`ifdef KARU_EN_SSTATEEN
            csr_mstateen0 <= 64'b0; //  Smstateen: writable bits reset to 0 (deny; M-firmware opens)
`endif
`ifdef KARU_EN_SMCNTRPMF
            csr_mcyclecfg   <= 64'b0;   //  Smcntrpmf: no inhibit at reset (count all modes)
            csr_minstretcfg <= 64'b0;
`endif
            priv         <= PRIV_M;
            csr_fflags   <= 0;
            csr_frm      <= 0;
            csr_vtype    <= 64'h8000_0000_0000_0000;    //  vill=1 at reset
            csr_vl       <= 0;
            csr_vstart   <= 0;
            csr_vxsat    <= 0;
            csr_vxrm     <= 0;
        end else begin
            if (!csr_mcountinhibit[0] && !cyc_pinh)
                csr_mcycle <= csr_mcycle + 64'b1;
            if (retire && !csr_mcountinhibit[2] && !ir_pinh)
                csr_instret <= csr_instret + 64'b1;
`ifdef KARU_EN_HPM
`ifdef KARU_EN_SSCOFPMF
            lcofi_set = 1'b0;
`endif
            for (hpm_i = 0; hpm_i < 29; hpm_i = hpm_i + 1) begin
`ifdef KARU_EN_SSCOFPMF
                hpm_ovf[hpm_i] = 1'b0;
`endif
                if (!csr_mcountinhibit[hpm_i + 3] &&
                    hpm_event_hit(csr_mhpmevent[hpm_i])
`ifdef KARU_EN_SSCOFPMF
                    && !hpm_pinh(csr_mhpmevent[hpm_i])
`endif
                    ) begin
                    csr_hpmcounter[hpm_i] <= csr_hpmcounter[hpm_i] + 64'b1;
`ifdef KARU_EN_SSCOFPMF
                    //  overflow happens ONLY here -- on a genuine increment whose
                    //  pre-value is all-ones (a wrap), never on a CSR write.
                    if (&csr_hpmcounter[hpm_i]) begin
                        hpm_ovf[hpm_i] = 1'b1;          //  OF is sticky status (set on every wrap)
                        //  OF also disables the overflow interrupt: a wrap while OF is
                        //  already set does NOT request a new LCOFI (counter still wraps).
                        if (!csr_mhpmevent[hpm_i][63])
                            lcofi_set = 1'b1;
                    end
`endif
                end
            end
`endif
            if (csr_w_fire) begin
                case (op_addr)
                    12'h001: csr_fflags    <= new_v_w[4:0];
                    12'h002: csr_frm       <= new_v_w[2:0];
                    12'h003: begin
                        csr_fflags  <= new_v_w[4:0];
                        csr_frm     <= new_v_w[7:5];
                    end
                    12'h008: csr_vstart <= new_v_w;
                    12'h009: csr_vxsat  <= new_v_w[0];
                    12'h00A: csr_vxrm   <= new_v_w[1:0];
                    12'h00F: begin csr_vxsat <= new_v_w[0]; csr_vxrm <= new_v_w[2:1]; end
                    12'h100: csr_mstatus  <= (csr_mstatus & ~SSTATUS_WMASK)
                                            | (new_v_w & SSTATUS_WMASK);
                    12'h104: csr_mie      <= (csr_mie & ~csr_mideleg)
                                            | (new_v_w & csr_mideleg);
                    12'h105: csr_stvec    <= {new_v_w[63:2],        //  WARL: modes 2/3
                                    new_v_w[1] ? 2'b00 : new_v_w[1:0]}; //  reserved -> direct
                    12'h106: csr_scounteren <= new_v_w;
                    //  senvcfg/menvcfg: PMM [33:32] (WARL 01->00) + the Zicbo
                    //  enables CBZE(7)/CBCFE(6)/CBIE(5:4); other bits stay read-0.
                    12'h10A: begin
                        senvcfg_pmm  <= (new_v_w[33:32] == 2'b01) ? 2'b00 : new_v_w[33:32];
                        senvcfg_cbze <= new_v_w[7]; senvcfg_cbcfe <= new_v_w[6];
                        senvcfg_cbie <= (new_v_w[5:4] == 2'b10) ? 2'b00 : new_v_w[5:4]; //  10 reserved
                    end
                    12'h140: csr_sscratch <= new_v_w;
                    12'h141: csr_sepc     <= new_v_w;
                    12'h142: csr_scause   <= new_v_w;
                    12'h143: csr_stval    <= new_v_w;
                    12'h144: csr_mip      <= (csr_mip & ~csr_mideleg)
                                            | (new_v_w & csr_mideleg & ~MIP_HW);
                    12'h180: csr_satp     <= new_v_w;
                    12'h300: csr_mstatus  <= (csr_mstatus & ~MSTATUS_WMASK)
                                            | (new_v_w & MSTATUS_WMASK);
                    12'h302: csr_medeleg  <= new_v_w;
                    12'h303: csr_mideleg  <= new_v_w;
                    12'h304: csr_mie      <= new_v_w;
                    12'h305: csr_mtvec    <= {new_v_w[63:2],        //  WARL: modes 2/3
                                    new_v_w[1] ? 2'b00 : new_v_w[1:0]}; //  reserved -> direct
                    12'h306: csr_mcounteren <= new_v_w;
                    12'h30A: begin
                        menvcfg_pmm  <= (new_v_w[33:32] == 2'b01) ? 2'b00 : new_v_w[33:32];
                        menvcfg_cbze <= new_v_w[7]; menvcfg_cbcfe <= new_v_w[6];
                        menvcfg_cbie <= (new_v_w[5:4] == 2'b10) ? 2'b00 : new_v_w[5:4];
                    end
`ifdef KARU_EN_SSTATEEN
                    12'h30C: csr_mstateen0 <= new_v_w & MSTATEEN0_WMASK;
`endif
                    12'h320: csr_mcountinhibit <= new_v_w;
`ifdef KARU_EN_SMCNTRPMF
                    12'h321: csr_mcyclecfg   <= new_v_w & CNTRCFG_WMASK;
                    12'h322: csr_minstretcfg <= new_v_w & CNTRCFG_WMASK;
`endif
                    12'h340: csr_mscratch <= new_v_w;
                    12'h341: csr_mepc     <= new_v_w;
                    12'h342: csr_mcause   <= new_v_w;
                    12'h343: csr_mtval    <= new_v_w;
                    12'h344: csr_mip      <= new_v_w & ~MIP_HW;
                    12'hB00: csr_mcycle   <= new_v_w;
                    12'hB02: csr_instret  <= new_v_w;
`ifdef KARU_EN_HPM
                    default: begin
                        if (op_addr >= 12'hB03 && op_addr <= 12'hB1F)
                            csr_hpmcounter[op_addr - 12'hB03] <= new_v_w;
                        else if (op_addr >= 12'h323 && op_addr <= 12'h33F)
`ifdef KARU_EN_SSCOFPMF
                            csr_mhpmevent[op_addr - 12'h323] <= new_v_w & MHPMEVENT_WMASK;
`else
                            csr_mhpmevent[op_addr - 12'h323] <= new_v_w;
`endif
                    end
`endif
                endcase
            end
`ifdef KARU_EN_SSCOFPMF
            //  Hardware counter overflow: set OF + the LCOFI pending bit, applied
            //  AFTER the CSR-write case so a genuine overflow wins over a same-cycle
            //  software clear of OF/mip[13]. Both are latches: once set they hold
            //  until software clears them, so one overflow raises LCOFI exactly once
            //  (the free-running counter will not wrap again for 2^64 events, and OF
            //  staying set does NOT re-raise mip[13] -- it is set only on the wrap).
            for (hpm_i = 0; hpm_i < 29; hpm_i = hpm_i + 1)
                if (hpm_ovf[hpm_i])
                    csr_mhpmevent[hpm_i][63] <= 1'b1;   //  set OF
            if (lcofi_set)
                csr_mip[13] <= 1'b1;            //  set LCOFIP (mip bit 13)
`endif
            //  FPU op sticky-OR into fflags (lower priority than explicit
            //  CSR write of fflags this same cycle — write wins).
            if (fflags_set && !(csr_w_fire
                && (op_addr == 12'h001 || op_addr == 12'h003)))
                csr_fflags <= csr_fflags | fflags_in;
            //  vector fixed-point op saturated -> sticky-set vxsat (an
            //  explicit write of vxsat/vcsr this same cycle wins).
            if (vxsat_set && !(csr_w_fire
                && (op_addr == 12'h009 || op_addr == 12'h00F)))
                csr_vxsat <= 1'b1;
            if (trap_req) begin
                if (trap_deleg) begin
                    csr_sepc    <= trap_epc;
                    csr_scause  <= trap_cause;
                    csr_stval   <= trap_tval;
                    csr_mstatus[8] <= priv[0];  //  SPP
                    csr_mstatus[5] <= csr_mstatus[1];   //  SPIE <- SIE
                    csr_mstatus[1] <= 1'b0; //  SIE <- 0
                    priv <= PRIV_S;
                end else begin
                    csr_mepc    <= trap_epc;
                    csr_mcause  <= trap_cause;
                    csr_mtval   <= trap_tval;
                    csr_mstatus[12:11] <= priv; //  MPP
                    csr_mstatus[7] <= csr_mstatus[3];   //  MPIE <- MIE
                    csr_mstatus[3] <= 1'b0; //  MIE <- 0
                    priv <= PRIV_M;
                end
            end
            //  vset* writes vl/vtype and clears vstart.
            if (vset_req) begin
                csr_vtype  <= vset_vtype;
                csr_vl     <= vset_vl;
                csr_vstart <= 64'b0;
            end
            //  Every other completed vector instruction zeroes vstart too
            //  (RVV 3.7). Cannot coincide with an explicit CSR write or a
            //  vset*: single-issue means CSR ops never issue while a vector
            //  FU is active, so ordering against those cases is moot.
            if (v_retire) csr_vstart <= 64'b0;
            //  fault-only-first trim: a vle*ff/vlseg*ff that faulted past
            //  element 0 reduces vl (RVV 7.7); vtype is untouched and vstart
            //  is cleared by the op's normal completion (v_retire above).
            if (vl_trim_req) csr_vl <= vl_trim_val;
            //  conservative Dirty-setting: any permitted FP/vector op or
            //  FP/vector CSR access marks the context Dirty (spec-legal
            //  over-approximation; the trap-on-Off gate lives in karu64).
            //  Cannot coincide with an mstatus/sstatus CSR write: that IS
            //  a CSR op, and a CSR op pulses fp/v_dirty only when it
            //  addresses an FP/vector CSR.
`ifdef KARU_EN_F
            if (fp_dirty) csr_mstatus[14:13] <= 2'b11;
`endif
`ifdef KARU_EN_V
            if (v_dirty)  csr_mstatus[10:9]  <= 2'b11;
`endif
            if (mret_req) begin
`ifdef KARU_EN_S
                priv <= csr_mstatus[12:11];
`else
                priv <= (csr_mstatus[12:11] == PRIV_U) ? PRIV_U : PRIV_M;
`endif
                csr_mstatus[3] <= csr_mstatus[7];   //  MIE <- MPIE
                csr_mstatus[7] <= 1'b1;             //  MPIE <- 1
                csr_mstatus[12:11] <= PRIV_U;       //  MPP <- U
                if (csr_mstatus[12:11] != PRIV_M)   //  returning below M -> clear MPRV
                    csr_mstatus[17] <= 1'b0;
            end
`ifdef KARU_EN_S
            if (sret_req) begin
                priv <= csr_mstatus[8] ? PRIV_S : PRIV_U;
                csr_mstatus[1] <= csr_mstatus[5];   //  SIE <- SPIE
                csr_mstatus[5] <= 1'b1;             //  SPIE <- 1
                csr_mstatus[8] <= 1'b0;             //  SPP <- U
                csr_mstatus[17] <= 1'b0;            //  returns to S/U -> clear MPRV
            end
`endif
`ifdef KARU_IRQ_TRACE
            if (trap_req)
                $display("[IRQ] t=%0d %0s cause=%h epc=%h priv %0d->%0d (mip=%h mie=%h mideleg=%h)",
                    cyc_in, trap_cause[63] ? "INT" : "EXC", trap_cause, trap_epc,
                    priv, trap_deleg ? 1 : 3, mip_v, csr_mie, csr_mideleg);
            if (mret_req)
                $display("[IRQ] t=%0d MRET -> priv %0d (mstatus=%h)",
                    cyc_in, csr_mstatus[12:11], csr_mstatus);
            if (sret_req)
                $display("[IRQ] t=%0d SRET -> priv %0d", cyc_in, csr_mstatus[8] ? 1 : 0);
            if (csr_w_fire && op_addr == 12'h344)
                $display("[IRQ] t=%0d mip<=%h (was %h, mie=%h mideleg=%h)",
                    cyc_in, new_v_w & ~MIP_HW, mip_v, csr_mie, csr_mideleg);
            if (csr_w_fire && op_addr == 12'h304)
                $display("[IRQ] t=%0d mie<=%h", cyc_in, new_v_w);
            if (csr_w_fire && op_addr == 12'h104)
                $display("[IRQ] t=%0d sie<=%h", cyc_in, new_v_w & csr_mideleg);
`endif
        end
    end

    assign op_rd_v  = rd_v_w;
    //  tvec[1:0] = mode: 0 direct (all traps -> BASE), 1 vectored (interrupts ->
    //  BASE + 4*cause, exceptions -> BASE). BASE is the tvec value with the mode
    //  bits masked off.
`ifdef KARU_EN_S
    wire [63:0] tvec_sel  = trap_deleg ? csr_stvec : csr_mtvec;
`else
    wire [63:0] tvec_sel  = csr_mtvec;
`endif
    wire [63:0] tvec_base = {tvec_sel[63:2], 2'b00};
    assign trap_vec = (tvec_sel[0] && trap_cause[63])
                    ? tvec_base + {56'b0, trap_cause[5:0], 2'b00}
                    : tvec_base;
`ifdef KARU_EN_S
    assign ret_pc   = sret_req ? csr_sepc : csr_mepc;
`else
    assign ret_pc   = csr_mepc;
`endif

endmodule

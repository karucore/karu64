// Scalar LSU AXI write-channel independence (review finding S7).
// In KARU_NO_MEM builds karu_lsu drives the dmem AXI write channels
// directly, so it must accept AW and W in either order or the same cycle.
// Every write state is exercised: S_AWW (aligned, IO-native and SC
// stores), S_AWW2 (second beat of a split store), S_AMO_B (AMO write) and
// S_CBOZ_W (eight CBO.ZERO beats). They run against a legal AXI4 subordinate
// in four orders: joint (same cycle), AW-first with W lagging 1..LAG_MAX
// cycles, W-first with AW lagging 1..LAG_MAX cycles, and seeded random
// independent AW/W/AR/R/B stalls. B follows only after both AW and W.
// For each access the bench checks one AW, one W and one B handshake per
// expected beat, the beat address, size, attributes, data and strobe,
// completion within DONE_BOUND cycles, VALID/payload stability under
// backpressure, the memory image, the result value, and that no VALID or
// further activity remains after done. Pass marker: LSU_AW_W_PASS. Any
// failure is a $fatal whose text starts with LSU_AW_W_FAIL. In random mode
// the "lag" field of a failure message is the seed index.
`timescale 1ns/1ps
`include "karu_axi_defs.vh"
`include "karu_uop_defs.vh"

module tb_lsu_aw_w #(parameter NONSECURE=1);
    localparam integer LAG_MAX = 4;
    localparam integer RAND_SEEDS = 8;
    localparam integer DONE_BOUND = 300;
    localparam integer M_JOINT = 0, M_AW_FIRST = 1, M_W_FIRST = 2, M_RANDOM = 3;

    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg req=0, is_store=0;
    reg [1:0] access_priv=3;
`ifdef KARU_DBG
    wire debug_mode_i=0, debug_clear_reservation_i=0;
`endif
    reg [4:0] sub_in=`LSU_LOAD;
    reg [63:0] addr=0, addr2=0, wdata=0;
    reg [1:0] pbmt=0, pbmt2=0, size=`LS_D;
    reg sign_l=1;
    wire busy, done, fault, fault_second;
    wire [63:0] rd_v;
    wire [1:0] ar_pbmt, aw_pbmt;
    wire [`AXI_ID_W-1:0] arid, awid;
    wire [`AXI_ADDR_W-1:0] araddr, awaddr;
    wire [`AXI_LEN_W-1:0] arlen, awlen;
    wire [`AXI_SIZE_W-1:0] arsize, awsize;
    wire [`AXI_BURST_W-1:0] arburst, awburst;
    wire [`AXI_PROT_W-1:0] arprot, awprot;
    wire arvalid, arready, rready, awvalid, awready;
    wire [63:0] wdata_o;
    wire [7:0] wstrb;
    wire wlast, wvalid, wready, bready;
    reg [`AXI_ID_W-1:0] rid=0, bid=0;
    reg [63:0] rdata=0;
    reg [1:0] rresp=0, bresp=0;
    reg rlast=1, rvalid=0, bvalid=0;
    karu_lsu #(.NONSECURE(NONSECURE)) dut(.*);

    // ---- run context ----
    integer mode=M_JOINT, lag=1, seed=1, access_no=0, cycle=0;
    reg [8*9:1] mode_name="joint";

    // ---- memory model: 4 KiB of RAM at 0x8000_0000, indexed by addr[11:0] ----
    localparam integer RAM_BYTES=4096;
    reg [7:0] ram[0:RAM_BYTES-1], expected[0:RAM_BYTES-1];

    // ---- expected write beats of the active access ----
    reg active=0;
    integer exp_n=0, aw_k=0, w_k=0, b_k=0, ar_k=0;
    reg [31:0] exp_awaddr[0:7];
    reg [2:0] exp_awsize[0:7];
    reg [1:0] exp_pbmt[0:7];
    reg [7:0] exp_strb[0:7];
    reg [63:0] exp_data[0:7];
    reg [2:0] exp_prot;

    // ---- legal AXI4 subordinate: one outstanding read and one write ----
    reg aw_got=0, w_got=0, b_wait=0, r_wait=0;
    integer lag_cnt=0, bdelay=0, rdelay=0;
    reg [31:0] got_awaddr, rd_addr;
    reg [7:0] got_wstrb;
    reg [63:0] got_wdata;
    reg rnd_aw=1, rnd_w=1, rnd_ar=1;
    integer rnd;
    wire wr_free = !b_wait && !bvalid;
    assign awready = wr_free && !aw_got && (
        mode==M_JOINT    ? (awvalid && wvalid && !w_got) :
        mode==M_AW_FIRST ? !w_got :
        mode==M_W_FIRST  ? (w_got && lag_cnt==0) : rnd_aw);
    assign wready = wr_free && !w_got && (
        mode==M_JOINT    ? (awvalid && wvalid && !aw_got) :
        mode==M_AW_FIRST ? (aw_got && lag_cnt==0) :
        mode==M_W_FIRST  ? !aw_got : rnd_w);
    assign arready = !r_wait && !rvalid && (mode!=M_RANDOM || rnd_ar);

    // ---- handshake bookkeeping ----
    integer aws=0, ws=0, bs=0, ars=0;
    integer n_joint=0, n_aw_first=0, n_w_first=0, aw_stall=0, w_stall=0;
    reg aw_wait=0, w_wait=0, ar_wait=0;
    reg [54:0] held_aw, held_ar;
    reg [72:0] held_w;
    wire aw_hs = awvalid && awready;
    wire w_hs = wvalid && wready;
    wire [54:0] aw_payload = {awid,awaddr,aw_pbmt,awlen,awsize,awburst,awprot};
    wire [54:0] ar_payload = {arid,araddr,ar_pbmt,arlen,arsize,arburst,arprot};
    wire [72:0] w_payload = {wdata_o,wstrb,wlast};

    function automatic [63:0] lane_mask(input [7:0] strb);
        for (integer i=0; i<8; i=i+1) lane_mask[i*8+:8] = {8{strb[i]}};
    endfunction

    always @(posedge clk) if (!rst) begin
        cycle <= cycle+1;
        if (mode==M_RANDOM) begin
            rnd = $random(seed);
            rnd_aw <= rnd[0]; rnd_w <= rnd[1]; rnd_ar <= rnd[2] | rnd[3];
        end
        // VALID and payload must hold while the subordinate stalls them.
        if (aw_wait && (!awvalid || aw_payload !== held_aw))
            $fatal(1,"LSU_AW_W_FAIL AW changed while stalled mode=%0s lag=%0d access=%0d",mode_name,lag,access_no);
        if (w_wait && (!wvalid || w_payload !== held_w))
            $fatal(1,"LSU_AW_W_FAIL W changed while stalled mode=%0s lag=%0d access=%0d",mode_name,lag,access_no);
        if (ar_wait && (!arvalid || ar_payload !== held_ar))
            $fatal(1,"LSU_AW_W_FAIL AR changed while stalled mode=%0s lag=%0d access=%0d",mode_name,lag,access_no);
        aw_wait <= awvalid && !awready; held_aw <= aw_payload;
        w_wait <= wvalid && !wready; held_w <= w_payload;
        ar_wait <= arvalid && !arready; held_ar <= ar_payload;
        if (awvalid && !awready) aw_stall <= aw_stall+1;
        if (wvalid && !wready) w_stall <= w_stall+1;

        if (lag_cnt != 0) lag_cnt <= lag_cnt-1;
        if (aw_hs) begin
            if (!active || aw_k >= exp_n)
                $fatal(1,"LSU_AW_W_FAIL extra AW handshake beat=%0d expected=%0d addr=%h mode=%0s lag=%0d access=%0d",
                    aw_k,exp_n,awaddr,mode_name,lag,access_no);
            if (awaddr !== exp_awaddr[aw_k] || awsize !== exp_awsize[aw_k] ||
                aw_pbmt !== exp_pbmt[aw_k] || awlen !== 0 || awburst !== `AXI_BURST_INCR ||
                awprot !== exp_prot || awid !== 0)
                $fatal(1,"LSU_AW_W_FAIL AW payload beat=%0d addr=%h/%h size=%0d/%0d pbmt=%0d/%0d prot=%0d/%0d mode=%0s lag=%0d access=%0d",
                    aw_k,awaddr,exp_awaddr[aw_k],awsize,exp_awsize[aw_k],aw_pbmt,exp_pbmt[aw_k],
                    awprot,exp_prot,mode_name,lag,access_no);
            aw_k <= aw_k+1; aws <= aws+1;
            aw_got <= 1; got_awaddr <= awaddr; bid <= awid;
            if (mode==M_AW_FIRST) lag_cnt <= lag-1;
        end
        if (w_hs) begin
            if (!active || w_k >= exp_n)
                $fatal(1,"LSU_AW_W_FAIL extra W handshake beat=%0d expected=%0d mode=%0s lag=%0d access=%0d",
                    w_k,exp_n,mode_name,lag,access_no);
            if (wstrb !== exp_strb[w_k] || wlast !== 1 ||
                (wdata_o & lane_mask(wstrb)) !== (exp_data[w_k] & lane_mask(exp_strb[w_k])))
                $fatal(1,"LSU_AW_W_FAIL W payload beat=%0d data=%h/%h strb=%h/%h last=%b mode=%0s lag=%0d access=%0d",
                    w_k,wdata_o,exp_data[w_k],wstrb,exp_strb[w_k],wlast,mode_name,lag,access_no);
            w_k <= w_k+1; ws <= ws+1;
            w_got <= 1; got_wdata <= wdata_o; got_wstrb <= wstrb;
            if (mode==M_W_FIRST) lag_cnt <= lag-1;
        end
        if (aw_hs && w_hs) n_joint <= n_joint+1;
        else if (aw_hs && w_got) n_w_first <= n_w_first+1;
        else if (w_hs && aw_got) n_aw_first <= n_aw_first+1;

        // B only after both requests of the transaction were accepted.
        if (aw_got && w_got && !b_wait && !bvalid) begin
            for (integer lane=0; lane<8; lane=lane+1)
                if (got_wstrb[lane]) ram[(got_awaddr & 32'hff8) + lane] = got_wdata[lane*8+:8];
            b_wait <= 1;
            bdelay <= mode==M_RANDOM ? (rnd >>> 4) & 3 : 0;
        end
        if (b_wait) begin
            if (bdelay != 0) bdelay <= bdelay-1;
            else begin bvalid <= 1; b_wait <= 0; end
        end
        if (bvalid && bready) begin
            if (!active || b_k >= exp_n)
                $fatal(1,"LSU_AW_W_FAIL extra B handshake beat=%0d expected=%0d mode=%0s lag=%0d access=%0d",
                    b_k,exp_n,mode_name,lag,access_no);
            bvalid <= 0; aw_got <= 0; w_got <= 0;
            b_k <= b_k+1; bs <= bs+1;
        end

        // Reads (LR and the AMO read phase).
        if (arvalid && arready) begin
            if (!active || ar_k != 0)
                $fatal(1,"LSU_AW_W_FAIL unexpected AR addr=%h mode=%0s lag=%0d access=%0d",araddr,mode_name,lag,access_no);
            ar_k <= ar_k+1; ars <= ars+1;
            r_wait <= 1; rd_addr <= araddr; rid <= arid;
            rdelay <= mode==M_RANDOM ? (rnd >>> 6) & 3 : 1;
        end
        if (r_wait) begin
            if (rdelay != 0) rdelay <= rdelay-1;
            else begin
                for (integer lane=0; lane<8; lane=lane+1)
                    rdata[lane*8+:8] <= ram[(rd_addr & 32'hff8) + lane];
                rvalid <= 1; r_wait <= 0;
            end
        end
        if (rvalid && rready) rvalid <= 0;
    end

    function automatic [63:0] amo_value(input [4:0] op, input [63:0] lhs, rhs);
        case (op)
            `LSU_AMOSWAP: amo_value=rhs;
            `LSU_AMOADD: amo_value=lhs+rhs;
            `LSU_AMOXOR: amo_value=lhs^rhs;
            `LSU_AMOAND: amo_value=lhs&rhs;
            `LSU_AMOOR: amo_value=lhs|rhs;
            `LSU_AMOMIN: amo_value=$signed(lhs)<$signed(rhs) ? lhs : rhs;
            `LSU_AMOMAX: amo_value=$signed(lhs)>$signed(rhs) ? lhs : rhs;
            `LSU_AMOMINU: amo_value=lhs<rhs ? lhs : rhs;
            `LSU_AMOMAXU: amo_value=lhs>rhs ? lhs : rhs;
            default: amo_value=0;
        endcase
    endfunction

    task automatic seed_ram(input integer pattern);
        for (integer i=0; i<RAM_BYTES; i=i+1) begin
            ram[i]=8'((i*73+pattern*29)^32'h5a);
            expected[i]=ram[i];
        end
    endtask

    task automatic set_beat(input integer k, input [31:0] a, input [2:0] sz,
        input [1:0] attr, input [7:0] strb, input [63:0] data);
        exp_awaddr[k]=a; exp_awsize[k]=sz; exp_pbmt[k]=attr;
        exp_strb[k]=strb; exp_data[k]=data;
    endtask

    // One LSU request. Builds the expected beats and memory image, issues
    // the request, waits for done and checks counts, data and quiescence.
    task automatic access(input [4:0] op, input [1:0] width, input [63:0] address,
        input [63:0] address2, input [1:0] attr, input [1:0] attr2, input [63:0] value);
        reg [63:0] old_value, operand, new_value, expected_rd, beat_data;
        reg [7:0] beat_strb;
        reg want_read, got_done;
        integer bytes, off, lo_bytes, index, index2, waits;
        begin
            @(negedge clk);
            if (busy || done || fault || active) $fatal(1,"LSU_AW_W_FAIL overlapping requests");
            access_no=access_no+1;
            access_priv = access_no%3 == 0 ? 2'd0 : (access_no%3 == 1 ? 2'd1 : 2'd3);
            exp_prot = {1'b0, (NONSECURE != 0), (access_priv != 0)};
            bytes=1<<width; off=int'(address[2:0]); lo_bytes=8-off;
            index=int'(address[11:0]); index2=int'(address2[11:0] & 12'hff8);
            old_value=0;
            for (integer i=0; i<bytes; i=i+1) old_value[i*8+:8]=expected[index+i];
            operand=value;
            if (width==`LS_W) begin
                old_value={{32{old_value[31]}},old_value[31:0]};
                operand={{32{value[31]}},value[31:0]};
            end
            expected_rd=old_value;
            want_read = op==`LSU_LR || (op>=`LSU_AMOSWAP && op<=`LSU_AMOMAXU);
            exp_n=0;
            if (op==`LSU_STORE || op==`LSU_SC) begin
                if (op==`LSU_SC) expected_rd=0;
                beat_strb=8'(((1<<bytes)-1)<<off);
                beat_data=value<<(off*8);
                if (attr==2) begin
                    set_beat(0,address[31:0],{1'b0,width},attr,beat_strb,beat_data);
                    exp_n=1;
                end else begin
                    set_beat(0,{address[31:3],3'b0},`AXI_SIZE_8B,attr,beat_strb,beat_data);
                    exp_n=1;
                    if (off+bytes > 8) begin
                        set_beat(1,{address2[31:3],3'b0},`AXI_SIZE_8B,attr2,
                            8'(((1<<bytes)-1)>>lo_bytes),value>>(lo_bytes*8));
                        exp_n=2;
                    end
                end
                for (integer i=0; i<bytes; i=i+1)
                    if (i<lo_bytes) expected[index+i]=value[i*8+:8];
                    else expected[index2+i-lo_bytes]=value[i*8+:8];
            end else if (op>=`LSU_AMOSWAP && op<=`LSU_AMOMAXU) begin
                new_value=amo_value(op,old_value,operand);
                if (width==`LS_W)
                    set_beat(0,{address[31:3],3'b0},`AXI_SIZE_8B,attr,
                        address[2] ? 8'hf0 : 8'h0f,{2{new_value[31:0]}});
                else
                    set_beat(0,{address[31:3],3'b0},`AXI_SIZE_8B,attr,8'hff,new_value);
                exp_n=1;
                for (integer i=0; i<bytes; i=i+1) expected[index+i]=new_value[i*8+:8];
            end else if (op==`LSU_CBOZERO) begin
                for (integer k=0; k<8; k=k+1)
                    set_beat(k,{address[31:6],6'b0}+32'(k*8),`AXI_SIZE_8B,0,8'hff,64'b0);
                exp_n=8;
                for (integer i=0; i<64; i=i+1) expected[(index & 12'hfc0)+i]=0;
            end
            aw_k=0; w_k=0; b_k=0; ar_k=0;
            active=1;
            req=1; sub_in=op; is_store=(op==`LSU_STORE); addr=address; addr2=address2;
            pbmt=attr; pbmt2=attr2; wdata=value; size=width; sign_l=1;
            @(negedge clk); req=0; access_priv=~access_priv;
            waits=0; got_done=done;
            while (!got_done && !fault && waits<DONE_BOUND) begin
                @(posedge clk); #1;
                got_done=done;
                if (got_done && b_k != exp_n)
                    $fatal(1,"LSU_AW_W_FAIL done before final B B=%0d expected=%0d mode=%0s lag=%0d access=%0d",
                        b_k,exp_n,mode_name,lag,access_no);
                waits=waits+1;
            end
            if (fault) $fatal(1,"LSU_AW_W_FAIL unexpected fault mode=%0s lag=%0d access=%0d",mode_name,lag,access_no);
            if (!got_done)
                $fatal(1,"LSU_AW_W_FAIL no done within %0d cycles AW=%0d W=%0d B=%0d expected=%0d awvalid=%b wvalid=%b mode=%0s lag=%0d access=%0d",
                    DONE_BOUND,aw_k,w_k,b_k,exp_n,awvalid,wvalid,mode_name,lag,access_no);
            if (aw_k != exp_n || w_k != exp_n || b_k != exp_n || ar_k != int'(want_read))
                $fatal(1,"LSU_AW_W_FAIL handshake count AW=%0d W=%0d B=%0d AR=%0d expected=%0d/%0d mode=%0s lag=%0d access=%0d",
                    aw_k,w_k,b_k,ar_k,exp_n,want_read,mode_name,lag,access_no);
            if (op!=`LSU_STORE && op!=`LSU_CBOZERO && rd_v !== expected_rd)
                $fatal(1,"LSU_AW_W_FAIL result rd=%h expected=%h mode=%0s lag=%0d access=%0d",
                    rd_v,expected_rd,mode_name,lag,access_no);
            for (integer i=0; i<RAM_BYTES; i=i+1)
                if (ram[i] !== expected[i])
                    $fatal(1,"LSU_AW_W_FAIL memory offset=%h got=%h expected=%h mode=%0s lag=%0d access=%0d",
                        i,ram[i],expected[i],mode_name,lag,access_no);
            // Nothing may remain asserted or happen after completion.
            repeat (3) begin
                @(posedge clk); #1;
                if (done || fault || busy || arvalid || awvalid || wvalid)
                    $fatal(1,"LSU_AW_W_FAIL VALID or activity after done busy=%b arvalid=%b awvalid=%b wvalid=%b mode=%0s lag=%0d access=%0d",
                        busy,arvalid,awvalid,wvalid,mode_name,lag,access_no);
            end
            if (aw_got || w_got || b_wait || bvalid)
                $fatal(1,"LSU_AW_W_FAIL write left open after done mode=%0s lag=%0d access=%0d",mode_name,lag,access_no);
            active=0;
        end
    endtask

    // The access list covers every LSU write state. Addresses are RAM PAs.
    task automatic run_sequence(input integer pattern);
        begin
            seed_ram(pattern);
            // S_AWW: aligned SD, upper-word SW, SB, IO-native SH (PBMT=IO)
            access(`LSU_STORE,`LS_D,64'h80000100,64'h80000108,0,0,64'h1122334455667788);
            access(`LSU_STORE,`LS_W,64'h80000104,64'h80000108,0,0,64'h00000000a5b6c7d8);
            access(`LSU_STORE,`LS_B,64'h80000107,64'h80000108,1,1,64'h00000000000000e1);
            access(`LSU_STORE,`LS_H,64'h80000122,64'h80000128,2,2,64'h000000000000beef);
            // S_AWW + S_AWW2: split SD inside a page; split SW whose second
            // beat goes to a separately translated page (addr2 != addr+8)
            access(`LSU_STORE,`LS_D,64'h80000203,64'h80000208,0,0,64'h0102030405060708);
            access(`LSU_STORE,`LS_W,64'h80000ffe,64'h80000400,0,1,64'h00000000cafef00d);
            // S_AWW via a successful SC after LR
            access(`LSU_LR,`LS_D,64'h80000300,64'h80000308,0,0,0);
            access(`LSU_SC,`LS_D,64'h80000300,64'h80000308,0,0,64'hdeadbeef00c0ffee);
            // S_AMO_B
            access(`LSU_AMOADD,`LS_D,64'h80000310,64'h80000318,0,0,64'h0000000100000001);
            access(`LSU_AMOSWAP,`LS_W,64'h80000314,64'h80000318,0,0,64'h0000000087654321);
            access(`LSU_AMOMAXU,`LS_W,64'h80000318,64'h80000320,1,1,64'h00000000fffffff0);
            // S_CBOZ_W: eight beats over the 64-byte block 0x8000_0340
            access(`LSU_CBOZERO,`LS_D,64'h80000345,64'h80000348,0,0,0);
        end
    endtask

    // +modes=<mask> selects orders for negative controls: 1 joint,
    // 2 AW-first, 4 W-first, 8 random (default 15, all).
    integer modes, i_lag, i_seed, base_joint, base_awf, base_wf;
    initial begin
        if (!$value$plusargs("modes=%d", modes)) modes=15;
        if (modes < 1 || modes > 15) $fatal(1,"LSU_AW_W_FAIL bad +modes=%0d",modes);
        repeat (3) @(negedge clk);
        rst=0;
        if (modes & 1) begin
            mode=M_JOINT; mode_name="joint"; lag=0;
            base_joint=n_joint; base_awf=n_aw_first; base_wf=n_w_first;
            run_sequence(0);
            @(negedge clk);
            if (n_joint==base_joint || n_aw_first!=base_awf || n_w_first!=base_wf)
                $fatal(1,"LSU_AW_W_FAIL joint mode coverage joint=%0d aw_first=%0d w_first=%0d",
                    n_joint-base_joint,n_aw_first-base_awf,n_w_first-base_wf);
        end
        for (i_lag=1; i_lag<=LAG_MAX; i_lag=i_lag+1) begin
            if (modes & 2) begin
                mode=M_AW_FIRST; mode_name="aw_first"; lag=i_lag;
                base_joint=n_joint; base_awf=n_aw_first; base_wf=n_w_first;
                run_sequence(i_lag);
                @(negedge clk);
                if (n_aw_first==base_awf || n_joint!=base_joint || n_w_first!=base_wf)
                    $fatal(1,"LSU_AW_W_FAIL aw_first mode coverage lag=%0d",i_lag);
            end
            if (modes & 4) begin
                mode=M_W_FIRST; mode_name="w_first"; lag=i_lag;
                base_joint=n_joint; base_awf=n_aw_first; base_wf=n_w_first;
                run_sequence(i_lag+8);
                @(negedge clk);
                if (n_w_first==base_wf || n_joint!=base_joint || n_aw_first!=base_awf)
                    $fatal(1,"LSU_AW_W_FAIL w_first mode coverage lag=%0d",i_lag);
            end
        end
        if (modes & 8) begin
            base_joint=n_joint; base_awf=n_aw_first; base_wf=n_w_first;
            for (i_seed=1; i_seed<=RAND_SEEDS; i_seed=i_seed+1) begin
                mode=M_RANDOM; mode_name="random"; lag=i_seed; seed=i_seed*7919;
                run_sequence(i_seed+16);
            end
            @(negedge clk);
            if (n_joint==base_joint || n_aw_first==base_awf || n_w_first==base_wf ||
                aw_stall==0 || w_stall==0)
                $fatal(1,"LSU_AW_W_FAIL random mode coverage joint=%0d aw_first=%0d w_first=%0d",
                    n_joint-base_joint,n_aw_first-base_awf,n_w_first-base_wf);
        end
        $display("LSU_AW_W_PASS modes=%0d accesses=%0d AW=%0d W=%0d B=%0d AR=%0d joint=%0d aw_first=%0d w_first=%0d aw_stall=%0d w_stall=%0d",
            modes,access_no,aws,ws,bs,ars,n_joint,n_aw_first,n_w_first,aw_stall,w_stall);
        $finish;
    end
    initial begin #20000000; $fatal(1,"LSU_AW_W_FAIL watchdog"); end
endmodule

// LSU atomic access contract: natural alignment, physical-device exclusion,
// PBMT aliases, exact word lanes, and reservation consumption on rejection.
// The internal LSU/karu_mem interface accepts AW+W together; AR, R and B
// delays vary independently. +only_misaligned / +only_device isolate the
// two pre-issue rejection rules for negative controls against older RTL.
`timescale 1ns/1ps
`include "karu_axi_defs.vh"
`include "karu_uop_defs.vh"

module tb_lsu_atomic;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg req=0, is_store=0;
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
    karu_lsu dut(.*);

    localparam [63:0] RAM=64'h80000120, RESERVE=64'h80000300;
    localparam integer RAM_BYTES=1024;
    reg [7:0] ram[0:RAM_BYTES-1], expected[0:RAM_BYTES-1];
    integer cycle=0, stall=0, rdelay=0, bdelay=0;
    integer ars=0, aws=0, ws=0, bs=0, checks=0, rejected=0;
    reg read_pending=0, write_pending=0;
    reg [31:0] read_address;
    reg active=0, expect_reject=0;
    reg [63:0] active_addr;
    reg [1:0] active_pbmt, active_size;
    reg [4:0] active_op;
    reg [7:0] active_strobe;
    reg [63:0] hold_rd;
    reg ar_wait=0, aww_wait=0;
    reg [53:0] held_ar;
    reg [126:0] held_aww;
    integer ar_stalls=0, aw_stalls=0;
    assign arready = !read_pending && !rvalid && (stall==0 || cycle%5==2);
    assign awready = !write_pending && !bvalid && (stall==0 || cycle%7==3);
    assign wready = awready;

    always @(posedge clk) if (!rst) begin
        cycle <= cycle+1;
        if (ar_wait && (!arvalid ||
            {arid,araddr,ar_pbmt,arlen,arsize,arburst,arprot} !== held_ar))
            $fatal(1,"AR changed while stalled check=%0d",checks);
        if (aww_wait && (!awvalid || !wvalid ||
            {awid,awaddr,aw_pbmt,awlen,awsize,awburst,awprot,wdata_o,wstrb,wlast} !== held_aww))
            $fatal(1,"AW/W changed while stalled check=%0d",checks);
        ar_wait <= arvalid && !arready;
        aww_wait <= awvalid && wvalid && !awready;
        held_ar <= {arid,araddr,ar_pbmt,arlen,arsize,arburst,arprot};
        held_aww <= {awid,awaddr,aw_pbmt,awlen,awsize,awburst,awprot,wdata_o,wstrb,wlast};
        if (arvalid && !arready) ar_stalls <= ar_stalls+1;
        if (awvalid && !awready) aw_stalls <= aw_stalls+1;
        if (active && expect_reject && (arvalid || awvalid || wvalid))
            $fatal(1,"ATOMIC_REJECT_BUS check=%0d op=%0d size=%0d addr=%h pbmt=%0d",
                checks,active_op,active_size,active_addr,active_pbmt);
        if (arvalid && arready) begin
            if (!active || araddr !== active_addr[31:0] || ar_pbmt !== active_pbmt ||
                arlen !== 0 || arsize !== (active_pbmt==2 ? {1'b0,active_size} : 3'd3) ||
                arburst !== `AXI_BURST_INCR)
                $fatal(1,"AR geometry check=%0d addr=%h size=%0d pbmt=%0d",checks,araddr,arsize,ar_pbmt);
            ars <= ars+1;
            read_pending <= 1;
            read_address <= araddr;
            rid <= arid;
            rdelay <= stall!=0 ? 4 : 0;
        end
        if (read_pending) begin
            if (rdelay != 0) rdelay <= rdelay-1;
            else begin
                for (integer lane=0; lane<8; lane=lane+1)
                    rdata[lane*8+:8] <= ram[((read_address & 32'h3f8)+lane)];
                rvalid <= 1;
                read_pending <= 0;
            end
        end
        if (rvalid && rready) rvalid <= 0;
        if (awvalid && awready && wvalid && wready) begin
            if (!active || awaddr !== (active_pbmt==2 ? active_addr[31:0] :
                    {active_addr[31:3],3'b0}) || aw_pbmt !== active_pbmt ||
                awlen !== 0 || awsize !== (active_pbmt==2 ? {1'b0,active_size} : 3'd3) ||
                awburst !== `AXI_BURST_INCR || wstrb !== active_strobe || wlast !== 1)
                $fatal(1,"AW/W geometry check=%0d addr=%h size=%0d strb=%h expected=%h",
                    checks,awaddr,awsize,wstrb,active_strobe);
            for (integer lane=0; lane<8; lane=lane+1)
                if (wstrb[lane]) ram[((awaddr & 32'h3f8)+lane)] <= wdata_o[lane*8+:8];
            aws <= aws+1; ws <= ws+1;
            bid <= awid;
            write_pending <= 1;
            bdelay <= stall!=0 ? 6 : 0;
        end
        if (write_pending) begin
            if (bdelay != 0) bdelay <= bdelay-1;
            else begin bvalid <= 1; write_pending <= 0; end
        end
        if (bvalid && bready) begin bvalid <= 0; bs <= bs+1; end
    end

    function automatic [63:0] amo_value(input [4:0] op, input [63:0] lhs, rhs);
        begin
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
        end
    endfunction

    task automatic seed(input integer pattern);
        reg [63:0] value;
        begin
            if (busy || read_pending || write_pending || rvalid || bvalid)
                $fatal(1,"seed while busy");
            for (integer i=0; i<RAM_BYTES; i=i+1) begin
                ram[i]=8'((i*73+pattern*11)^32'ha5);
                expected[i]=ram[i];
            end
            value=pattern!=0 ? 64'h0123456712345678 : 64'h81234567fedcba98;
            for (integer i=0; i<8; i=i+1) begin
                ram[int'(RAM[9:0])+i]=value[i*8+:8];
                expected[int'(RAM[9:0])+i]=value[i*8+:8];
            end
        end
    endtask

    task automatic access(input [4:0] op, input [1:0] width,
        input [63:0] address, input [1:0] attr, input [63:0] value,
        input reject_access, input sc_success);
        reg [63:0] old_value, operand, new_value, expected_rd;
        reg have_completion, got_fault, got_done, want_read, want_write;
        integer before_ar, before_aw, before_w, before_b;
        integer bytes, index, waits;
        begin
            @(negedge clk);
            if (busy || done || fault || active) $fatal(1,"overlapping test requests");
            checks=checks+1;
            bytes=1<<width;
            index=int'(address[9:0]);
            old_value=0;
            for (integer i=0; i<bytes; i=i+1) old_value[i*8+:8]=expected[index+i];
            operand=value;
            if (width==`LS_W) begin
                old_value={{32{old_value[31]}},old_value[31:0]};
                operand={{32{value[31]}},value[31:0]};
            end
            expected_rd=old_value;
            if (op==`LSU_SC) expected_rd=sc_success ? 0 : 1;
            want_read=!reject_access && (op==`LSU_LOAD || op==`LSU_LR ||
                (op>=`LSU_AMOSWAP && op<=`LSU_AMOMAXU));
            want_write=!reject_access && (op==`LSU_STORE || (op==`LSU_SC && sc_success) ||
                (op>=`LSU_AMOSWAP && op<=`LSU_AMOMAXU));
            new_value=value;
            if (op>=`LSU_AMOSWAP && op<=`LSU_AMOMAXU)
                new_value=amo_value(op,old_value,operand);
            if (want_write)
                for (integer i=0; i<bytes; i=i+1) expected[index+i]=new_value[i*8+:8];
            before_ar=ars; before_aw=aws; before_w=ws; before_b=bs;
            active=1; expect_reject=reject_access;
            active_addr=address; active_pbmt=attr; active_size=width; active_op=op;
            active_strobe=8'(((1<<bytes)-1)<<address[2:0]);
            hold_rd=rd_v;
            req=1; sub_in=op; is_store=(op==`LSU_STORE); addr=address;
            addr2=(address&~64'd7)+8; pbmt=attr; pbmt2=attr;
            wdata=value; size=width; sign_l=1;
            @(posedge clk); #1;
            have_completion=done || fault; got_fault=fault; got_done=done;
            if (reject_access && (arvalid || awvalid || wvalid))
                $fatal(1,"ATOMIC_REJECT_BUS check=%0d op=%0d size=%0d addr=%h pbmt=%0d",
                    checks,op,width,address,attr);
            @(negedge clk); req=0;
            waits=0;
            while (!have_completion && waits<200) begin
                @(posedge clk); #1;
                have_completion=done || fault; got_fault=fault; got_done=done;
                waits=waits+1;
            end
            if (!have_completion || got_fault !== reject_access || got_done === reject_access)
                $fatal(1,"completion check=%0d op=%0d size=%0d addr=%h fault=%b done=%b reject=%b",
                    checks,op,width,address,got_fault,got_done,reject_access);
            if (reject_access) begin
                rejected=rejected+1;
                if (fault_second !== 0 || rd_v !== hold_rd)
                    $fatal(1,"rejection changed result/second flag check=%0d rd=%h old=%h second=%b",
                        checks,rd_v,hold_rd,fault_second);
            end else if (op!=`LSU_STORE && rd_v !== expected_rd)
                $fatal(1,"result check=%0d op=%0d addr=%h got=%h expected=%h",
                    checks,op,address,rd_v,expected_rd);
            if (ars-before_ar!=int'(want_read) || aws-before_aw!=int'(want_write) ||
                ws-before_w!=int'(want_write) || bs-before_b!=int'(want_write))
                $fatal(1,"bus count check=%0d AR=%0d AW=%0d W=%0d B=%0d wanted=%0d/%0d",
                    checks,ars-before_ar,aws-before_aw,ws-before_w,bs-before_b,want_read,want_write);
            for (integer i=0; i<RAM_BYTES; i=i+1)
                if (ram[i] !== expected[i])
                    $fatal(1,"byte canary check=%0d offset=%0d got=%h expected=%h",checks,i,ram[i],expected[i]);
            repeat (2) begin
                @(posedge clk); #1;
                if (done || fault || busy || arvalid || awvalid || wvalid)
                    $fatal(1,"late completion/activity check=%0d",checks);
            end
            active=0; expect_reject=0;
        end
    endtask

    task automatic reject_and_consume(input [4:0] op, input [1:0] width,
        input [63:0] address, input [1:0] attr);
        begin
            access(`LSU_LR,`LS_D,RESERVE,0,0,0,0);
            access(op,width,address,attr,64'h0123456789abcdef,1,0);
            // A rejected LR/SC/AMO must not leave an earlier reservation live.
            access(`LSU_SC,`LS_D,RESERVE,0,64'hbad0bad0bad0bad0,0,0);
        end
    endtask

    integer op_i, width_i, offset_i, attr_i, device_i, pattern_i, alias_i;
    reg only_misaligned, only_device, misaligned;
    reg [63:0] device_address, source_value;
    initial begin
        only_misaligned=$test$plusargs("only_misaligned");
        only_device=$test$plusargs("only_device");
        if (only_misaligned && only_device) $fatal(1,"choose one negative-control slice");
        repeat (3) @(negedge clk);
        rst=0;
        for (stall=0; stall<2; stall=stall+1) begin
            if (!only_device)
                for (pattern_i=0; pattern_i<2; pattern_i=pattern_i+1)
                    for (attr_i=0; attr_i<3; attr_i=attr_i+1)
                        for (width_i=2; width_i<=3; width_i=width_i+1)
                            for (offset_i=0; offset_i<8; offset_i=offset_i+1)
                                for (op_i=int'(`LSU_LR); op_i<=int'(`LSU_AMOMAXU); op_i=op_i+1) begin
                                    misaligned=(offset_i & ((1<<width_i)-1))!=0;
                                    if (!only_misaligned || misaligned) begin
                                        seed(pattern_i);
                                        source_value=pattern_i!=0 ? 64'hfedcba9880000001 : 64'h0123456701234567;
                                        if (misaligned) reject_and_consume(op_i[4:0],width_i[1:0],RAM+64'(offset_i),attr_i[1:0]);
                                        else begin
                                            if (op_i[4:0]==`LSU_SC)
                                                access(`LSU_LR,width_i[1:0],RAM+64'(offset_i),attr_i[1:0],0,0,0);
                                            else if (op_i>=`LSU_AMOSWAP)
                                                access(`LSU_LR,`LS_D,RESERVE,0,0,0,0);
                                            access(op_i[4:0],width_i[1:0],RAM+64'(offset_i),attr_i[1:0],source_value,0,op_i[4:0]==`LSU_SC);
                                            if (op_i[4:0]==`LSU_LR)
                                                access(`LSU_SC,width_i[1:0],RAM+64'(offset_i),attr_i[1:0],source_value,0,1);
                                            if (op_i>=`LSU_AMOSWAP)
                                                access(`LSU_SC,`LS_D,RESERVE,0,source_value,0,0);
                                            else
                                                access(`LSU_SC,width_i[1:0],RAM+64'(offset_i),attr_i[1:0],source_value,0,0);
                                        end
                                    end
                                end
            if (!only_misaligned)
                for (device_i=0; device_i<5; device_i=device_i+1) begin
                    case (device_i)
                        0: device_address=64'h02000000;
                        1: device_address=64'h0c200000;
                        2: device_address=64'h10000000;
                        3: device_address=64'h11000000;
                        4: device_address=64'h12000000;
                    endcase
                    // Include reserved PBMT=3 here: it cannot turn a physical
                    // device into reservable RAM even if presented upstream.
                    for (attr_i=0; attr_i<4; attr_i=attr_i+1)
                        for (width_i=2; width_i<=3; width_i=width_i+1)
                            for (offset_i=0; offset_i<8; offset_i=offset_i+1)
                                for (op_i=int'(`LSU_LR); op_i<=int'(`LSU_AMOMAXU); op_i=op_i+1) begin
                                    seed(0);
                                    reject_and_consume(op_i[4:0],width_i[1:0],device_address+64'(offset_i),attr_i[1:0]);
                                end
                end
            if (!only_device && !only_misaligned)
                for (attr_i=0; attr_i<3; attr_i=attr_i+1)
                    for (alias_i=0; alias_i<3; alias_i=alias_i+1)
                        for (width_i=2; width_i<=3; width_i=width_i+1) begin
                            seed(1);
                            access(`LSU_STORE,width_i[1:0],RAM,attr_i[1:0],64'h8000000180000001,0,0);
                            access(`LSU_LOAD,width_i[1:0],RAM,alias_i[1:0],0,0,0);
                            access(`LSU_LR,width_i[1:0],RAM,attr_i[1:0],0,0,0);
                            access(`LSU_SC,width_i[1:0],RAM,alias_i[1:0],64'h0123456712345678,0,1);
                            access(`LSU_SC,width_i[1:0],RAM,attr_i[1:0],0,0,0);
                        end
            if (!only_device && !only_misaligned)
                for (attr_i=0; attr_i<3; attr_i=attr_i+1) begin
                    // Karu reserves an aligned eight-byte granule, with an
                    // exact operand-address match required for SC success.
                    seed(0);
                    access(`LSU_LR,`LS_W,RAM,attr_i[1:0],0,0,0);
                    access(`LSU_SC,`LS_D,RAM,attr_i[1:0],64'h123456789abcdef0,0,1);
                    access(`LSU_SC,`LS_D,RAM,attr_i[1:0],0,0,0);
                    seed(1);
                    access(`LSU_LR,`LS_D,RAM,attr_i[1:0],0,0,0);
                    access(`LSU_SC,`LS_W,RAM,attr_i[1:0],64'h8000000080000001,0,1);
                    access(`LSU_SC,`LS_W,RAM,attr_i[1:0],0,0,0);
                    seed(0);
                    access(`LSU_LR,`LS_D,RAM,attr_i[1:0],0,0,0);
                    access(`LSU_SC,`LS_W,RAM+4,attr_i[1:0],0,0,0);
                    access(`LSU_SC,`LS_D,RAM,attr_i[1:0],0,0,0);
                    // A matching operand address cannot waive alignment.
                    seed(0);
                    access(`LSU_LR,`LS_W,RAM+4,attr_i[1:0],0,0,0);
                    access(`LSU_SC,`LS_D,RAM+4,attr_i[1:0],64'h123456789abcdef0,1,0);
                    access(`LSU_SC,`LS_W,RAM+4,attr_i[1:0],0,0,0);
                end
        end
        if (!only_device && !only_misaligned && (ar_stalls==0 || aw_stalls==0))
            $fatal(1,"handshake delay coverage missing");
        $display("LSU_ATOMIC_PASS checks=%0d rejected=%0d AR=%0d AW=%0d W=%0d B=%0d",
            checks,rejected,ars,aws,ws,bs);
        $finish;
    end
    initial begin #30000000; $fatal(1,"LSU atomic watchdog"); end
endmodule

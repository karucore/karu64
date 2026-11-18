// SPDX-License-Identifier: BSD-3-Clause
// karudbg authentication block: POR-domain lifecycle grant, boot hold, ROM
// mailbox and revocation. Normative interface: doc/debug-auth-contract.md.
//
// Reset is POR only (rst). Hart/system resets, ndmreset and DM deactivation
// never clear auth_unlock, boot_done, fw_lock, revoke_q or auth_req; DM
// deactivation (dm_active_i=0) resets only the mailbox session.
//
// Hart side: the core reports one committed (legal, non-trapping) access to
// an authentication CSR per cycle on csr_fire_i, plus the commit-provenance
// signals of the issuing instruction. The core has already applied the
// instruction-form legality table (contract section 3), so csr_we_i is the
// Zicsr "performs a write" bit and csr_wdata_i the architecturally written
// value. DMI side: the DM forwards each accepted authdata access only while
// lc==AUTH (authdata is absent otherwise, as Debug 1.0 Security recommends).
module karudbg_auth #(
    parameter [63:0] AUTH_ROM_BASE = 64'h0000_0000_0001_0000,
    parameter [63:0] AUTH_ROM_END  = 64'h0000_0000_0002_0000
) (
    input wire clk,
    input wire rst,                  // POR
    // Platform trust inputs (contract 3.4, plan 1.1)
    input wire [1:0] lc_i,           // 0 OPEN, 1 AUTH, 2 DISABLED, 3 = DISABLED
    input wire hold_strap_i,
    input wire revoke_i,
    input wire [1:0] trng_opst_i,
    input wire [15:0] trng_data_i,
    output wire trng_ack_o,
    // Outputs
    output reg debug_enable_o,       // registered gate (K2/K4 side)
    output wire debug_enable_next_o, // its next state, for ndmreset_q only
    output wire lc_auth_o,           // authdata implemented
    output reg sys_reset_o,          // boot hold or relock reset; one flop
    // DM side
    input wire dm_active_i,
    input wire dmi_valid_i,          // accepted authdata access, lc==AUTH only
    input wire dmi_write_i,
    input wire [31:0] dmi_wdata_i,
    output reg [31:0] dmi_rdata_o,   // combinational, for the accepted access
    output reg authbusy_o,
    // Hart side (cut K2)
    input wire core_in_reset_i,
    input wire csr_fire_i,
    input wire [2:0] csr_sel_i,      // 0 auth, 1 rx, 2 tx, 3 rng, 4 mbst
    input wire csr_we_i,
    input wire [63:0] csr_wdata_i,
    output reg [63:0] csr_rdata_o,
    input wire [63:0] ex_pc_i,
    input wire issuing_i,
    input wire trap_i,
    input wire dbg_enter_i,
    input wire debug_mode_i,
    input wire [1:0] priv_i,
    input wire virt_i
);
    localparam [1:0] LC_OPEN = 2'd0, LC_AUTH = 2'd1;
    localparam [2:0] SEL_AUTH = 3'd0, SEL_RX = 3'd1, SEL_TX = 3'd2,
                     SEL_RNG = 3'd3, SEL_MBST = 3'd4;
    localparam [2:0] ST_IDLE = 3'd0, ST_HOLD = 3'd1, ST_REQUESTED = 3'd2,
                     ST_CLOSED = 3'd3;
    localparam [2:0] E_NONE = 3'd0, E_OVERFLOW = 3'd1, E_UNDERFLOW = 3'd2,
                     E_BAD_OP = 3'd3, E_BAD_STATE = 3'd4;
    localparam [3:0] OP_STATUS = 4'h0, OP_REQUEST = 4'h1, OP_SEND = 4'h2,
                     OP_RECV = 4'h3, OP_ABORT = 4'hf;

    // ---- POR-domain state ----
    reg [1:0] lc_q;
    reg hold_q, auth_req_q, auth_unlock_q, boot_done_q, fw_lock_q, revoke_q;
    reg [7:0] perm_req_q;
    // ---- mailbox session state (also reset by DM deactivation) ----
    reg [31:0] rx_mem [0:15];
    reg [31:0] tx_mem [0:15];
    reg [3:0] rx_rd, rx_wr, tx_rd, tx_wr;
    reg [4:0] rx_count, tx_count;
    reg [4:0] send_rem, recv_rem;
    reg [2:0] err_q;
    reg tx_full_q;
    reg sess_event_q;                // sticky session-reset event, ROM-acknowledged
    reg resp_started_q;              // POR-sticky: ROM has popped an RX word
    reg hart_started_q;              // POR-sticky: hart has left reset once

    wire lc_auth, pc_in_rom, boot_exit_now, session_reset;
    wire [2:0] state;
    wire [4:0] rx_free, tx_free;
    wire host_push, host_pop, rom_pop, rom_push, rom_push_drop;
    wire dmi_read, dmi_header;
    wire [3:0] hdr_op;
    wire [4:0] hdr_n;
    wire hdr_rsvd_ok, req_arg_ok, req_state_ok;
    wire unlock_commit, fw_lock_set, boot_done_set, debug_enable_d;
    wire hold_d, relock_d;
    wire abort_fire, sess_event, sess_ack, sess_close_now;
    wire csr_live, reset_close;
    wire [31:0] status_word;
    wire unused_wdata;
    integer i;

    assign unused_wdata = &{1'b0, csr_wdata_i[63:32]};

    assign lc_auth = lc_q == LC_AUTH;
    assign lc_auth_o = lc_auth;
    assign pc_in_rom = ex_pc_i >= AUTH_ROM_BASE && ex_pc_i < AUTH_ROM_END;
    // Any trap, any issue from outside the ROM range, or Debug Mode entry
    // closes the window. Prefetch does not count; issue does.
    assign boot_exit_now = !core_in_reset_i &&
        (trap_i || dbg_enter_i || (issuing_i && !pc_in_rom));
    // Any hart/system reset after the hart first left reset closes the
    // window too: a reset reruns the ROM with boot_done=1 (plan 2.2), so
    // repeated resets give no extra attempts. The POR boot hold is the only
    // reset before hart_started_q.
    assign reset_close = core_in_reset_i && hart_started_q;
    // A CSR access in a reset, trap or Debug-entry cycle is killed with its
    // instruction: it has no effect here, whatever the core reports (C8).
    assign csr_live = csr_fire_i && !core_in_reset_i && !trap_i && !dbg_enter_i;
    assign state = (!lc_auth || boot_done_q) ? ST_CLOSED :
                   auth_req_q ? ST_REQUESTED : hold_q ? ST_HOLD : ST_IDLE;
    assign rx_free = 5'd16 - rx_count;
    assign tx_free = 5'd16 - tx_count;
    assign session_reset = !dm_active_i;
    assign abort_fire = dmi_header && hdr_op == OP_ABORT && hdr_rsvd_ok;
    // A session reset (deactivation or ABORT) before the ROM has consumed any
    // response word only raises the sticky event flag: the ROM re-pushes its
    // challenge. One after consumption, or coinciding with the first pop,
    // closes the window in hardware: one RESPONSE per POR, with no counter
    // that a host could wrap between ROM observations.
    assign sess_event = session_reset || abort_fire;
    assign sess_close_now = sess_event && (resp_started_q || rom_pop);
    assign sess_ack = csr_live && csr_we_i && csr_sel_i == SEL_AUTH &&
                      csr_wdata_i[25] && !debug_mode_i;

    // ---- DMI side decode ----
    assign dmi_read = dmi_valid_i && !dmi_write_i;
    assign dmi_header = dmi_valid_i && dmi_write_i && send_rem == 0;
    assign hdr_op = dmi_wdata_i[31:28];
    assign hdr_n = dmi_wdata_i[4:0];
    assign hdr_rsvd_ok = dmi_wdata_i[27:24] == 4'h0;
    // REQUEST key 0xA5 in [23:16]; D4: exactly permission bit 0.
    assign req_arg_ok = dmi_wdata_i[23:16] == 8'ha5 && dmi_wdata_i[15:8] == 8'h00 &&
                        dmi_wdata_i[7:0] == 8'h01;
    assign req_state_ok = lc_auth && hold_q && !auth_req_q && !boot_done_q;
    assign host_push = dmi_valid_i && dmi_write_i && send_rem != 0;
    assign host_pop = dmi_read && recv_rem != 0;
    // ---- hart side decode (legality already enforced by the core) ----
    assign rom_pop = csr_live && csr_we_i && csr_sel_i == SEL_RX && rx_count != 0;
    assign rom_push = csr_live && csr_we_i && csr_sel_i == SEL_TX && tx_count != 5'd16;
    assign rom_push_drop = csr_live && csr_we_i && csr_sel_i == SEL_TX && tx_count == 5'd16;
    assign trng_ack_o = csr_live && csr_we_i && csr_sel_i == SEL_RNG;
    // Commit predicate (plan 3.1, contract 3.1) plus a REQUEST in this POR.
    assign unlock_commit = csr_live && csr_we_i && csr_sel_i == SEL_AUTH &&
        csr_wdata_i[0] && pc_in_rom && priv_i == 2'd3 && !virt_i && !debug_mode_i &&
        lc_auth && auth_req_q && !boot_done_q && !boot_exit_now && !sess_close_now;
    assign fw_lock_set = csr_live && csr_we_i && csr_sel_i == SEL_AUTH && csr_wdata_i[2];
    assign boot_done_set = boot_exit_now || sess_close_now || reset_close ||
        (csr_live && csr_we_i && csr_sel_i == SEL_AUTH && csr_wdata_i[1] && !debug_mode_i);
    assign debug_enable_d =
        (lc_q == LC_OPEN || (lc_auth && (auth_unlock_q || unlock_commit))) &&
        !(fw_lock_q || fw_lock_set) && !(revoke_q || revoke_i);
    assign debug_enable_next_o = debug_enable_d;
    // Hold: sampled at POR in lc=AUTH only (OPEN and DISABLED boot normally
    // whatever the strap), released by REQUEST or by releasing the strap.
    assign hold_d = hold_q && hold_strap_i &&
                    !(dmi_header && hdr_op == OP_REQUEST && hdr_rsvd_ok && req_arg_ok && req_state_ok);
    // Relock: a hart in Debug Mode while locked is reset (plan 3.5 item 3).
    assign relock_d = !debug_enable_o && debug_mode_i && !core_in_reset_i;

    // Bit 10 is reserved: any read with a RECV pending returns TX data, so a
    // status word is only ever returned with no RECV pending.
    assign status_word = {4'h6, 2'd1, lc_q, state, err_q, 2'b00, send_rem,
                          1'b0, rx_free, tx_count};

    always @* begin
        dmi_rdata_o = status_word;
        if (recv_rem != 0) dmi_rdata_o = tx_mem[tx_rd];
    end

    always @* begin
        csr_rdata_o = 64'b0;
        case (csr_sel_i)
            SEL_AUTH: csr_rdata_o = {39'b0, revoke_q, perm_req_q, 7'b0, auth_unlock_q,
                                     auth_req_q, hold_q, lc_q, debug_enable_o,
                                     fw_lock_q, boot_done_q, auth_unlock_q};
            SEL_RX: csr_rdata_o = {31'b0, rx_count != 0, rx_count != 0 ? rx_mem[rx_rd] : 32'b0};
            SEL_TX: csr_rdata_o = 64'b0;
            SEL_RNG: csr_rdata_o = {32'b0, trng_opst_i, 14'b0,
                                    trng_opst_i == 2'd2 ? trng_data_i : 16'b0};
            SEL_MBST: csr_rdata_o = {38'b0, resp_started_q, sess_event_q, perm_req_q,
                                     2'b00, tx_full_q, state, tx_free, rx_count};
            default: csr_rdata_o = 64'b0;
        endcase
    end

    // ---- POR-domain registers ----
    always @(posedge clk) begin
        if (rst) begin
            lc_q <= lc_i == 2'd3 ? 2'd2 : lc_i;
            hold_q <= hold_strap_i && lc_i == LC_AUTH;
            auth_req_q <= 0; auth_unlock_q <= 0; boot_done_q <= 0;
            fw_lock_q <= 0; revoke_q <= revoke_i; perm_req_q <= 0;
            debug_enable_o <= lc_i == LC_OPEN && !revoke_i;
            sys_reset_o <= hold_strap_i && lc_i == LC_AUTH;
            sess_event_q <= 0; resp_started_q <= 0; hart_started_q <= 0;
        end else begin
            hold_q <= hold_d;
            if (dmi_header && hdr_op == OP_REQUEST && hdr_rsvd_ok && req_arg_ok && req_state_ok) begin
                auth_req_q <= 1;
                perm_req_q <= dmi_wdata_i[7:0];
            end
            if (unlock_commit) auth_unlock_q <= 1;
            if (boot_done_set) boot_done_q <= 1;
            if (fw_lock_set) fw_lock_q <= 1;
            if (revoke_i) revoke_q <= 1;
            if (rom_pop) resp_started_q <= 1;
            if (!core_in_reset_i) hart_started_q <= 1;
            if (sess_event) sess_event_q <= 1;
            else if (sess_ack) sess_event_q <= 0;
            debug_enable_o <= debug_enable_d;
            sys_reset_o <= hold_d || relock_d;
        end
    end

    // ---- mailbox session ----
    always @(posedge clk) begin
        if (rst) begin
            rx_rd <= 0; rx_wr <= 0; tx_rd <= 0; tx_wr <= 0;
            rx_count <= 0; tx_count <= 0; send_rem <= 0; recv_rem <= 0;
            err_q <= E_NONE; tx_full_q <= 0; authbusy_o <= 0;
            for (i = 0; i < 16; i = i + 1) begin rx_mem[i] <= 0; tx_mem[i] <= 0; end
        end else begin
            authbusy_o <= dmi_valid_i && !session_reset;
            if (sess_event) begin
                rx_rd <= 0; rx_wr <= 0; tx_rd <= 0; tx_wr <= 0;
                rx_count <= 0; tx_count <= 0; send_rem <= 0; recv_rem <= 0;
                err_q <= E_NONE; tx_full_q <= 0;
            end else begin
                // RX: host pushes, ROM pops.
                if (host_push) begin rx_mem[rx_wr] <= dmi_wdata_i; rx_wr <= rx_wr + 1'b1; end
                if (rom_pop) rx_rd <= rx_rd + 1'b1;
                rx_count <= rx_count + {4'b0, host_push} - {4'b0, rom_pop};
                // TX: ROM pushes, host pops.
                if (rom_push) begin tx_mem[tx_wr] <= csr_wdata_i[31:0]; tx_wr <= tx_wr + 1'b1; end
                if (host_pop) tx_rd <= tx_rd + 1'b1;
                tx_count <= tx_count + {4'b0, rom_push} - {4'b0, host_pop};
                if (rom_push_drop) tx_full_q <= 1;
                if (host_push) send_rem <= send_rem - 1'b1;
                if (host_pop) recv_rem <= recv_rem - 1'b1;
                if (dmi_header) begin
                    if (!hdr_rsvd_ok) begin
                        if (err_q == E_NONE) err_q <= E_BAD_OP;
                    end else case (hdr_op)
                        OP_STATUS: recv_rem <= 0;
                        OP_REQUEST:
                            if (!req_arg_ok) begin
                                if (err_q == E_NONE) err_q <= E_BAD_OP;
                            end else if (!req_state_ok) begin
                                if (err_q == E_NONE) err_q <= E_BAD_STATE;
                            end
                        OP_SEND:
                            if (state == ST_CLOSED) begin
                                if (err_q == E_NONE) err_q <= E_BAD_STATE;
                            end else if (hdr_n == 0 || hdr_n > 5'd16 || hdr_n > rx_free) begin
                                if (err_q == E_NONE) err_q <= E_OVERFLOW;
                            end else send_rem <= hdr_n;
                        OP_RECV:
                            if (hdr_n == 0 || hdr_n > 5'd16 || hdr_n > tx_count) begin
                                if (err_q == E_NONE) err_q <= E_UNDERFLOW;
                            end else recv_rem <= hdr_n;
                        default: if (err_q == E_NONE) err_q <= E_BAD_OP;
                    endcase
                end
            end
        end
    end

    // synthesis translate_off
    // Local invariants (contract 3, 4; plan 3.1, 3.5):
    // - grant, boot_done, fw_lock, revoke_q, auth_req are monotone between PORs;
    // - auth_unlock never rises outside AUTH, without REQUEST, after
    //   boot_done, or without the commit predicate;
    // - debug_enable follows its formula one cycle later;
    // - FIFO counts stay within depth and match their pointers;
    // - a pending SEND never exceeds RX free space;
    // - outside AUTH, without revocation, the hart is never held or reset;
    // - a session reset after the ROM consumed a response word closes the
    //   window on that edge (no unlock can follow).
    reg chk_valid_q, chk_unlock_q, chk_done_q, chk_lock_q, chk_revoke_q, chk_req_q;
    reg chk_close_q, chk_reset_close_q;
    always @(posedge clk) begin
        chk_valid_q <= !rst;
        chk_close_q <= !rst && sess_event && (resp_started_q || rom_pop);
        chk_reset_close_q <= !rst && core_in_reset_i && hart_started_q;
        chk_unlock_q <= auth_unlock_q; chk_done_q <= boot_done_q;
        chk_lock_q <= fw_lock_q; chk_revoke_q <= revoke_q; chk_req_q <= auth_req_q;
        if (!rst && chk_valid_q) begin
            if ((chk_unlock_q && !auth_unlock_q) || (chk_done_q && !boot_done_q) ||
                (chk_lock_q && !fw_lock_q) || (chk_revoke_q && !revoke_q) ||
                (chk_req_q && !auth_req_q))
                $fatal(1, "karudbg_auth: monotone POR-domain bit cleared");
            if (!chk_unlock_q && auth_unlock_q && (!lc_auth || !chk_req_q || chk_done_q))
                $fatal(1, "karudbg_auth: auth_unlock rose outside a requested AUTH window");
            if (debug_enable_o && (lc_q != LC_OPEN && !(lc_auth && auth_unlock_q)))
                $fatal(1, "karudbg_auth: debug enabled without lifecycle or grant");
            if (debug_enable_o && (fw_lock_q || revoke_q))
                $fatal(1, "karudbg_auth: debug enabled after revocation");
            // OPEN is never held or reset unless revoked (DISABLED keeps the
            // gate closed, so a Debug-Mode hart there is relock-reset).
            if (lc_q == LC_OPEN && !fw_lock_q && !revoke_q && sys_reset_o)
                $fatal(1, "karudbg_auth: hold or relock reset in OPEN without revocation");
            if (chk_reset_close_q && !boot_done_q)
                $fatal(1, "karudbg_auth: system reset after boot left the window open");
            if (chk_close_q && !boot_done_q)
                $fatal(1, "karudbg_auth: session reset after response start left the window open");
            if (rx_count > 16 || tx_count > 16 || send_rem > rx_free ||
                rx_count[3:0] != rx_wr - rx_rd || tx_count[3:0] != tx_wr - tx_rd)
                $fatal(1, "karudbg_auth: mailbox FIFO accounting");
        end
        if (!rst && unlock_commit && (!pc_in_rom || debug_mode_i || priv_i != 2'd3 || virt_i ||
                                      core_in_reset_i))
            $fatal(1, "karudbg_auth: unlock committed outside the ROM predicate");
    end
    // synthesis translate_on
endmodule

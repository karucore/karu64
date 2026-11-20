#!/usr/bin/env python3
"""Lemma C1 (doc/debug-auth-plan.md 5.1, 5.2): bypass freedom, as a checked
structural inventory of the flattened karudbg_top.

Yosys elaborates karudbg_top from dbg/karudbg.f with DEFINES, runs proc,
memory_collect and flatten, and writes the netlist as JSON. The script then
computes cones of influence over that netlist, bit by bit, going backward
from each protected element and stopping at the cuts:

  * A bitwise cell (and, or, xor, not, mux, pmux, every flip-flop type)
    connects output bit i only to input bit i and to its select, enable,
    clock and reset bits. Every other cell (arithmetic, compare, shift,
    reduce, memory) connects every output bit to every input bit, which
    over-approximates. A memory's read data depends on all of its write
    ports, so a write path is a structural path to the stored contents.
  * A cut signal is a port or net of a named instance. Going backward, a
    path crosses an input-port cut when it leaves a cell inside that
    instance for a bit of the port, and an output-port cut when it leaves a
    cell outside the instance for a bit of the port. So a net shared by
    several consumers is a cut only on the edges into the named consumer.
  * The traversal does not expand past a cut it crosses, a state bit of
    another protected element, or a top-level input. What it reaches is the
    element's frontier: cut signals, protected elements, trusted inputs,
    and adversary inputs reached without crossing any cut ("direct"). A
    path into one protected element through another is therefore checked
    in two steps, each against its own allowlist.

Checks (each list is exact; a missing entry fails as stale):
  1. ELEMENTS: each protected element's frontier, other than trusted
     inputs, equals its ALLOW_ELEMENTS entry.
  2. DRIVERS: the plan's two "in particular" claims. The untrusted side of
     each K2 and K3.hart signal is traced back until it crosses H, the
     hart's own output ports; each signal's frontier equals its
     ALLOW_DRIVERS entry. So nothing but the hart's CSR sideband reaches K2
     and nothing but the hart's own imem/dmem ports reaches the island.
  3. Every top-level input is classified as trusted or adversary.

The inventory (frontiers, each cut's own untrusted side, and the adversary
inputs that reach each element through each first crossing) is written to
<out>/inventory.json and <out>/inventory.txt.

Limits: structural only. A path that exists is reported even if its logic
can never propagate a value, and a gate's function is not checked (that is
C2-C9). Bitwise precision stops at non-bitwise cells, which over-approximate.

The Yosys `select` cone operators (%ci*, with stop sets) work on whole wires
and whole cells; on this netlist that pulls every input of a wide mux into
every cone, and `splitcells` did not finish on the flattened core, so the
cones are computed here on Yosys's own netlist instead.

--self-test elaborates mutated copies of the RTL (the repository is only
read) in parallel; each must fail with its expected violation. With six
elaborations in parallel a run takes about 80 s and up to 1.1 GB per process.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
TOP = "karudbg_top"
# KARU_DBG_FULL is SBA + autoexec + triggers (dbg/karudbg_cfg.vh). KARU_NO_V
# drops the vector unit, as lemmas C4, C8 and C10 do: the vector unit sits
# inside the hart, on the untrusted side of K2, K3 and K5, and adds nothing
# to the cuts. The VCU118 image also has KARU_ZKR, which is not elaborated.
DEFINES = ["KARU_DBG", "KARU_DBG_AUTH", "KARU_DBG_FULL", "KARU_NO_V"]

# ---- inputs of karudbg_top (plan 1.1, 1.2) ----
TRUSTED = {
    "clk": "clock (plan 1.2: not adversary-controlled)",
    "rst": "POR (plan 1.2)",
    "lc_i": "lifecycle (plan 1.2)",
    "revoke_i": "trusted platform revocation input (contract 3.4)",
}
ADVERSARY = {  # plan 1.2: every other input
    "tck": "JTAG", "tms": "JTAG", "tdi": "JTAG", "trst_n": "JTAG",
    "hart_reset_i": "system reset", "hold_strap_i": "boot-hold strap",
    "irq": "interrupt", "irq_software": "interrupt", "irq_external_m": "interrupt",
    "irq_external_s": "interrupt", "time_in": "time", "cache_flush_done": "cache flush handshake",
    "uncache_page": "platform input, not in plan 1.2's list: treated as adversary",
    "hpm_events": "platform input, not in plan 1.2's list: treated as adversary",
}
for _p in ("arready", "rid", "rdata", "rresp", "rlast", "rvalid"):
    ADVERSARY["imem_" + _p] = ADVERSARY["dmem_" + _p] = "fabric response"
for _p in ("awready", "wready", "bid", "bresp", "bvalid"):
    ADVERSARY["dmem_" + _p] = "fabric response"

# ---- cuts (plan 5.1) ----
# (group, instance, mode, signals). mode "in": crossed by a backward path
# that leaves a cell inside the instance for the signal; "out": by one that
# leaves a cell outside the instance for it.
_AR = ["arid", "araddr", "arlen", "arsize", "arburst", "arprot", "arvalid"]
_AW = ["awid", "awaddr", "awlen", "awsize", "awburst", "awprot", "awvalid", "wdata", "wstrb", "wlast", "wvalid"]
CUTS = [
    # K1: the DM's DMI request port; JTAG, DTM and BSCAN are behind it.
    ("K1", "system.dm", "in", ["req_valid_i", "req_addr_i", "req_op_i", "req_data_i",
                               "resp_ready_i", "dmi_reset_i"]),
    # K1.mbox: the K1 traffic the DM forwards to the karudbg_auth mailbox
    # (authdata accesses and the session reset; plan 5.3, "K1 can affect
    # only the mailbox"). auth_wdata_o is a wire from req_data_i, so the
    # mailbox reads the K1 net itself and only this output cut separates it.
    ("K1.mbox", "system.dm", "out", ["auth_valid_o", "auth_write_o", "auth_wdata_o", "dmactive_o"]),
    # K2: the karudbg_auth hart port. core_in_reset_i is in the RTL's K2
    # group (dbg/karudbg_auth.v) although plan 5.1 does not list it.
    ("K2", "system.auth", "in", ["csr_fire_i", "csr_sel_i", "csr_we_i", "csr_wdata_i", "ex_pc_i",
                                 "issuing_i", "trap_i", "dbg_enter_i", "debug_mode_i", "priv_i",
                                 "virt_i", "core_in_reset_i"]),
    # K3: the island on the imem and dmem ports. K3.hart is its hart side
    # (requests), K3.ext its external side (responses into the selector).
    # C9 proves the island with both sides free.
    ("K3.hart", "system.island", "in", ["up_imem_" + s for s in _AR + ["rready"]] +
     ["up_dmem_" + s for s in _AR + ["rready"] + _AW + ["bready"]]),
    ("K3.ext", "system.island", "in",
     ["dn_imem_" + s for s in ("arready", "rid", "rdata", "rresp", "rlast", "rvalid")] +
     ["dn_dmem_" + s for s in ("arready", "rid", "rdata", "rresp", "rlast", "rvalid",
                               "awready", "wready", "bid", "bresp", "bvalid")]),
    # K4: the DM's hart-side interface. K4.out are the outputs plan 5.1
    # lists; K4.in are the inputs of the same interfaces (hart status,
    # debug-page requests, SBA responses), all free in C2, C3 and C7.
    ("K4.out", "system.dm", "out", ["halt_req_o", "resume_req_o", "resume_authorized_o", "ndmreset_o",
                                    "mem_rdata_o", "mem_ready_o", "mem_error_o", "sba_req_valid_o",
                                    "sba_req_addr_o", "sba_req_data_o", "sba_req_size_o",
                                    "sba_req_write_o", "sba_resp_ready_o"]),
    ("K4.in", "system.dm", "in", ["hart_halted_i", "hart_resume_ack_i", "hart_unavailable_i",
                                  "hart_reset_i", "mem_req_i", "mem_write_i", "mem_addr_i",
                                  "mem_wdata_i", "mem_be_i", "sba_req_ready_i", "sba_resp_valid_i",
                                  "sba_resp_data_i", "sba_resp_error_i"]),
    # K5: the set and clear terms of the debug_mode flop (rtl/karu64.v);
    # C4 proves the set term gated by debug_enable_i.
    ("K5", "system.core", "in", ["dbg_enter", "dbg_exit"]),
    # H: the hart's own output ports that feed K2 and K3.hart. Used for the
    # DRIVERS check; not one of K1-K5.
    ("H", "system.core", "out", ["auth_fire_o", "auth_sel_o", "auth_we_o", "auth_wdata_o",
                                 "auth_ex_pc_o", "auth_issuing_o", "auth_trap_o", "auth_dbg_enter_o",
                                 "auth_priv_o", "auth_virt_o"] +
     ["imem_" + s for s in _AR + ["rready"]] + ["dmem_" + s for s in _AR + ["rready"] + _AW + ["bready"]]),
]
CHECKED_DRIVERS = ["K2", "K3.hart"]

# ---- protected elements (plan 5.2, C1) ----
_ISLAND_RESP = (["up_imem_" + s for s in ("arready", "rid", "rdata", "rresp", "rlast", "rvalid")] +
                ["up_dmem_" + s for s in ("arready", "rid", "rdata", "rresp", "rlast", "rvalid",
                                          "awready", "wready", "bid", "bresp", "bvalid")])
ELEMENTS = {
    "debug_mode": dict(owner="system.core", nets=["debug_mode"]),
    "auth_state": dict(owner="system.auth", state=True),
    "dm_state": dict(owner="system.dm", state=True),
    "island_sram": dict(owner="system.island", memory="sram"),
    # island routing flags, bridges and ROM: the source of island response data
    "island_state": dict(owner="system.island", state=True, skip_memory=["sram"]),
    # island response data as the hart receives it: the selector's outputs.
    # Combinational, and read inside the island too, so it is a start point
    # only, never a stop for the other cones (stop=False).
    "island_response": dict(owner="system.island", nets=_ISLAND_RESP, stop=False),
}

def _sigs(group):
    return next(c[3] for c in CUTS if c[0] == group)


# ---- allowlists: the expected inventory. Every entry is a first crossing
# (cut signal, protected element, or adversary input reached directly). A
# frontier entry not listed here fails as a new path; a listed entry that is
# no longer reached fails as stale. Trusted inputs are reported, not listed.
_RESET = {  # the hart reset core_rst = rst | hart_reset_i | ndmreset_o | auth_reset_o (C6cone)
    "K4.out.ndmreset_o": "ndmreset into the hart reset; 0 while locked (C2, C7dm)",
    "auth_state": "auth_reset_o (boot hold, relock) into the hart reset (C5, C7relock)",
    "in:hart_reset_i": "DIRECT, the system reset (plan 1.2) into the hart reset. It only "
                       "resets; the lemmas hold with it free (C4: debug_mode=0 after any "
                       "reset cycle; C9; C6 reset values)",
}
_K3_HART_USED = [s for s in _sigs("K3.hart") if not s.endswith("prot")]  # arprot is unused
_K3_EXT_HANDSHAKE = ["dn_imem_arready", "dn_imem_rvalid", "dn_imem_rlast", "dn_dmem_arready",
                     "dn_dmem_rvalid", "dn_dmem_rlast", "dn_dmem_awready", "dn_dmem_bvalid"]
_K2_LIVE = [s for s in _sigs("K2") if s != "virt_i"]  # virt_i is 0 without KARU_H
ALLOW_ELEMENTS = {
    "debug_mode": {
        "K5.dbg_enter": "the set term; C4 proves it rises only with debug_enable_i",
        "K5.dbg_exit": "the clear term (dret at the DM's resume address)",
        **_RESET,
    },
    "auth_state": {
        **{f"K1.mbox.{s}": "authdata access or session reset forwarded by the DM (C5, inputs free)"
           for s in _sigs("K1.mbox")},
        **{f"K2.{s}": "hart CSR sideband (C5, inputs free; C8 provenance)" for s in _K2_LIVE
           if s != "core_in_reset_i"},
        "K2.core_in_reset_i": "the hart reset: a CSR access in a reset cycle has no effect, and a "
                              "reset once the hart has run closes the window (C5)",
        "in:hold_strap_i": "DIRECT, the boot-hold strap (plan 2.4): sampled at POR, it can only "
                           "start or end the hold and grants nothing (C5 hold rules, C6v)",
    },
    "dm_state": {
        **{f"K1.{s}": "DMI request (C2, C3, C7 with K1 free)" for s in _sigs("K1")},
        # karudbg_auth's combinational debug_enable_next_o feeds the ndmreset
        # flop's gate (S10); it depends on the commit predicate and on the
        # session-close terms, hence on K2 and on the forwarded authdata access.
        **{f"K1.mbox.{s}": "back through karudbg_auth's debug_enable_next_o (ndmreset gate, S10)"
           for s in _sigs("K1.mbox")},
        **{f"K2.{s}": "through karudbg_auth's debug_enable_next_o (ndmreset gate, S10)" for s in _K2_LIVE},
        **{f"K4.in.{s}": "hart status, debug-page request or SBA response (free in C2, C3, C7)"
           for s in _sigs("K4.in")},
        "auth_state": "debug_enable, lc_auth, authbusy and mailbox read data",
    },
    "island_sram": {
        "island_state": "the write port is driven only by the d_bridge registers; C9 proves "
                        "writes only from the hart ports",
    },
    "island_state": {
        **{f"K3.hart.{s}": "hart request (C9, master free)" for s in _K3_HART_USED},
        # external handshakes move the outstanding/ownership flags; external
        # data, IDs and responses (rdata, rid, rresp, bid, bresp) never reach
        # island state
        **{f"K3.ext.{s}": "external handshake into the routing flags (C9, responder free)"
           for s in _K3_EXT_HANDSHAKE},
        "island_sram": "SRAM read data into the d_bridge",
        **_RESET,
    },
    "island_response": {
        **{f"K3.ext.{s}": "the selector's external input (K3); C9: used only for an outstanding "
                          "external transaction" for s in _sigs("K3.ext")},
        **{f"K3.hart.{s}": "address decode for arready/awready" for s in
           ["up_imem_araddr", "up_imem_arvalid", "up_dmem_araddr", "up_dmem_arvalid",
            "up_dmem_awaddr", "up_dmem_awvalid"]},
        "island_state": "island response data and the ownership flags",
    },
}
# Plan 5.2, C1: "nothing other than the hart's CSR file reaches K2, and nothing
# other than the hart's own ports reaches island SRAM writes". Each K2 and
# K3.hart signal must be the hart's own port signal.
_H_OF_K2 = {"csr_fire_i": "auth_fire_o", "csr_sel_i": "auth_sel_o", "csr_we_i": "auth_we_o",
            "csr_wdata_i": "auth_wdata_o", "ex_pc_i": "auth_ex_pc_o", "issuing_i": "auth_issuing_o",
            "trap_i": "auth_trap_o", "dbg_enter_i": "auth_dbg_enter_o", "priv_i": "auth_priv_o"}
ALLOW_DRIVERS = {
    **{f"K2.{k}": {f"H.{v}": "the hart's CSR sideband"} for k, v in _H_OF_K2.items()},
    "K2.debug_mode_i": {"debug_mode": "the hart's Debug Mode flop"},
    # Not the CSR file: plan 5.1 does not list this K2 input. The hart reset
    # makes a CSR access ineffective and closes the window once the hart has
    # run (C5); its composition is C6cone.
    "K2.core_in_reset_i": _RESET,
    **{f"K3.hart.{s}": {f"H.{s[3:]}": "the hart's own port"} for s in _sigs("K3.hart")},
}

# ---- the VCU118 debug image (--image) ----
# Its defines and parameters are those of the image's synthesis, listed
# below. The vector unit is included. Two things differ from DEFINES in
# what the inventory has to allow, and image_allowances() adds exactly those:
#   * KARU_RVA23S64 implies KARU_H, so K2.virt_i is live: the hart's
#     virtualisation mode, driven by its own auth_virt_o, reaches the
#     authentication state and, through debug_enable_next_o, the DM state,
#     like every other K2 signal;
#   * KARU_ZKR adds the top-level input zkr_rdata_i, the entropy block's
#     read data. It is classified as adversary, conservatively: the block is
#     written by the hart too. It must reach no protected element directly.
# The list and the parameters are those of the image's own synthesis, as its
# Vivado log prints them ("KARU_DEFINES:", and "Parameter ... bound to:" for
# karudbg_core in flow/fpga/vcu118_ddr_top.v), less the defines of the
# Ethernet and DDR4 blocks, which are outside karudbg_top:
#   * KARU_ICACHE, the instruction cache between the hart's fetch and K3;
#   * the reset vector in the island ROM, the external time input, and the
#     hardware window limit of karudbg_auth at 2^31 clocks.
# The island ROM's contents are a parameter too. The image's own ROM holds
# the authentication key and is not read here; --island-rom takes another
# build of the same ROM (the simulation's, with the public test key).
IMAGE_DEFINES = ["KARU_DBG", "KARU_DBG_FULL", "KARU_DBG_AUTH", "KARU_ZKR", "KARU_RVA23S64", "KARU_ICACHE",
                 "KARU_ZVK", "KARU_KECCAK", "KARU_V_MUL_CYCLES=16", "KARU_V_DIV_CYCLES=64", "KARU_V_LANE_PIPE",
                 "KARU_V_CWB_STAGE", "KARU_SMCNTRPMF", "KARU_SSCOFPMF"]
IMAGE_PARAMS = {"RESET_PC": "64'h0000000000010000", "EXT_TIME": "1", "AUTH_WINDOW_LOG2": "31"}
PARAMS = {}                     # parameters of TOP that differ from their defaults
def image_allowances():
    ALLOW_ELEMENTS["auth_state"]["K2.virt_i"] = "hart CSR sideband, live with KARU_H (C5, inputs free; C8 provenance)"
    ALLOW_ELEMENTS["dm_state"]["K2.virt_i"] = "through karudbg_auth's debug_enable_next_o (ndmreset gate, S10)"
    ALLOW_DRIVERS["K2.virt_i"] = {"H.auth_virt_o": "the hart's CSR sideband"}
    ADVERSARY["zkr_rdata_i"] = "entropy block read data (KARU_ZKR); the block is also written by the hart"

# ---- negative controls (--self-test): (name, file, [(before, after)],
# expected violation (kind, key, text)). Each must fail with that violation.
_SBA_W = "sba_req_valid && sba_req_write"
MUTANTS = [
    # Plan 5.4's control for C1: SBA writes routed into the island's write
    # channel, ahead of the island, as if karudbg_bus sat in front of it.
    ("sba_to_island_sram", "dbg/karudbg_core.v",
     [(".up_dmem_awaddr(k_dmem_awaddr),",
       f".up_dmem_awaddr({_SBA_W} ? sba_req_addr[`AXI_ADDR_W-1:0] : k_dmem_awaddr),"),
      (".up_dmem_awvalid(k_dmem_awvalid),", f".up_dmem_awvalid(k_dmem_awvalid || ({_SBA_W})),"),
      (".up_dmem_wdata(k_dmem_wdata),", f".up_dmem_wdata({_SBA_W} ? sba_req_data : k_dmem_wdata),"),
      (".up_dmem_wvalid(k_dmem_wvalid),", f".up_dmem_wvalid(k_dmem_wvalid || ({_SBA_W})),")],
     ("driver", "K3.hart.up_dmem_wdata", "new path: K4.out.sba_req_data_o")),
    # A non-CSR signal into the K2 write port: the DMI request word ORed
    # into the authentication CSR write data.
    ("dmi_word_into_k2", "dbg/karudbg_core.v",
     [(".csr_wdata_i(auth_csr_wdata),", ".csr_wdata_i(auth_csr_wdata | {32'b0, dmi_req_data_i}),")],
     ("driver", "K2.csr_wdata_i", "new path: ")),
    # A DMI input reaches debug_mode with no debug_enable gate: the DMI
    # request valid resets the hart, bypassing the DM and its ndmreset gate.
    ("dmi_request_resets_hart", "dbg/karudbg_core.v",
     [("        .rst(core_rst),\n`ifdef KARU_DBG_SBA", "        .rst(core_rst || dmi_req_valid_i),\n`ifdef KARU_DBG_SBA")],
     ("element", "debug_mode", "new path: in:tdi")),
    # The DM's halt request sets debug_mode beside the gated set term K5,
    # so the core gate (C4) is bypassed.
    ("halt_request_sets_debug_mode", "rtl/karu64.v",
     [("            if (dbg_enter) begin\n                debug_mode <= 1;",
       "            if (dbg_enter || debug_halt_req_i) begin\n                debug_mode <= 1;")],
     ("element", "debug_mode", "new path: K4.out.halt_req_o")),
    # Stale-inventory control: an allowlisted path disappears (the system
    # reset no longer reaches the hart).
    ("hart_reset_disconnected", "dbg/karudbg_core.v",
     [("assign core_rst = rst || hart_reset_i || ndmreset_o || auth_reset_o;",
       "assign core_rst = rst || ndmreset_o || auth_reset_o;")],
     ("element", "debug_mode", "stale allowlist entry: in:hart_reset_i")),
]


# ---------------------------------------------------------------------------
def rtl_files():
    return [l.strip() for l in (ROOT / "dbg/karudbg.f").read_text().splitlines()
            if l.strip().endswith(".v")]


def elaborate(work, overrides=None):
    """Flattened JSON netlist of TOP; overrides maps repository paths to copies."""
    work.mkdir(parents=True, exist_ok=True)
    files = [str((overrides or {}).get(f, ROOT / f)) for f in rtl_files()]
    flags = " ".join(f"-D{d}" for d in DEFINES)
    out = work / "netlist.json"
    params = "".join(f"chparam -set {k} {v} {TOP}\n" for k, v in PARAMS.items())
    script = (f"read_verilog {flags} -I{ROOT}/rtl -I{ROOT}/dbg {' '.join(files)}\n{params}"
              # no opt_clean: it drops unused port nets (rid, bid) by name
              f"hierarchy -check -top {TOP}\nproc\nmemory_collect\nflatten\n"
              f"write_json {out}\n")
    (work / "elab.ys").write_text(script)
    r = subprocess.run(["yosys", "-q", "-l", str(work / "yosys.log"), str(work / "elab.ys")],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        raise RuntimeError(f"yosys failed; see {work / 'yosys.log'}:\n" + "\n".join(r.stdout.splitlines()[-5:]))
    return out


def owner_of(name, cell):
    """Instance path of a flattened cell ('' for karudbg_top itself)."""
    if name.startswith("$flatten"):
        # $flatten\inst.\inst.$local: whole "inst." tokens, then "inst.$local..."
        path = []
        for part in name[len("$flatten"):].split("\\")[1:]:
            if part.endswith(".") and "$" not in part:
                path.append(part[:-1])
            else:
                path.append(part.split(".", 1)[0])
                break
        if any("$" in p for p in path):
            raise RuntimeError(f"cannot attribute cell {name} to an instance")
        return ".".join(path)
    hdl = cell.get("attributes", {}).get("hdlname")
    if hdl and not name.startswith("$"):
        return ".".join(hdl.split()[:-1])
    return ""


def inside(owner, inst):
    return owner == inst or owner.startswith(inst + ".")


BIT2 = {"$and", "$or", "$xor", "$xnor"}
BIT1 = {"$not", "$pos"}
NO_OUTPUT = {"$scopeinfo", "$check", "$print", "$assert", "$assume", "$cover", "$live", "$fair"}


def is_ff(t):
    return "dff" in t or "dlatch" in t or t in ("$ff", "$sr")


class Netlist:
    def __init__(self, path):
        mod = json.loads(Path(path).read_text())["modules"][TOP]
        self.nets = {n: v["bits"] for n, v in mod["netnames"].items()}
        self.inputs = {}  # bit -> port name
        for name, port in mod["ports"].items():
            if port["direction"] == "input":
                for b in port["bits"]:
                    if isinstance(b, int):
                        self.inputs[b] = name
        self.owner, self.inputs_of = [], []
        self.drv = defaultdict(list)  # bit -> [(cell index, dependency bits or None for all inputs)]
        self.state = []  # (cell index, type, name, output bits)
        self.src = {}
        for name, cell in mod["cells"].items():
            t = cell["type"]
            if t in NO_OUTPUT:
                continue
            if t in ("$memrd", "$memwr", "$meminit", "$memrd_v2", "$memwr_v2", "$meminit_v2"):
                raise RuntimeError(f"uncollected memory cell {name}")
            ci = len(self.owner)
            self.owner.append(owner_of(name, cell))
            conn, dirs = cell["connections"], cell["port_directions"]
            ins = [b for p, bits in conn.items() if dirs[p] == "input" for b in bits if isinstance(b, int)]
            self.inputs_of.append(ins)
            outs = {p: bits for p, bits in conn.items() if dirs[p] == "output"}
            prm = cell.get("parameters", {})
            if t in BIT2 or t in BIT1 or t in ("$mux", "$bwmux", "$pmux") or is_ff(t):
                self._bitwise(ci, t, conn, prm, outs)
            else:
                for bits in outs.values():
                    for b in bits:
                        if isinstance(b, int):
                            self.drv[b].append((ci, None))
            if is_ff(t) or t == "$mem_v2":
                q = outs.get("Q", outs.get("RD_DATA", []))
                self.state.append((ci, t, name, [b for b in q if isinstance(b, int)]))
                self.src[name] = cell.get("attributes", {}).get("src", "?").split("|")[0]

    def _bitwise(self, ci, t, conn, prm, outs):
        def ext(port, n, signed):
            bits = conn.get(port, [])
            if len(bits) >= n:
                return [[b] for b in bits[:n]]
            fill = [bits[-1]] if signed and bits else []
            return [[b] for b in bits] + [fill] * (n - len(bits))
        if is_ff(t):
            q = outs["Q"]
            per = [p for p in ("D", "AD", "SET", "CLR") if p in conn and len(conn[p]) == len(q)]
            common = [b for p, bits in conn.items() if p != "Q" and p not in per for b in bits]
            cols = [conn[p] for p in per]
            for i, b in enumerate(q):
                self._add(b, ci, [c[i] for c in cols] + common)
            return
        y = outs["Y"]
        n = len(y)
        if t in BIT1 or t in BIT2:
            sa = int(str(prm.get("A_SIGNED", "0")), 2) if isinstance(prm.get("A_SIGNED"), str) else int(prm.get("A_SIGNED", 0))
            cols = [ext("A", n, sa)]
            if t in BIT2:
                sb = int(str(prm.get("B_SIGNED", "0")), 2) if isinstance(prm.get("B_SIGNED"), str) else int(prm.get("B_SIGNED", 0))
                cols.append(ext("B", n, sb))
            for i, b in enumerate(y):
                self._add(b, ci, [x for c in cols for x in c[i]])
        elif t == "$mux":
            for i, b in enumerate(y):
                self._add(b, ci, [conn["A"][i], conn["B"][i]] + conn["S"])
        elif t == "$bwmux":
            for i, b in enumerate(y):
                self._add(b, ci, [conn["A"][i], conn["B"][i], conn["S"][i]])
        else:  # $pmux
            s = conn["S"]
            for i, b in enumerate(y):
                self._add(b, ci, [conn["A"][i]] + [conn["B"][k * n + i] for k in range(len(s))] + s)

    def _add(self, b, ci, deps):
        if isinstance(b, int):
            self.drv[b].append((ci, [d for d in deps if isinstance(d, int)]))

    def bits(self, name):
        if name not in self.nets:
            raise RuntimeError(f"net {name} not found in the flattened netlist")
        return [b for b in self.nets[name] if isinstance(b, int)]

    def name(self, b):
        """A readable name for bit b: the shortest public net name carrying it."""
        if not hasattr(self, "_names"):
            self._names = {}
            for n, bits in self.nets.items():
                if n.startswith("$"):
                    continue
                for i, x in enumerate(bits):
                    if isinstance(x, int):
                        cand = (n.count("."), len(n), f"{n}[{i}]" if len(bits) > 1 else n)
                        if x not in self._names or cand < self._names[x]:
                            self._names[x] = cand
        return self._names[b][2] if b in self._names else f"<bit {b}>"


class Labels:
    """Cut crossings, element bits and inputs, and the backward traversal."""

    def __init__(self, nl):
        self.nl = nl
        self.cut = defaultdict(list)  # bit -> [(instance, mode, label)]
        self.cut_bits, self.cut_inst, self.group, self.constant = {}, {}, {}, []
        for group, inst, mode, sigs in CUTS:
            for s in sigs:
                label = f"{group}.{s}"
                bits = nl.bits(f"{inst}.{s}")
                if not bits:  # tied off in this configuration (virt_i without KARU_H)
                    self.constant.append(label)
                self.cut_bits[label], self.cut_inst[label], self.group[label] = bits, (inst, mode), group
                for b in bits:
                    self.cut[b].append((inst, mode, label))
        self.elem = {}  # bit -> element
        self.elem_bits, self.elem_cells = {}, {}
        for e, spec in ELEMENTS.items():
            if "nets" in spec:
                bits = [b for n in spec["nets"] for b in nl.bits(f"{spec['owner']}.{n}")]
                cells = []
            else:
                cells = [(name, t, q) for ci, t, name, q in nl.state if inside(nl.owner[ci], spec["owner"])
                         and (spec.get("state") or name == f"{spec['owner']}.{spec['memory']}")
                         and name not in [f"{spec['owner']}.{m}" for m in spec.get("skip_memory", [])]]
                bits = [b for _, _, q in cells for b in q]
            if not bits:
                raise RuntimeError(f"element {e} has no bits")
            self.elem_bits[e], self.elem_cells[e] = bits, cells
            if not spec.get("stop", True):
                continue
            for b in bits:
                if b in self.elem:
                    raise RuntimeError(f"bit {b} in elements {self.elem[b]} and {e}")
                self.elem[b] = e

    def crossing(self, b, consumer, exclude):
        """Labels at which a backward step into bit b, from a cell owned by
        consumer, stops. Going backward, a path leaves the consumer's input
        port before it enters the producer's output port, so when one net is
        both, the input-port cut is the first crossing and is the one recorded."""
        found = [(mode, label) for inst, mode, label in self.cut.get(b, ())
                 if label not in exclude and (inside(consumer, inst) == (mode == "in"))]
        if found:
            first = [l for m, l in found if m == "in"] or [l for m, l in found]
            return first
        e = self.elem.get(b)
        if e is not None and e not in exclude:
            return [e]
        if b in self.nl.inputs:
            return ["in:" + self.nl.inputs[b]]
        return []

    def cone(self, start, ctx, exclude):
        """Frontier of a backward traversal from start bits consumed in instance
        ctx: {label: (bits reached, witness path)}. Labels in exclude are not stops."""
        nl, hits, seen, seen_cells, stack = self.nl, {}, {}, set(), []

        def visit(b, consumer, came):
            labels = self.crossing(b, consumer, exclude)
            if labels:
                for label in labels:
                    rec = hits.setdefault(label, [set(), (b, came)])
                    rec[0].add(b)
            elif b not in seen:
                seen[b] = came
                stack.append(b)
        for b in start:
            visit(b, ctx, None)
        while stack:
            b = stack.pop()
            for ci, deps in nl.drv.get(b, ()):
                if deps is None:
                    if ci in seen_cells:
                        continue
                    seen_cells.add(ci)
                    deps = nl.inputs_of[ci]
                own = nl.owner[ci]
                for d in deps:
                    visit(d, own, (b, ci))
        return {k: (len(bits), self.path(seen, end)) for k, (bits, end) in hits.items()}

    def path(self, seen, end):
        """Witness: the reached bit, then each bit back to the start, with the
        instance of the cell between them."""
        b, came = end
        steps = [self.nl.name(b)]
        while came is not None and len(steps) < 60:
            prev, ci = came
            steps.append(f"<{self.nl.owner[ci] or 'top'}> {self.nl.name(prev)}")
            came = seen.get(prev)
        return steps


def analyse(netlist_path):
    """Inventory and violations for one netlist."""
    t0 = time.monotonic()
    nl = Netlist(netlist_path)
    lab = Labels(nl)
    ports = set(nl.inputs.values())
    violations = []
    unclassified = sorted(ports - set(TRUSTED) - set(ADVERSARY))
    if unclassified:
        violations.append(("inputs", "unclassified top-level inputs", unclassified))
    stale_ports = sorted((set(TRUSTED) | set(ADVERSARY)) - ports)
    if stale_ports:
        violations.append(("inputs", "classified inputs absent from the netlist", stale_ports))
    inv = {"defines": DEFINES, "inputs": sorted(ports), "constant_cut_signals": lab.constant,
           "elements": {}, "drivers": {}, "cuts": {}}
    def frontier(f):
        return {k: {"bits": n, "witness": w} for k, (n, w) in sorted(f.items())}
    # 1. element frontiers
    for e, spec in ELEMENTS.items():
        f = lab.cone(lab.elem_bits[e], spec["owner"], {e})
        regs = sorted({name if t == "$mem_v2" else re.sub(r"\[\d+\]$", "", nl.name(q[0]))
                       if not nl.name(q[0]).startswith("<") else f"<{t} at {nl.src[name]}>"
                       for name, t, q in lab.elem_cells[e] if q})
        inv["elements"][e] = {"owner": spec["owner"], "bits": len(lab.elem_bits[e]),
                              "registers": regs or spec.get("nets"), "frontier": frontier(f)}
    # 2. untrusted side of each cut signal of the checked groups, and of
    #    every cut group as a whole (for the inventory)
    for label, (inst, mode) in lab.cut_inst.items():
        if lab.group[label] in CHECKED_DRIVERS and label not in lab.constant:
            inv["drivers"][label] = frontier(lab.cone(lab.cut_bits[label], inst, {label}))
    for group, inst, mode, sigs in CUTS:
        own = {f"{group}.{s}" for s in sigs}
        start = [b for s in own for b in lab.cut_bits[s]]
        inv["cuts"][group] = {"instance": inst, "mode": mode, "signals": sorted(own),
                              "frontier": frontier(lab.cone(start, inst, own))}
    # 3. checks against the allowlists
    def compare(kind, key, front, allow):
        got = {k for k in front if not (k.startswith("in:") and k[3:] in TRUSTED)}
        want = set(allow)
        for k in sorted(got - want):
            violations.append((kind, key, f"new path: {k}", " <- ".join(reversed(front[k]["witness"]))))
        for k in sorted(want - got):
            violations.append((kind, key, f"stale allowlist entry: {k}", ""))
    for e in ELEMENTS:
        compare("element", e, inv["elements"][e]["frontier"], ALLOW_ELEMENTS.get(e, {}))
    for label, f in inv["drivers"].items():
        compare("driver", label, f, ALLOW_DRIVERS.get(label, {}))
    for e in ALLOW_ELEMENTS:
        if e not in ELEMENTS:
            violations.append(("element", e, "allowlisted element not defined"))
    for label in ALLOW_DRIVERS:
        if label not in inv["drivers"]:
            violations.append(("driver", label, "allowlisted cut signal not defined"))
    inv["closure"] = closure(inv)
    inv["seconds"] = round(time.monotonic() - t0, 1)
    return inv, violations


def closure(inv):
    """Adversary inputs that reach each element, by the first crossing
    (frontier entry) they pass on the way."""
    src = {}
    for e, rec in inv["elements"].items():
        src[e] = set(rec["frontier"])
    for g, rec in inv["cuts"].items():
        src[g] = set(rec["frontier"])

    def node(k):
        if k.startswith("in:"):
            return k
        return k.rsplit(".", 1)[0] if k.rsplit(".", 1)[0] in inv["cuts"] else k
    reach = {k: set() for k in src}
    changed = True
    while changed:
        changed = False
        for k, ss in src.items():
            new = set(reach[k])
            for s in ss:
                n = node(s)
                if n.startswith("in:"):
                    if n[3:] in ADVERSARY:
                        new.add(n[3:])
                else:
                    new |= reach.get(n, set())
            if new != reach[k]:
                reach[k], changed = new, True
    out = {}
    for e, rec in inv["elements"].items():
        via = {}
        for s in rec["frontier"]:
            n = node(s)
            if n.startswith("in:"):
                if n[3:] in ADVERSARY:
                    via[s] = [n[3:]]
            else:
                via[s] = sorted(reach.get(n, set()))
        out[e] = via
    return out


def write_report(inv, violations, out):
    out.mkdir(parents=True, exist_ok=True)
    inv = dict(inv, violations=[list(v) for v in violations])
    (out / "inventory.json").write_text(json.dumps(inv, indent=1) + "\n")
    lines = [f"C1 bypass-freedom inventory, karudbg_top with {' '.join(DEFINES)}", ""]
    for e, rec in inv["elements"].items():
        lines.append(f"element {e} ({rec['owner']}, {rec['bits']} bits)")
        for s, r in rec["frontier"].items():
            why = ALLOW_ELEMENTS.get(e, {}).get(s)
            tag = ("trusted input" if s.startswith("in:") and s[3:] in TRUSTED else
                   why if why else "NOT ALLOWLISTED")
            lines.append(f"  <- {s:30s} {r['bits']:4d} bits  {tag}")
            reach = inv["closure"][e].get(s)
            if reach is not None and not s.startswith("in:"):
                group = s.rsplit(".", 1)[0] if s.rsplit(".", 1)[0] in inv["cuts"] else None
                src = inv["cuts"][group]["frontier"] if group else inv["elements"][s]["frontier"]
                first = [k[3:] for k in src if k.startswith("in:") and k[3:] in ADVERSARY]
                missing = sorted({p for p in ADVERSARY if p in inv["inputs"]} - set(reach))
                lines.append(f"       adversary inputs at {group or s}'s own first crossing: "
                             f"{', '.join(first) or 'none'}; behind it in all: "
                             + (f"all except {', '.join(missing) or 'none'}" if len(missing) < 4
                                else ", ".join(reach) or "none"))
        lines.append("")
    lines.append("untrusted side of each K2 and K3.hart signal, traced back to H (the hart's own ports)")
    for label, f in inv["drivers"].items():
        lines.append(f"  {label:28s} <- {', '.join(f)}")
    lines.append("")
    lines.append("first crossings behind each cut group (informational, not checked)")
    for g, rec in inv["cuts"].items():
        lines.append(f"  {g} ({rec['instance']}, {rec['mode']}) <- {', '.join(rec['frontier'])}")
    if inv["constant_cut_signals"]:
        lines.append(f"  constant in this configuration: {', '.join(inv['constant_cut_signals'])}")
    lines.append("")
    lines.append("violations: " + ("none" if not violations else str(len(violations))))
    for v in violations:
        lines.append("  " + " | ".join(str(x) for x in v if x))
    (out / "inventory.txt").write_text("\n".join(lines) + "\n")


def mutate(name, path, edits, work):
    """Copy of repository file path with the edits applied, in work."""
    text = (ROOT / path).read_text()
    for before, after in edits:
        if text.count(before) != 1:
            raise RuntimeError(f"mutant {name}: site not unique in {path}: {before!r}")
        text = text.replace(before, after)
    work.mkdir(parents=True, exist_ok=True)
    copy = work / Path(path).name
    copy.write_text(text)
    return {path: copy}


def job(work, overrides=None, netlist=None):
    """Elaborate (unless a netlist is given) and analyse; runs in a worker process."""
    path = netlist or elaborate(work, overrides)
    inv, violations = analyse(path)
    write_report(inv, violations, work)
    if overrides:
        path.unlink()  # 170 MB per mutant; the design's netlist is kept for --netlist
    return violations, inv["seconds"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="_build/dbg/auth-bypass")
    parser.add_argument("--netlist", help="analyse an existing JSON netlist instead of elaborating")
    parser.add_argument("--self-test", action="store_true", help="also run the negative controls")
    parser.add_argument("--jobs", type=int, default=len(MUTANTS) + 1,
                        help="parallel elaborations (each up to about 1.1 GB)")
    parser.add_argument("--defines", help="space-separated defines replacing DEFINES (exploration "
                        "only: the allowlists are written for DEFINES)")
    parser.add_argument("--image", action="store_true",
                        help="the VCU118 debug image's defines and parameters (IMAGE_DEFINES, IMAGE_PARAMS) in "
                             "place of DEFINES, with the allowlist entries that H and Zkr add")
    parser.add_argument("--island-rom", help="with --image: a hex image for the island ROM (ISLAND_ROM_HEX). Not "
                                             "the image's own, which holds the authentication key")
    args = parser.parse_args()
    if args.defines:
        DEFINES[:] = args.defines.split()
    if args.image:
        DEFINES[:] = IMAGE_DEFINES
        PARAMS.update(IMAGE_PARAMS)
        if args.island_rom:
            rom = Path(args.island_rom).resolve()
            if not rom.is_file(): sys.exit(f"--island-rom: no file {rom}")
            PARAMS["ISLAND_ROM_HEX"] = f'"{rom}"'
        image_allowances()
    out = (ROOT / args.out).resolve()
    t0 = time.monotonic()
    runs = {"design": (out, None, args.netlist and Path(args.netlist).resolve())}
    if args.self_test:
        for name, path, edits, _ in MUTANTS:
            work = out / "mutants" / name
            runs[name] = (work, mutate(name, path, edits, work), None)
    with ProcessPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {name: pool.submit(job, *spec) for name, spec in runs.items()}
        results = {name: f.result() for name, f in futures.items()}
    violations, secs = results["design"]
    for v in violations:
        print("FAIL C1 " + " | ".join(str(x) for x in v[:3]) + (f"\n    witness: {v[3]}" if v[3] else ""))
    ok = not violations
    print(f"{'PASS' if ok else 'FAIL'} C1 bypass freedom: {len(ELEMENTS)} protected elements, "
          f"{sum(len(c[3]) for c in CUTS)} cut signals, {sum(map(len, ALLOW_ELEMENTS.values()))} "
          f"allowlisted element paths, {len(ALLOW_DRIVERS)} cut-signal drivers; "
          f"inventory {out / 'inventory.txt'}", flush=True)
    for name, path, edits, (kind, key, text) in MUTANTS if args.self_test else []:
        got, _ = results[name]
        hit = [v for v in got if v[0] == kind and v[1] == key and text in v[2]]
        ok = ok and bool(hit)
        if hit:
            print(f"detected C1 mutant {name}: {kind} {key}: {hit[0][2]}\n    witness: {hit[0][3] or '-'}")
        else:
            print(f"NOT DETECTED C1 mutant {name}: expected {kind} {key} '{text}', got "
                  + ("; ".join(" | ".join(v[:3]) for v in got[:3]) or "no violation"))
    print(f"C1 run time {round(time.monotonic() - t0)} s", flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

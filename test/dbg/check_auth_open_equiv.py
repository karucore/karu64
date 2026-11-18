#!/usr/bin/env python3
"""Prove karudbg with KARU_DBG_AUTH and lc=OPEN equivalent to karudbg without it.

Contract section 7 (doc/debug-auth-contract.md): with the authentication gate
tied open (debug_enable_i=1, lc_auth_i=0, authbusy_i=0), the DM's DMI
responses, hart-facing debug page and all outputs must match today's DM cycle
for cycle from reset. The proof is a Yosys sequential equivalence
(equiv_make/equiv_induct) between the two flattened designs; both reset to the
same state through the shared synchronous rst input.
"""
# SPDX-License-Identifier: BSD-2-Clause
import argparse
from pathlib import Path
import subprocess
import sys

WRAPPER = """
module karudbg_open_gate (
    input wire clk, input wire rst, input wire dmi_reset_i,
    input wire req_valid_i, output wire req_ready_o,
    input wire [6:0] req_addr_i, input wire [1:0] req_op_i, input wire [31:0] req_data_i,
    output wire resp_valid_o, input wire resp_ready_i,
    output wire [31:0] resp_data_o, output wire [1:0] resp_op_o,
    output wire halt_req_o, output wire resume_req_o, output wire resume_authorized_o,
    output wire ndmreset_o,
    input wire hart_halted_i, input wire hart_resume_ack_i,
    input wire hart_unavailable_i, input wire hart_reset_i,
    input wire mem_req_i, input wire mem_write_i, input wire [11:0] mem_addr_i,
    input wire [63:0] mem_wdata_i, input wire [7:0] mem_be_i,
    output wire [63:0] mem_rdata_o, output wire mem_ready_o, output wire mem_error_o,
    output wire sba_req_valid_o, input wire sba_req_ready_i,
    output wire [63:0] sba_req_addr_o, output wire [63:0] sba_req_data_o,
    output wire [2:0] sba_req_size_o, output wire sba_req_write_o,
    input wire sba_resp_valid_i, output wire sba_resp_ready_o,
    input wire [63:0] sba_resp_data_i, input wire [2:0] sba_resp_error_i);
    wire unused_valid, unused_write, unused_active;
    wire [31:0] unused_wdata;
    karudbg dm (.*, .debug_enable_i(1'b1), .debug_enable_next_i(1'b1), .lc_auth_i(1'b0),
        .auth_valid_o(unused_valid), .auth_write_o(unused_write),
        .auth_wdata_o(unused_wdata), .auth_rdata_i(32'b0), .authbusy_i(1'b0),
        .dmactive_o(unused_active));
endmodule
"""
# The gold side is wrapped identically, so flattened state names (dm.*) match
# and equiv_induct can use the register correspondence.
GOLD_WRAPPER = WRAPPER.replace("karudbg_open_gate", "karudbg_open_gold").replace(
    """karudbg dm (.*, .debug_enable_i(1'b1), .debug_enable_next_i(1'b1), .lc_auth_i(1'b0),
        .auth_valid_o(unused_valid), .auth_write_o(unused_write),
        .auth_wdata_o(unused_wdata), .auth_rdata_i(32'b0), .authbusy_i(1'b0),
        .dmactive_o(unused_active));""",
    """karudbg dm (.*);
    assign {unused_valid, unused_write, unused_wdata, unused_active} = 35'b0;""").replace(
    "unused_", "goldonly_")


def run(repo, out, defines, sources, mutate):
    out.mkdir(parents=True, exist_ok=True)
    gate_src = []
    for src in sources:
        text = (repo / src).read_text()
        if mutate and src.name == "karudbg.v":
            # Mutant control: let the locked view leak into OPEN by ignoring
            # the gate on halt_req_o; the proof must fail.
            needle = "assign halt_req_o = dmactive_q && halt_q && dbg_en;"
            if needle not in text:
                sys.exit("check_auth_open_equiv: mutation did not apply")
            text = text.replace(needle, "assign halt_req_o = dmactive_q && halt_q && auth_impl;")
        dst = out / ("gate_" + src.name)
        dst.write_text(text)
        gate_src.append(dst)
    (out / "wrapper.v").write_text(WRAPPER)
    (out / "gold_wrapper.v").write_text(GOLD_WRAPPER)
    flags = " ".join("-D" + d for d in defines)
    gold = " ".join(str(repo / s) for s in sources)
    gate = " ".join(map(str, gate_src))
    script = f"""
read_verilog -I{repo}/dbg {flags} {gold}
read_verilog -sv {out}/gold_wrapper.v
hierarchy -check -top karudbg_open_gold
proc; flatten; memory_map; opt_clean
rename karudbg_open_gold gold
design -stash gold
read_verilog -I{repo}/dbg {flags} -DKARU_DBG_AUTH {gate}
read_verilog -sv {out}/wrapper.v
hierarchy -check -top karudbg_open_gate
proc; flatten; memory_map; opt_clean
rename karudbg_open_gate gate
design -stash gate
design -copy-from gold -as gold gold
design -copy-from gate -as gate gate
equiv_make gold gate equiv
hierarchy -top equiv
async2sync
equiv_simple -seq 4
equiv_induct -seq 4
equiv_status
equiv_status -assert
"""
    (out / "equiv.ys").write_text(script)
    result = subprocess.run(["yosys", "-q", "-l", str(out / "yosys.log"), str(out / "equiv.ys")],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mutate", action="store_true")
    parser.add_argument("-D", dest="defines", action="append", default=[])
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    sources = [Path("dbg/karudbg.v"), Path("dbg/karudbg_rom.v"), Path("dbg/karudbg_sba.v")]
    ok = run(repo, Path(args.out), args.defines, sources, args.mutate)
    label = "+".join(args.defines) or "base"
    if args.mutate:
        print(f"{'FAIL' if ok else 'PASS'} OPEN-equivalence mutant {'NOT ' if ok else ''}detected ({label})")
        sys.exit(1 if ok else 0)
    print(f"{'PASS' if ok else 'FAIL'} karudbg KARU_DBG_AUTH lc=OPEN equivalence ({label}); log {args.out}/yosys.log")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

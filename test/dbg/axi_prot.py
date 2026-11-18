#!/usr/bin/env python3
"""Bounded AXI protection regression, reusing the maintained unit benches.

Run both static security domains and deliberately corrupt one propagation
stage at a time. All generated sources, executables and logs stay in _build.
No Git state is modified. A successful unit matrix is not board evidence.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
RAM = "rtl/karu_ram_prim.v"
BENCHES = {
    "ifu": ("tb_ifu", ["test/tb_ifu.sv", "rtl/karu_ifu.v"], "IFU PASS"),
    "lsu": ("tb_lsu_atomic", ["test/tb_lsu_atomic.sv", "rtl/karu_lsu.v"], "LSU_ATOMIC_PASS"),
    "icache": ("tb_icache", ["test/tb_icache.sv", "rtl/karu_icache.v", RAM], "[ICACHE] ALL PASS"),
    "mem": ("tb_mem_stream", ["test/tb_mem_stream.sv", "rtl/karu_mem.v", RAM], "[MEM-STREAM] ALL PASS"),
    "sv39": ("karu_sv39_tb", ["test/karu_sv39_tb.v", "rtl/karu_sv39.v", RAM], "SV39-SVADE-SVNAPOT-SVPBMT-H PASS"),
}
# Each mutation removes real propagation, rather than corrupting a checker.
MUTATIONS = {
    "ifu": ("rtl/karu_ifu.v", "arprot  <= fetch_prot;", "arprot  <= 0;", "AXI request:"),
    "lsu": ("rtl/karu_lsu.v", "awprot  <= prot_q;", "awprot  <= 0;", "LSU AW protection lost"),
    "icache": ("rtl/karu_icache.v", "m_arprot <= prot_q;", "m_arprot <= 0;", "I-cache lost protection"),
    "mem": ("rtl/karu_mem.v", "req_prot<=vq_prot;", "req_prot<=0;", "D-cache AW lost issue/queue context"),
    "sv39": ("rtl/karu_sv39.v", "arprot <= {1'b0, (NONSECURE != 0), 1'b1};", "arprot <= 0;", "PTE read is not privileged data"),
}


def run_case(case, out, debug):
    name, kind, domain, negative = case
    top, sources, success = BENCHES[kind]
    directory = out / name
    directory.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    commands = []
    sources = list(sources)
    if negative:
        original, before, after, diagnostic = MUTATIONS[kind]
        text = (ROOT / original).read_text()
        if before not in text:
            raise RuntimeError(f"mutation site changed: {original}: {before}")
        changed = directory / Path(original).name
        changed.write_text(text.replace(before, after))
        sources[sources.index(original)] = str(changed)
    compile_cmd = ["iverilog", "-g2012", "-Irtl", "-s", top, "-o", str(directory / "sim.vvp")]
    if debug:
        compile_cmd += ["-Idbg", "-DKARU_DBG"]
    if domain is not None:
        compile_cmd += [f"-P{top}.NONSECURE={domain}"]
    compile_cmd += sources
    commands.append(compile_cmd)
    build = subprocess.run(compile_cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=60)
    log = "$ " + shlex.join(compile_cmd) + "\n" + build.stdout
    passed = False
    if build.returncode == 0:
        sim_cmd = ["vvp", str(directory / "sim.vvp")]
        commands.append(sim_cmd)
        sim = subprocess.run(sim_cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=120)
        log += "$ " + shlex.join(sim_cmd) + "\n" + sim.stdout
        if negative:
            passed = sim.returncode != 0 and diagnostic in sim.stdout
        else:
            passed = sim.returncode == 0 and success in sim.stdout
    (directory / "run.log").write_text(log)
    return {"name": name, "passed": passed, "negative_control": negative,
            "seconds": round(time.monotonic() - start, 3),
            "log": str(directory / "run.log"), "commands": commands}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="_build/dbg/axi-prot")
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--debug", action="store_true", help="repeat propagation checks with KARU_DBG enabled")
    parser.add_argument("--skip-xbar", action="store_true", help="leaf-only diagnostic run")
    args = parser.parse_args()
    out = (ROOT / args.build_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    sources = sorted({source for _, source_list, _ in BENCHES.values() for source in source_list}
                     | {"test/dbg/axi_prot.py", "dbg/axi.mk"}
                     | {str(path.relative_to(ROOT)) for path in (ROOT / "rtl").glob("*.vh")})
    def hashes():
        return {source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest() for source in sources}
    before = hashes()
    cases = []
    for kind in BENCHES:
        for domain in ([None] if kind == "icache" else [0, 1]):
            cases.append((f"{kind}-" + ("mixed-domains" if domain is None else f"domain{domain}"), kind, domain, False))
        cases.append((f"{kind}-negative", kind, None if kind == "icache" else 1, True))
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
        futures = {executor.submit(run_case, case, out, args.debug): case[0] for case in cases}
        for future in concurrent.futures.as_completed(futures):
            try:
                result = future.result()
            except Exception as error:
                result = {"name": futures[future], "passed": False, "error": str(error)}
            results.append(result)
            print(f"{'PASS' if result['passed'] else 'FAIL'} {result['name']}", flush=True)
    if not args.skip_xbar:
        directory = out / "xbar"
        directory.mkdir(exist_ok=True)
        cmd = ["make", "axi-ddr-hold-test", f"BUILD={directory}"]
        start = time.monotonic()
        try:
            completed = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, timeout=180)
            (directory / "run.log").write_text("$ " + shlex.join(cmd) + "\n" + completed.stdout)
            passed = completed.returncode == 0 and "[AXI-DDR] ALL PASS" in completed.stdout
            result = {"name": "ddr-xbar", "passed": passed, "log": str(directory / "run.log"),
                      "commands": [cmd], "seconds": round(time.monotonic() - start, 3)}
        except subprocess.TimeoutExpired:
            result = {"name": "ddr-xbar", "passed": False, "error": "180-second bound exceeded"}
        results.append(result)
        print(f"{'PASS' if result['passed'] else 'FAIL'} ddr-xbar", flush=True)
    after = hashes()
    if after != before:
        results.append({"name": "source-integrity", "passed": False,
                        "error": "test inputs changed while the matrix was running"})
    tools = {}
    for tool, version_arg in [("iverilog", "-V"), ("vvp", "-V"), ("verilator", "--version")]:
        path = Path(shutil.which(tool)).resolve()
        version = subprocess.run([str(path), version_arg], text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=10).stdout.splitlines()[0]
        tools[tool] = {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                       "version": version}
    record = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "debug": args.debug,
              "tools": tools,
              "source_sha256": before, "source_sha256_after": after,
              "results": sorted(results, key=lambda result: result["name"])}
    (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    count = sum(result["passed"] for result in results)
    print(f"AXI_PROT {'PASS' if count == len(results) else 'FAIL'} {count}/{len(results)}; {out / 'results.json'}")
    return 0 if count == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

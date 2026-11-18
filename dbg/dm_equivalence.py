"""Small-module sequential equivalence for AUTOEXEC=0 mapping reuse.

The proof elaborates actual row defaults, rather than forcing a parameter that
might differ from the mapped instance. No assumption is made about reset or
other inputs. Failed or unproven equivalence is never a waiver.
"""
# SPDX-License-Identifier: BSD-2-Clause
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def environment_envelope(text):
    # Conservative: retain every physical line containing a macro/directive
    # marker or a possible synthesis pragma, even in a literal/plain comment.
    # Extra conservatism can reject a harmless edit, never hide a compiler-
    # directive change crossing the proved module's boundary.
    hot = re.compile(r"synthesis|synopsys|yosys|pragma|translate_off|translate_on|full_case|parallel_case", re.I)
    return [line for line in text.splitlines() if "`" in line or hot.search(line)]


def script_text(repo, defines, old_sources, current_sources, out):
    flags = " ".join("-D" + word for word in defines)
    def design(sources, tag):
        return [f"read_verilog -defer -I{repo}/rtl -I{repo}/dbg {flags} " + " ".join(map(str, sources)),
                "hierarchy -check -top karudbg", "proc", "flatten", "memory_map", "opt", "check",
                f"write_json {out}/{tag}.json", f"rename karudbg {tag}", f"design -stash {tag}"]
    commands = design(old_sources, "gold") + ["design -reset"] + design(current_sources, "gate")
    commands += ["design -reset", "design -copy-from gold -as gold gold", "design -copy-from gate -as gate gate",
                 "equiv_make gold gate equiv", "hierarchy -top equiv", "equiv_simple", "equiv_induct -seq 4",
                 "equiv_status -assert"]
    return "\n".join(commands) + "\n"


def execute(repo, defines, old_sources, current_sources, old_dm, current_dm, out, file_record):
    if "KARU_DBG_AUTOEXEC" in defines or "KARU_DBG_FULL" in defines:
        raise ValueError("AUTOEXEC=0 proof cannot cover an enabled autoexec row")
    if environment_envelope(old_dm.read_text()) != environment_envelope(current_dm.read_text()):
        raise ValueError("DM compiler directive/pragma environment changed")
    out.mkdir(parents=True, exist_ok=True)
    tool = Path(shutil.which("yosys")).resolve()
    script, log = out / "equiv.ys", out / "equiv.log"
    script.write_text(script_text(repo, defines, old_sources, current_sources, out))
    with log.open("w") as stream:
        result = subprocess.run([str(tool), "-Q", "-T", "-s", str(script)], cwd=repo,
                                stdout=stream, stderr=subprocess.STDOUT, timeout=120)
    if result.returncode or "Equivalence successfully proven!" not in log.read_text():
        raise ValueError("AUTOEXEC=0 DM equivalence failed: " + str(log))
    expected_sba = 1 if "KARU_DBG_SBA" in defines else 0
    designs = [json.loads((out / (tag + ".json")).read_text())["modules"]["karudbg"] for tag in ("gold", "gate")]
    for design in designs:
        params = design.get("parameter_default_values", {})
        if int(params.get("AUTOEXEC", "1"), 2) != 0 or int(params.get("SBA", "-1"), 2) != expected_sba:
            raise ValueError("actual elaborated DM defaults are not AUTOEXEC=0/SBA=" + str(expected_sba))
    ports = [{name: (port["direction"], len(port["bits"])) for name, port in design["ports"].items()} for design in designs]
    if ports[0] != ports[1]:
        raise ValueError("DM port contract changed")
    return {"method": "Yosys equiv_make/equiv_simple/equiv_induct/equiv_status -assert",
            "parameters": {"AUTOEXEC": 0, "SBA": expected_sba}, "yosys": file_record(tool),
            "command": [str(tool), "-Q", "-T", "-s", str(script)],
            "script": file_record(script), "log": file_record(log),
            "gold": file_record(out / "gold.json"), "gate": file_record(out / "gate.json")}


def verify(record, repo, defines, old_sources, current_sources, old_dm, current_dm, out, file_record):
    tool = Path(shutil.which("yosys")).resolve()
    expected = script_text(repo, defines, old_sources, current_sources, out)
    if record["yosys"] != file_record(tool) or Path(record["script"]["path"]) != out / "equiv.ys":
        raise ValueError("DM proof tool or script scope changed")
    if (out / "equiv.ys").read_text() != expected:
        raise ValueError("DM proof script is not the exact recorded-row derivation")
    for key, name in (("script", "equiv.ys"), ("log", "equiv.log"), ("gold", "gold.json"), ("gate", "gate.json")):
        if record[key] != file_record(out / name):
            raise ValueError("DM proof artifact changed: " + key)
    with tempfile.TemporaryDirectory(prefix="dm-verify-", dir=out.parent) as temporary:
        actual = execute(repo, defines, old_sources, current_sources, old_dm, current_dm, Path(temporary), file_record)
    if actual["parameters"] != record["parameters"]:
        raise ValueError("DM proof parameter scope changed")

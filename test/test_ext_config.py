#!/usr/bin/env python3
"""RVA23S64 build-composition regression.

Run: python3 test/test_ext_config.py
Requires Icarus Verilog (preprocess/elaborate/run) and Verilator (preprocess,
including explicit diagnostics for conflicting profile inputs). No core model
is built and no architectural/platform certification is inferred.
Yosys additionally checks the core's constant geometry guard, as do both
simulators, in plain Verilog mode matching the FPGA source reader. The exact
marked guard is read from karu64.v, not reimplemented.
"""

import itertools
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "test/tb_ext_config.sv"
BASE = set("C A M B F D V S HPM MEM ZVBB ZVKB".split())
PROFILE = BASE | {"H", "SSTATEEN", "SSCOFPMF"}
CRYPTO = set("ZVK ZVKNED ZVKNHA ZVKNHB ZVKSED ZVKSH ZVKG".split())
CONFLICTS = "C A M B F D V ZVBB S HPM".split()


def command(arguments, success=True):
    result = subprocess.run(arguments, text=True, capture_output=True, timeout=30)
    if (result.returncode == 0) != success:
        raise AssertionError(f"Unexpected status {result.returncode}: {arguments}\n"
                             f"{result.stdout}{result.stderr}")
    return result


def probe(defines, include, directory, expected=None):
    flags = [f"-D{define}" for define in defines]
    prefix = ["iverilog", "-g2012", f"-I{include}", *flags]
    preprocessed = command([*prefix, "-E", "-o", "-", str(BENCH)]).stdout
    if expected is not None:
        found = set(re.findall(r'\$display\("EXT ([A-Z0-9_]+)"\)', preprocessed))
        assert found == expected, (defines, "preprocess", found, expected)
        verilated = command(["verilator", "-E", f"-I{include}", *flags, str(BENCH)]).stdout
        found = set(re.findall(r'\$display\("EXT ([A-Z0-9_]+)"\)', verilated))
        assert found == expected, (defines, "Verilator preprocess", found, expected)
        output = directory / "probe.vvp"
        command([*prefix, "-s", "tb_ext_config", "-o", str(output), str(BENCH)])
        simulated = command(["vvp", str(output)]).stdout
        found = set(re.findall(r"^EXT ([A-Z0-9_]+)$", simulated, re.MULTILINE))
        assert found == expected, (defines, "elaboration", found, expected)
        assert "EXT_CONFIG_PASS" in simulated
def main():
    for tool in ("iverilog", "vvp", "verilator", "yosys"):
        if not shutil.which(tool):
            raise SystemExit(f"missing prerequisite: {tool}")
    # New ISA opt-outs must be deliberately classified by this contract.
    configured_optouts = set(re.findall(r"\bKARU_NO_[A-Z0-9_]+\b",
                                       (ROOT / "rtl/karu_ext.vh").read_text()))
    assert configured_optouts == {f"KARU_NO_{name}" for name in CONFLICTS} | {"KARU_NO_MEM"}
    rows = [([], BASE)]
    drops = {
        "C": {"C"}, "A": {"A"}, "M": {"M"}, "B": {"B"},
        "F": {"F", "D", "V", "ZVBB", "ZVKB"},
        "D": {"D", "V", "ZVBB", "ZVKB"},
        "V": {"V", "ZVBB", "ZVKB"}, "S": {"S"},
        "ZVBB": {"ZVBB", "ZVKB"}, "HPM": {"HPM"},
    }
    for name, removed in drops.items():
        rows.append(([f"KARU_NO_{name}"], BASE - removed))
    rows += [
        (["KARU_NO_MEM"], BASE),
        (["KARU_NO_V", "KARU_NO_MEM"], BASE - {"V", "ZVBB", "ZVKB", "MEM"}),
        (["KARU_NO_F", "KARU_NO_MEM", "KARU_NO_S", "KARU_NO_HPM"],
         {"C", "A", "M", "B"}),
        (["KARU_H"], BASE | {"H", "SSTATEEN"}),
        (["KARU_SSTATEEN"], BASE | {"SSTATEEN"}),
        (["KARU_NO_S", "KARU_SSTATEEN"], BASE - {"S"}),
        (["KARU_SSCOFPMF"], BASE | {"SSCOFPMF"}),
        (["KARU_NO_HPM", "KARU_SSCOFPMF"], BASE - {"HPM"}),
        (["KARU_SMCNTRPMF"], BASE | {"SMCNTRPMF"}),
        (["KARU_ZVK"], BASE | CRYPTO),
        (["KARU_KECCAK"], BASE | {"KECCAK"}),
        (["KARU_NO_V", "KARU_ZVK", "KARU_KECCAK"], BASE - {"V", "ZVBB", "ZVKB"}),
        (["KARU_NO_ZVBB", "KARU_ZVKB"], BASE - {"ZVBB"}),
        (["KARU_ZVK", "KARU_KECCAK", "KARU_SSCOFPMF", "KARU_SMCNTRPMF"],
         BASE | CRYPTO | {"KECCAK", "SSCOFPMF", "SMCNTRPMF"}),
    ]
    with tempfile.TemporaryDirectory(prefix="karu-ext-config-") as temporary:
        directory = Path(temporary)
        for defines, expected in rows:
            probe(defines, ROOT / "rtl", directory, expected)
        profile_rows = 0
        # Every combination of the independent optional families must remain
        # explicitly selected; the profile must neither remove nor force one.
        for crypto, keccak, filtering in itertools.product((False, True), repeat=3):
            defines = ["KARU_RVA23S64"]
            expected = PROFILE.copy()
            if crypto:
                defines.append("KARU_ZVK")
                expected |= CRYPTO
            if keccak:
                defines.append("KARU_KECCAK")
                expected.add("KECCAK")
            if filtering:
                defines.append("KARU_SMCNTRPMF")
                expected.add("SMCNTRPMF")
            probe(defines, ROOT / "rtl", directory, expected)
            profile_rows += 1
        for extra in (["KARU_NO_MEM"], ["KARU_H", "KARU_SSTATEEN", "KARU_SSCOFPMF"]):
            probe(["KARU_RVA23S64", *extra], ROOT / "rtl", directory, PROFILE)
            profile_rows += 1
        for conflict in CONFLICTS:
            define = f"KARU_NO_{conflict}"
            flags = ["-DKARU_RVA23S64", f"-D{define}"]
            result = command(["verilator", "-E", f"-I{ROOT / 'rtl'}", *flags,
                              str(BENCH)], success=False)
            assert f"KARU_RVA23S64 conflicts with {define}" in result.stderr
            command(["iverilog", "-g2012", f"-I{ROOT / 'rtl'}", *flags,
                     "-s", "tb_ext_config", "-o", str(directory / "bad.vvp"),
                     str(BENCH)], success=False)
        # Existing non-profile invalid H/no-S composition must still fail.
        command(["verilator", "-E", f"-I{ROOT / 'rtl'}", "-DKARU_H", "-DKARU_NO_S",
                 str(BENCH)], success=False)
        # Use the actual core guard in a plain-Verilog elaboration shell.
        # RV64/RESET_PC width is structural, not a configurable parameter.
        core = (ROOT / "rtl/karu64.v").read_text()
        assert re.search(r"parameter\s+\[63:0\]\s+RESET_PC\s*=", core)
        begin = "// KARU_PROFILE_GEOMETRY_BEGIN"
        end = "// KARU_PROFILE_GEOMETRY_END"
        assert core.count(begin) == core.count(end) == 1
        guard = core.split(begin, 1)[1].split(end, 1)[0]
        geometry = directory / "geometry.v"
        geometry.write_text('`include "karu_vcfg.vh"\n'
                            'module geometry;\n'
                            'parameter [63:0] RESET_PC = 0;\n'
                            + guard + '\nendmodule\n')
        geometry_rows = [
            ([], True),
            (["KARU_RVA23S64"], True),
            (["KARU_RVA23S64", "KARU_VLEN=256", "KARU_ELEN=64", "KARU_VBUS_W=128"], True),
        ]
        for setting in ("KARU_VLEN=128", "KARU_VLEN=512", "KARU_ELEN=32",
                        "KARU_ELEN=128", "KARU_VBUS_W=64", "KARU_VBUS_W=256"):
            geometry_rows += [(["KARU_RVA23S64", setting], False), ([setting], True)]
        error_module = "KARU_RVA23S64_requires_RV64_VLEN256_ELEN64_VBUS128"
        for defines, valid in geometry_rows:
            flags = [f"-D{define}" for define in defines]
            commands = [
                ["iverilog", "-g2005", f"-I{ROOT / 'rtl'}", *flags, "-s", "geometry",
                 "-o", str(directory / "geometry.vvp"), str(geometry)],
                ["verilator", "--lint-only", "--language", "1364-2005", "--top-module", "geometry",
                 f"-I{ROOT / 'rtl'}", *flags, str(geometry)],
                ["yosys", "-Q", "-T", "-p",
                 'read_verilog -I' + str(ROOT / "rtl") + ' ' + ' '.join(flags)
                 + ' ' + str(geometry)
                 + '; hierarchy -check -top geometry; select -assert-none t:*; stat'],
            ]
            for arguments in commands:
                result = command(arguments, success=valid)
                if not valid:
                    assert error_module in result.stdout + result.stderr, (defines, arguments)
            # Yosys select -assert-none above proves the accepted branch has
            # no cells, not a dormant check (stat omits completely empty tops).
        for conflict in CONFLICTS:
            command(["yosys", "-Q", "-T", "-p",
                     'read_verilog -I' + str(ROOT / "rtl")
                     + ' -DKARU_RVA23S64 -DKARU_NO_' + conflict + ' ' + str(geometry)
                     + '; hierarchy -check -top geometry'], success=False)
    print(f"EXT_CONFIG_PASS baseline={len(rows)} profile={profile_rows} "
          f"conflicts={len(CONFLICTS)} existing_invalid=1 geometry={len(geometry_rows)}x3")


if __name__ == "__main__":
    main()

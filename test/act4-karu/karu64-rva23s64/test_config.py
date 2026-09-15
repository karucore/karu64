#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Isolated profile configuration, provenance and CSR-mask checks (no model build)."""

import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest

from ruamel.yaml import YAML


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent
ROOT = SOURCE.parents[1]
YAML_READER = YAML(typ="safe", pure=True)
REQUIRED = set("""
I M A F D C B V Zicsr Zicntr Zihpm Ziccif Ziccrse Ziccamoa Zicclsm
Za64rs Zihintpause Zic64b Zicbom Zicbop Zicboz Zfhmin Zkt Zvfhmin Zvbb
Zvkt Zihintntl Zicond Zimop Zcmop Zcb Zfa Zawrs Supm Zifencei S U
Svbare Sv39 Svade Ssccptr Sstvecd Sstvala Sscounterenw Svpbmt Svinval
Svnapot Sstc Sscofpmf Ssnpm Ssu64xl Sha H Ssstateen Shcounterenw
Shvstvala Shtvala Shvstvecd Shvsatpa Shgatpa
""".split())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def materialize(name, output):
    subprocess.run([sys.executable, str(SOURCE / "generate_config.py"),
                    "--configuration", name, "--output-dir", str(output)],
                   check=True, capture_output=True, text=True, timeout=30)
    return (YAML_READER.load((output / f"{name}.yaml").read_text()),
            json.loads((output / "sail.json").read_text()))


class ProfileConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="karu-profile-config-")
        cls.output = Path(cls.temporary.name)
        cls.frozen = {}
        for name in ("karu64-rv64gc", "karu64-sv39", "karu64-h", "karu64-rva23s64"):
            for directory in (SOURCE / name, ROOT / "_build/act-config" / name):
                if directory.exists():
                    for path in directory.rglob("*"):
                        if path.is_file():
                            cls.frozen[path] = digest(path)
        cls.h, cls.h_sail = materialize("karu64-h", cls.output / "h")
        cls.profile, cls.sail = materialize("karu64-rva23s64", cls.output / "profile")
        cls.optional, cls.optional_sail = materialize("karu64-rva23s64-smcntrpmf",
                                                      cls.output / "optional")

    @classmethod
    def tearDownClass(cls):
        try:
            for path, fingerprint in cls.frozen.items():
                if digest(path) != fingerprint:
                    raise AssertionError(f"existing configuration changed: {path}")
        finally:
            cls.temporary.cleanup()

    def test_mandatory_selection_and_optional_exclusions(self):
        extensions = {entry["name"] for entry in self.profile["implemented_extensions"]}
        self.assertFalse(REQUIRED - extensions)
        self.assertNotIn("Smcntrpmf", extensions)
        self.assertFalse(extensions & {"Zvkned", "Zvknha", "Zvknhb", "Zvksed", "Zvksh", "Zvkg"})
        for entry in self.profile["implemented_extensions"]:
            if entry["name"] in ("Sm", "S"):
                self.assertEqual(entry["version"], "= 1.13.0")
        self.assertFalse(self.sail["extensions"]["Smcntrpmf"]["supported"])
        self.assertTrue(self.sail["extensions"]["Sscofpmf"]["supported"])

    def test_inherited_harness_memory_and_guest_contracts(self):
        for name in ("memory", "platform"):
            self.assertEqual(self.sail[name], self.h_sail[name])
        for name in ("H", "Stateen", "Sstc", "Ssnpm", "Smnpm", "V"):
            self.assertEqual(self.sail["extensions"][name], self.h_sail["extensions"][name])
        self.assertEqual(self.profile["params"]["VLEN"], 256)
        self.assertEqual(self.profile["params"]["ELEN"], 64)
        self.assertEqual(self.sail["platform"]["reservation"]["reservation_set_size_exp"], 3)
        self.assertTrue(self.sail["platform"]["reservation"]["require_exact_reservation_addr"])
        for filename in ("rvmodel_common.h",):
            self.assertEqual((self.output / "h" / filename).read_bytes(),
                             (self.output / "profile" / filename).read_bytes())
        self.assertEqual((self.output / "profile/rvmodel_macros.h").read_text(),
                         "#define RVMODEL_HTIF_CLINT\n#define RVMODEL_HTIF_EXTIRQ\n" +
                         (self.output / "h/rvmodel_macros.h").read_text())
        self.assertTrue((self.output / "profile/link.ld").read_text().startswith(
            (self.output / "h/link.ld").read_text()))

    def test_profile_declares_real_timer_transport(self):
        for name, enabled in (("h", False), ("profile", True), ("optional", True)):
            with self.subTest(configuration=name):
                directory = self.output / name
                macros = subprocess.check_output([
                    "riscv64-unknown-elf-gcc", "-E", "-dM", "-x", "assembler-with-cpp",
                    "-DRVTEST_SELFCHECK", "-I" + str(directory),
                    str(directory / "rvmodel_macros.h")], text=True)
                for symbol, value in (("MTIME", "0x0200bff8"),
                                      ("MTIMECMP", "0x02004000"), ("MSIP", "0x02000000")):
                    definition = f"#define RVMODEL_{symbol}_ADDRESS {value}"
                    self.assertEqual(definition in macros, enabled)
                if enabled:
                    self.assertIn("#define RVMODEL_TIMER_INT_SOON_DELAY 1000", macros)
                    self.assertIn("sw _R2, 0(_R1)", macros)
                    self.assertIn("sw zero, 0(_R1)", macros)
                    manifest = json.loads((directory / "manifest.json").read_text())
                    self.assertEqual(manifest["testbench_defines"],
                                     ["HTIF_TB_CLINT", "HTIF_TB_EXTIRQ"])
                for name, symbol in (("MEXT", "karu_htif_meip"), ("SEXT", "karu_htif_seip")):
                    self.assertEqual(f"LA(_R1, {symbol})" in macros, enabled)
                    if enabled:
                        self.assertIn(f"#define RVMODEL_SET_{name}_INT(_R1,_R2) "
                                      f"LA(_R1, {symbol}); LI(_R2, 1); sw _R2, 0(_R1);", macros)
                        self.assertIn(f"#define RVMODEL_CLR_{name}_INT(_R1,_R2) "
                                      f"LA(_R1, {symbol}); sw zero, 0(_R1);", macros)

    def test_external_input_linker_layout_and_guards(self):
        directory = self.output / "link-probes"
        directory.mkdir()
        for name, padding, fromhost_offset, error in (
            ("dut", 0, 0x100, None), ("reference", 0, 8, None),
            ("fromhost-alias", 0, 0x18, "overlap fromhost"),
            ("page-crossing", 0xFE0, 8, "uncacheable HTIF page"),
        ):
            with self.subTest(layout=name):
                source = directory / f"{name}.S"
                source.write_text(f"""
.section .text.init,"ax",@progbits
.global rvtest_entry_point
rvtest_entry_point: nop
.section .tohost,"aw",@progbits
.balign 4096
.space {padding}
.global tohost, fromhost
tohost: .dword 0
.space {fromhost_offset - 8}
fromhost: .dword 0
.section .text.rvmodel,"ax",@progbits
nop
""")
                binaries = []
                for config in (("profile",) if error else ("h", "profile")):
                    elf = directory / f"{name}-{config}.elf"
                    result = subprocess.run([
                        "riscv64-unknown-elf-gcc", "-march=rv64gc", "-mabi=lp64d",
                        "-nostdlib", "-static", "-Wl,--no-relax",
                        "-T", str(self.output / config / "link.ld"),
                        "-o", str(elf), str(source)], capture_output=True, text=True)
                    if error:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(error, result.stderr)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    binary = elf.with_suffix(".bin")
                    subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary",
                                    str(elf), str(binary)], check=True, capture_output=True)
                    binaries.append(binary.read_bytes())
                    if config == "profile":
                        symbols = subprocess.check_output(["riscv64-unknown-elf-nm", str(elf)], text=True)
                        addresses = {line.split()[2]: int(line.split()[0], 16)
                                     for line in symbols.splitlines() if len(line.split()) == 3}
                        self.assertEqual(addresses["karu_htif_meip"], addresses["tohost"] + 0x18)
                        self.assertEqual(addresses["karu_htif_seip"], addresses["tohost"] + 0x20)
                if not error:
                    self.assertEqual(binaries[0], binaries[1])

    def test_atomic_alignment_priority_matches_physical_lsu(self):
        rtl = (ROOT / "rtl/karu64.v").read_text()
        self.assertIn(".req(lsu_req_pa)", rtl)
        self.assertIn(".addr(lsu_pa_w)", rtl)
        lsu = (ROOT / "rtl/karu_lsu.v").read_text()
        self.assertRegex(lsu, r"wire atomic_bad\s*=\s*\(is_lr_in \|\| is_sc_in \|\| is_amo_in\)\s*&&\s*"
                         r"\(access_misaligned \|\| karu_pma_io\(addr\)\)")
        for config in (self.h_sail, self.sail, self.optional_sail):
            for kind in ("lrsc", "amo"):
                self.assertEqual(config["memory"]["misaligned"]["exceptions"][kind], {"None": None})
                for region in config["memory"]["regions"]:
                    self.assertEqual(region["attributes"]["misaligned_exceptions"][kind], "AccessFault")

    def test_option_overlay_replaces_discriminant(self):
        merge = runpy.run_path(str(SOURCE / "generate_config.py"))["merge"]
        target = {"exceptions": {"amo": {"Some": "AccessFault"}, "unrelated": True}}
        for value in ({"None": None}, {"Some": "AlignmentException"}):
            merge(target, {"exceptions": {"amo": value}})
            self.assertEqual(target, {"exceptions": {"amo": value, "unrelated": True}})

    def test_reservation_policy_matches_rtl(self):
        rtl = (ROOT / "rtl/karu_lsu.v").read_text()
        self.assertRegex(rtl, r"sc_pass_i\s*=\s*is_sc_in\s*&&\s*reserve_valid\s*&&\s*"
                         r"\(reserve_addr\s*==\s*addr\)")
        for config in (self.h_sail, self.sail, self.optional_sail):
            reservation = config["platform"]["reservation"]
            self.assertEqual(reservation["reservation_set_size_exp"], 3)
            self.assertTrue(reservation["require_exact_reservation_addr"])
            self.assertFalse(reservation["invalidate_on_same_hart_store"])

    def test_minimal_profile_counter_contract(self):
        params = self.profile["params"]
        self.assertEqual(params["HPM_EVENTS"], list(range(32)))
        self.assertEqual(params["HPM_COUNTER_EN"], [False] * 3 + [True] * 29)
        self.assertEqual(params["COUNTINHIBIT_EN"], [True, False] + [True] * 30)
        for name in ("MCOUNTENABLE_EN", "SCOUNTENABLE_EN", "HCOUNTENABLE_EN"):
            self.assertEqual(params[name], [True] * 32)
        mask = self.sail["extensions"]["Zihpm"]["event_selector_mask"]
        self.assertEqual(mask["len"], 32)
        self.assertEqual(int(mask["value"], 0), 0x1F)
        self.assertEqual(int(self.sail["base"]["mideleg"]["delegatable_bits"]["value"], 0), 0x2222)
        self.assertFalse(self.h_sail["extensions"]["Sscofpmf"]["supported"])
        self.assertNotIn("event_selector_mask", self.h_sail["extensions"]["Zihpm"])
        self.assertEqual(int(self.h_sail["base"]["mideleg"]["delegatable_bits"]["value"], 0), 0x222)

    def test_counter_contract_matches_preprocessed_rtl(self):
        rtl = subprocess.check_output(["iverilog", "-g2012", "-E", "-o", "-",
                                      f"-I{ROOT / 'rtl'}", "-DKARU_RVA23S64",
                                      str(ROOT / "rtl/karu_csr.v")], text=True)
        def literal(name):
            match = re.search(r"localparam\s+\[63:0\]\s+" + name + r"\s*=\s*64'h([0-9a-fA-F_]+)", rtl)
            self.assertIsNotNone(match, name)
            return int(match.group(1).replace("_", ""), 16)
        self.assertEqual(literal("MHPMEVENT_WMASK"), 0xFC0000000000001F)
        self.assertEqual(literal("COUNTEREN_WMASK"), 0xFFFFFFFF)
        self.assertEqual(literal("VS_IRQ_MASK"), 0x444)
        s_mask = re.search(r"localparam\s+\[63:0\]\s+S_IRQ_MASK\s*=([^;]+);", rtl).group(1)
        terms = re.findall(r"64'h([0-9a-fA-F_]+)", s_mask)
        self.assertEqual([int(value.replace("_", ""), 16) for value in terms], [0x222, 0x2000])
        self.assertRegex(rtl, r"MIE_WMASK\s*=\s*64'h888\s*\|\s*S_IRQ_MASK\s*\|\s*H_IRQ_MASK")
        self.assertNotIn("csr_mcyclecfg", rtl)
        self.assertIn("scountovf_bits[scov_k + 3] = csr_mhpmevent[scov_k][63]", rtl)
        self.assertRegex(rtl, r"12'hDA0\s*\?\s*\(scountovf_bits\s*&")
        self.assertIn("& (virt ? csr_hcounteren : ~64'b0)", rtl)

    def test_optional_fixed_counter_layer_is_exact(self):
        expected = json.loads(json.dumps(self.sail))
        expected["extensions"]["Smcntrpmf"]["supported"] = True
        self.assertEqual(self.optional_sail, expected)
        required = {entry["name"] for entry in self.profile["implemented_extensions"]}
        optional = {entry["name"] for entry in self.optional["implemented_extensions"]}
        self.assertEqual(optional - required, {"Smcntrpmf"})
        self.assertFalse(required - optional)
        self.assertEqual(self.optional["params"], self.profile["params"])
        manifest = json.loads((self.output / "optional/manifest.json").read_text())
        self.assertEqual(manifest["rtl_build_define"], "KARU_RVA23S64")
        self.assertEqual(manifest["rtl_additional_defines"], ["KARU_SMCNTRPMF"])
        rtl = subprocess.check_output(["iverilog", "-g2012", "-E", "-o", "-",
                                      f"-I{ROOT / 'rtl'}", "-DKARU_RVA23S64", "-DKARU_SMCNTRPMF",
                                      str(ROOT / "rtl/karu_csr.v")], text=True)
        self.assertRegex(rtl, r"CNTRCFG_WMASK\s*=\s*64'h7c00_0000_0000_0000")
        self.assertIn("csr_mcyclecfg", rtl)
        self.assertIn("csr_minstretcfg", rtl)

    def test_manifest_and_idempotent_generation(self):
        directory = self.output / "profile"
        before = {path.name: (digest(path), path.stat().st_mtime_ns) for path in directory.iterdir()}
        manifest = json.loads((directory / "manifest.json").read_text())
        self.assertEqual(manifest["reference_version"], "0.14")
        self.assertEqual(manifest["rtl_build_define"], "KARU_RVA23S64")
        self.assertIn("not an RVA23S64 compliance claim", manifest["purpose"])
        for name, fingerprint in manifest["inputs_sha256"].items():
            self.assertEqual(digest(SOURCE / name), fingerprint)
        for name, fingerprint in manifest["outputs_sha256"].items():
            self.assertEqual(digest(directory / name), fingerprint)
        materialize("karu64-rva23s64", directory)
        after = {path.name: (digest(path), path.stat().st_mtime_ns) for path in directory.iterdir()}
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main(verbosity=2)

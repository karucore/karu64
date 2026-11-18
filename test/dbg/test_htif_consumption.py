"""Identical rebuilt executables must retain complete source and log evidence."""
# SPDX-License-Identifier: BSD-2-Clause
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_htif_consumption as verifier
from replay_isa import ROOT, file_record


class HtifConsumptionTest(unittest.TestCase):
    def fixture(self, folder):
        cpu, simulator = folder / "cpu.v", folder / "Vhtif_tb"
        cpu.write_text("module cpu; endmodule\n")
        simulator.write_bytes(b"simulator")
        artifacts = folder / "complete-build-binding"
        artifacts.mkdir()
        frontend = artifacts / "Vhtif_tb__verFiles.dat"
        flags = "-DKARU_DBG -DKARU_DBG_FULL"
        frontend.write_text("C " + json.dumps(flags + " " + str(cpu)) +
                            "\nS 0 0 0 0 0 0 unhashed " + str(cpu) + "\n")
        inputs = [file_record(cpu)]
        build = {"passed": True, "command": ["make", "-B"], "simulator": file_record(simulator),
                 "inputs_before": inputs, "inputs_after": inputs, "effective_flags": flags,
                 "consumed_source_paths": [inputs[0]["path"]], "unhashed_frontend_inputs": [],
                 "frontend_manifest": file_record(frontend)}
        elfs = folder / "elfs"
        elfs.mkdir()
        elf = elfs / "test.elf"
        elf.write_bytes(b"ELF")
        table = folder / "results.tsv"
        table.write_text("test.elf\tPASS\n")
        manifest = {"passed": False, "changed_inputs": ["dbg/karudbg.v"],
                    "simulator": file_record(simulator), "simulator_flags": flags,
                    "elfs_before": [file_record(elf)], "elfs_after": [file_record(elf)],
                    "elf_root": str(elfs), "tools": {}, "results": file_record(table),
                    "kind": "ACT4 golden replay"}
        (folder / "manifest.json").write_text(json.dumps(manifest))
        (folder / "run.log").write_text("RVCP-SUMMARY: TEST PASSED\n[HTIF] exit 0 @ 42\n")
        (folder / "results.json").write_text(json.dumps([
            {"elf": "test.elf", "result": "PASS", "log": "run.log", "returncode": 0}]))
        return build, artifacts / "build-inputs.json", cpu, simulator, elf

    def test_complete_binding_and_changed_artifacts(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "_build/dbg") as directory:
            folder = Path(directory)
            build, binding, cpu, simulator, elf = self.fixture(folder)
            binding.write_text(json.dumps(build))
            self.assertTrue(verifier.verify(folder)["passed"])
            for path, changed, message in (
                    (cpu, b"module changed; endmodule\n", "complete build inputs"),
                    (simulator, b"new simulator", "rebuilt simulator"),
                    (elf, b"different ELF", "ELF, simulator"),
                    (folder / "run.log", b"[FAIL]\n", "independent log recheck")):
                original = path.read_bytes()
                path.write_bytes(changed)
                with self.assertRaisesRegex(ValueError, message):
                    verifier.verify(folder)
                path.write_bytes(original)

    def test_nonforced_or_incomplete_or_wrong_flags_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "_build/dbg") as directory:
            folder = Path(directory)
            build, binding, *_ = self.fixture(folder)
            for field, value, message in (
                    ("command", ["make"], "forced rebuild"),
                    ("consumed_source_paths", [], "frontend coverage"),
                    ("effective_flags", "-DWRONG", "configuration flags"),
                    ("unhashed_frontend_inputs", ["new.v"], "complete input coverage")):
                mutated = dict(build)
                mutated[field] = value
                binding.write_text(json.dumps(mutated))
                with self.assertRaisesRegex(ValueError, message):
                    verifier.verify(folder)


if __name__ == "__main__":
    unittest.main()

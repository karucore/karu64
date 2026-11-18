"""Contract tests for ISA replay selection, classification and immutable inputs."""
# SPDX-License-Identifier: BSD-2-Clause
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys
import json

spec = importlib.util.spec_from_file_location("replay_isa", Path(__file__).with_name("replay_isa.py"))
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)


class IsaReplayTest(unittest.TestCase):
    def test_runtime_inputs_distinct_from_recorded_flow_provenance(self):
        for name in ("rtl/karu64.v", "rtl/karu_trigger.v", "dbg/karudbg_cfg.vh",
                     "Makefile", "dbg/isa.mk", "test/dbg/replay_isa.py", "test/dbg/build_isa.py",
                     "test/htif_hcontext_preempt_check.vh", "test/htif_ifu_fault_check.vh", "test/htif_pbmt_check.vh"):
            self.assertTrue(replay.runtime_source({"path": name}), name)
        for name in ("dbg/checks.mk", "dbg/core-test.mk", "dbg/trigger.mk", "dbg/synthesis.mk",
                     "test/act4-karu/generate_config.py", "dbg/karudbg.v", "dbg/karudbg_sba.v", "test/fw/keccak_subj.c"):
            self.assertFalse(replay.runtime_source({"path": name}), name)

    def test_build_binding_rejects_wrong_flags_binary_or_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            simulator, source = root / "Vhtif_tb", root / "rtl.v"
            simulator.write_bytes(b"simulator")
            source.write_bytes(b"RTL")
            record = {"passed": True, "effective_flags": "-DFULL",
                      "simulator": replay.file_record(simulator),
                      "inputs_before": [replay.file_record(source)]}
            (root / "build-inputs.json").write_text(json.dumps(record))
            self.assertIsNotNone(replay.check_build_binding(simulator, "-DFULL"))
            with self.assertRaises(ValueError):
                replay.check_build_binding(simulator, "-DBASE")
            simulator.write_bytes(b"other simulator")
            with self.assertRaises(ValueError):
                replay.check_build_binding(simulator, "-DFULL")
            simulator.write_bytes(b"simulator")
            source.write_bytes(b"changed RTL")
            with self.assertRaises(ValueError):
                replay.check_build_binding(simulator, "-DFULL")

    def test_directory_selection_preserves_same_basenames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("rv64i/I/equal.elf", "rv64i/Zvbb8/equal.elf",
                         "rv64i/Zvbb64/equal.elf", "priv/InterruptsSm/equal.elf"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"ELF")
            self.assertEqual(len(replay.select_elfs(root, [])), 4)
            self.assertEqual(len(replay.select_elfs(root, ["Zvbb"])), 2)
            self.assertEqual(len(replay.select_elfs(root, ["rv64i/I"])), 1)
            self.assertEqual(len(replay.select_elfs(root, ["priv/InterruptsSm", "Zvbb"])), 3)
            with self.assertRaises(ValueError):
                replay.select_elfs(root, ["absent"])

    def test_markers_do_not_hide_failure_or_timeout(self):
        good = "RVCP-SUMMARY: TEST PASSED\n[HTIF] exit 0 @ cycle 123\n"
        self.assertEqual(replay.classify(good, 0), "PASS")
        self.assertEqual(replay.classify(good, 124, timed_out=True), "TIMEOUT")
        self.assertEqual(replay.classify(good, 1), "SIM_ERROR")
        self.assertEqual(replay.classify(good + "RVCP-SUMMARY: TEST FAILED\n", 0), "FAIL")
        self.assertEqual(replay.classify(good.replace("exit 0", "exit 1"), 0), "FAIL")
        self.assertEqual(replay.classify("RVCP-SUMMARY: TEST PASSED\n", 0), "NO_EXIT")
        self.assertEqual(replay.classify("[HTIF] exit 0 @ cycle 123\n", 0), "NO_MARKER")
        self.assertEqual(replay.classify("[HTIF] exit 0 @ cycle 123\n", 0, ordinary=True), "PASS")

    def test_hash_verification_detects_change_and_deletion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.elf"
            path.write_bytes(b"original")
            record = replay.file_record(path)
            self.assertEqual(replay.verify_records([record]), [])
            path.write_bytes(b"modified")
            self.assertEqual(replay.verify_records([record]), [str(path)])
            path.unlink()
            self.assertEqual(replay.verify_records([record]), [str(path)])

    def test_execution_logs_preserve_dotted_names_and_remove_pass_images(self):
        # Tiny process fixtures exercise the runner, not an RTL simulation.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def tool(name, body):
                path = root / name
                path.write_text(f"#!{sys.executable}\n" + body)
                path.chmod(0o755)
                return str(path)
            copy = tool("copy", "import pathlib,sys\npathlib.Path(sys.argv[-1]).write_bytes(bytes(8))\n")
            nm = tool("nm", "print('80002000 D tohost')\n")
            simulator = Path(tool("sim", "print('RVCP-SUMMARY: TEST PASSED\\n[HTIF] exit 0 @ cycle 12')\n"))
            for name in ("vadd.vv.elf", "vadd.vx.elf"):
                elf = root / "inputs" / name
                elf.parent.mkdir(exist_ok=True)
                elf.write_bytes(b"ELF")
                result = replay.run_one(elf, elf.parent, root / "out", simulator,
                                        copy, nm, 5, 100, False, False)
                self.assertEqual(result["result"], "PASS")
            self.assertEqual(sorted(p.name for p in (root / "out/tests").iterdir()),
                             ["vadd.vv.log", "vadd.vx.log"])


if __name__ == "__main__":
    unittest.main()

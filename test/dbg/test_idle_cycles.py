"""The idle-cycle comparison must reject changed inputs and nonzero costs."""
# SPDX-License-Identifier: BSD-2-Clause
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("compare_idle_cycles.py").resolve()


class IdleCycleTest(unittest.TestCase):
    def test_policy_with_independent_fixture_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def fixture(name, flag, cycles=123, elf="same-elf", source="same-source"):
                folder = root / name
                folder.mkdir(exist_ok=True)
                manifest = {"passed": True, "kind": "ordinary HTIF", "build_binding": {"sha256": "bound"},
                            "changed_inputs": [], "elfs_before": [{"path": "_build/test.elf", "sha256": elf}],
                            "runtime_source_paths": ["rtl/karu64.v"],
                            "sources_before": [{"path": "rtl/karu64.v", "sha256": source}],
                            "simulator_flags": "-DKARU_DBG" + flag}
                (folder / "manifest.json").write_text(json.dumps(manifest))
                (folder / "results.json").write_text(json.dumps([{"elf": "test.elf", "result": "PASS", "log": "test.log"}]))
                (folder / "test.log").write_text(f"[HTIF] exit 0 @ cyc={cycles}\n")
            def run():
                return subprocess.run([sys.executable, str(SCRIPT), "--base", str(root / "base"),
                                       "--full", str(root / "full"), "--out", str(root / "out")],
                                      text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      timeout=10)
            fixture("base", "")
            fixture("full", " -DKARU_DBG_FULL")
            self.assertEqual(run().returncode, 0)
            fixture("full", " -DKARU_DBG_FULL", cycles=124)
            self.assertNotEqual(run().returncode, 0)
            fixture("full", " -DKARU_DBG_FULL", elf="different-elf")
            self.assertIn("ELF identities", run().stdout)
            fixture("full", " -DKARU_DBG_FULL", source="different-source")
            self.assertIn("source identities", run().stdout)
            fixture("full", " -DKARU_DBG_FULL -DKARU_NO_F")
            self.assertIn("flags must differ", run().stdout)


if __name__ == "__main__":
    unittest.main()

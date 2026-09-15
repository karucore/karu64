#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Paired generator checks for WFI-independent interrupt stimulus.

Privileged1.13 permits WFI to resume without an interrupt, including as a NOP.
Timer-trigger tests therefore wait explicitly before clearing their source.
U-mode WFI with S implemented must trap; separate timer-origin bins retain
the asynchronous interrupt coverage without racing the illegal-trap signature.
"""

import ast
import importlib
from pathlib import Path
import random
import shutil
import tempfile
import unittest

from test_h_capability import ACT4, TestConfig, TestData, preprocess
from test_h_trap_harness import HERE, run


EXTENSIONS = Path("generators/testgen/src/testgen/priv/extensions")


def code(text):
    return [line.split("#", 1)[0].strip() for line in text.splitlines()
            if line.split("#", 1)[0].strip()]


class InterruptWfiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="act-irq-wfi-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.before = Path(cls.temp.name)
        directory = cls.before / EXTENSIONS
        directory.mkdir(parents=True)
        cls.modules = {}
        for name in ("InterruptsSm", "InterruptsSSm", "InterruptsU"):
            shutil.copy2(ACT4 / EXTENSIONS / (name + ".py"), directory)
            cls.modules[name] = importlib.import_module("testgen.priv.extensions." + name)
        run([
            "patch", "--batch", "--reverse", "--fuzz=0", "--no-backup-if-mismatch", "-p1",
            "-d", str(cls.before), "-i", str(HERE / "patches/priv-irq-wfi.patch"),
        ])

    def generate(self, module, function, xlen, before=False):
        random.seed(45678)
        data = TestData(TestConfig(xlen=xlen, flen=xlen, testsuite=module))
        chunk = data.begin_test_chunk()
        namespace = vars(self.modules[module]).copy()
        if before:
            source = ast.parse((self.before / EXTENSIONS / (module + ".py")).read_text())
            node = next(item for item in source.body if isinstance(item, ast.FunctionDef) and item.name == function)
            exec(compile(ast.Module(body=[node], type_ignores=[]), "before.py", "exec"), namespace)
        lines = namespace[function](data)
        bookkeeping = (data.test_count, chunk.sigupd_count, chunk.num_testcases, chunk.data_strings)
        return lines, bookkeeping

    def expanded(self, lines, xlen, supervisor):
        declarations = ["#define RVMODEL_MTIME_ADDRESS 0x0200bff8", "#define RVMODEL_MTIMECMP_ADDRESS 0x02004000"]
        return code(preprocess(declarations + lines, xlen, s_supported=supervisor))

    def test_machine_waits_only_added_for_enabled_interrupt_cases(self):
        for module, function, waits, cases in (
            ("InterruptsSm", "_generate_wfi_tests", 2, 4),
            ("InterruptsSSm", "_generate_wfi_m_tests", 4, 8),
        ):
            for xlen in (32, 64):
                current, current_counts = self.generate(module, function, xlen)
                before, before_counts = self.generate(module, function, xlen, before=True)
                self.assertEqual(current_counts, before_counts)
                self.assertEqual(current_counts[0], cases)
                current_code = self.expanded(current, xlen, True)
                before_code = self.expanded(before, xlen, True)
                self.assertEqual(len(current_code) - len(before_code), waits)
                # Exactly one added wait follows each interrupt-enabled WFI.
                added = [index for index, line in enumerate(current_code)
                         if line.startswith("RVTEST_IDLE_FOR_TIMER_INTERRUPT")
                         and any(item.startswith("wfi") for item in current_code[max(0, index - 3):index])]
                self.assertEqual(len(added), waits)
                self.assertEqual([line for index, line in enumerate(current_code) if index not in added], before_code)

    def test_supervisor_user_wfi_retains_two_exact_illegal_cases_without_timer_race(self):
        for xlen in (32, 64):
            current, counts = self.generate("InterruptsU", "_generate_user_wfi_tests", xlen)
            _, old_counts = self.generate("InterruptsU", "_generate_user_wfi_tests", xlen, before=True)
            self.assertEqual(counts, old_counts)
            self.assertEqual(counts[0], 2)
            text = self.expanded(current, xlen, True)
            self.assertEqual(text.count("wfi"), 2)
            self.assertEqual(text.count("csrw mie, zero"), 2)
            self.assertIn("csrci mstatus, 8", text)
            self.assertIn("csrsi mstatus, 8", text)
            self.assertFalse(any("RVMODEL_TIMER_INT_SOON_DELAY" in line for line in text))
            self.assertFalse(any("RVTEST_IDLE_FOR_TIMER_INTERRUPT" in line for line in text))

    def test_no_supervisor_user_wfi_keeps_existing_explicit_wait_and_code(self):
        for xlen in (32, 64):
            current, counts = self.generate("InterruptsU", "_generate_user_wfi_tests", xlen)
            before, old_counts = self.generate("InterruptsU", "_generate_user_wfi_tests", xlen, before=True)
            self.assertEqual(counts, old_counts)
            text = self.expanded(current, xlen, False)
            self.assertEqual(text, self.expanded(before, xlen, False))
            self.assertEqual(sum("RVTEST_IDLE_FOR_TIMER_INTERRUPT" in line for line in text), 2)

    def test_user_timer_origin_and_tw1_coverage_are_unchanged(self):
        for function in ("_generate_user_mti_tests", "_generate_user_wfi_timeout_tests"):
            for xlen in (32, 64):
                current, counts = self.generate("InterruptsU", function, xlen)
                before, old_counts = self.generate("InterruptsU", function, xlen, before=True)
                self.assertEqual(counts, old_counts)
                self.assertEqual(counts[0], 4)
                for supervisor in (False, True):
                    self.assertEqual(self.expanded(current, xlen, supervisor),
                                     self.expanded(before, xlen, supervisor))


if __name__ == "__main__":
    unittest.main(verbosity=2)

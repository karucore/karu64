#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compile-time H mask tests for the maintained ACT4 generator patch."""

import os
from pathlib import Path
import random
import re
import shlex
import subprocess
import sys
import unittest

ACT4 = Path(__file__).resolve().parent.parent / "riscv-arch-test"
sys.path.insert(0, str(ACT4 / "generators/testgen/src"))

from testgen.asm.csr import csr_access_test, csr_walk_test  # noqa: E402
from testgen.data.config import TestConfig  # noqa: E402
from testgen.data.state import TestData  # noqa: E402
from testgen.priv.extensions.Sm import _generate_mcsr_tests  # noqa: E402


MSTATUS_MASK = 0x8000020080FFFFAA
MSTATUSH_MASK = 0x200
MSTATUS_GATE = ("defined(H_SUPPORTED) && __riscv_xlen == 64", (1 << 38) | (1 << 39))
MSTATUSH_GATE = ("defined(H_SUPPORTED) && __riscv_xlen == 32", (1 << 6) | (1 << 7))


def preprocess(lines, xlen, h_supported=False, s_supported=True):
    command = [*shlex.split(os.environ.get("CPP", "cc -E")), "-P", "-x", "assembler-with-cpp"]
    command += [f"-D__riscv_xlen={xlen}"]
    if h_supported:
        command.append("-DH_SUPPORTED")
    if s_supported:
        command.append("-DS_SUPPORTED")
    result = subprocess.run(command + ["-"], input="\n".join(lines), text=True, capture_output=True, check=True)
    return result.stdout


def generate(generator, csr, mask_gate=None, warl_fields=None):
    random.seed(12345)
    data = TestData(TestConfig(xlen=64, flen=64, testsuite="Sm"))
    chunk = data.begin_test_chunk()
    kwargs = {"maskedwrites": True}
    if mask_gate is not None:
        kwargs["mask_gate"] = mask_gate
    if warl_fields is not None:
        kwargs["warl_fields"] = warl_fields
    lines = generator(data, csr, "test_cg", "test_cp", **kwargs)
    bookkeeping = (data.test_count, chunk.sigupd_count, chunk.num_testcases, chunk.data_strings)
    return lines, bookkeeping


def loaded_masks(source):
    return [int(value, 0) for value in re.findall(r"LI\(x\d+, (0x[0-9a-f]+|\d+)\)\s+# Load.*mask", source)]


class MaskGateTest(unittest.TestCase):
    def test_gate_disabled_preserves_code_and_bookkeeping(self):
        for generator in (csr_access_test, csr_walk_test):
            for csr, gate in (("mstatus", MSTATUS_GATE), ("mstatush", MSTATUSH_GATE)):
                mask = MSTATUS_MASK if csr == "mstatus" else MSTATUSH_MASK
                fields = [("mpp", 11, 2, 2), ("mpp", 11, 2, 1, "S_SUPPORTED")]
                warl_fields = fields if csr == "mstatus" and generator == csr_walk_test else None
                plain, plain_bookkeeping = generate(generator, (csr, mask), warl_fields=warl_fields)
                gated, gated_bookkeeping = generate(generator, (csr, mask), gate, warl_fields)
                self.assertEqual(plain_bookkeeping, gated_bookkeeping)
                for xlen in (32, 64):
                    for s_supported in (False, True):
                        with self.subTest(generator=generator.__name__, csr=csr, xlen=xlen, s=s_supported):
                            self.assertEqual(
                                preprocess(plain, xlen, s_supported=s_supported),
                                preprocess(gated, xlen, s_supported=s_supported),
                            )

    def test_gva_mpv_select_the_correct_xlen_csr(self):
        for generator in (csr_access_test, csr_walk_test):
            for csr, mask, gate, legal_xlen in (
                ("mstatus", MSTATUS_MASK, MSTATUS_GATE, 64),
                ("mstatush", MSTATUSH_MASK, MSTATUSH_GATE, 32),
            ):
                lines, _ = generate(generator, (csr, mask), gate)
                for xlen in (32, 64):
                    for h_supported in (False, True):
                        expected = mask | (gate[1] if h_supported and xlen == legal_xlen else 0)
                        if generator == csr_access_test and xlen == 32:
                            expected &= 0xFFFFFFFF
                        with self.subTest(generator=generator.__name__, csr=csr, xlen=xlen, h=h_supported):
                            self.assertEqual(loaded_masks(preprocess(lines, xlen, h_supported)), [expected])

    def test_warl_masks_keep_h_bits_and_exclude_reserved_fields(self):
        fields = [("mpp", 11, 2, 2), ("mpp", 11, 2, 1, "S_SUPPORTED")]
        lines, _ = generate(csr_walk_test, ("mstatus", MSTATUS_MASK), MSTATUS_GATE, fields)
        for s_supported in (False, True):
            for h_supported in (False, True):
                masks = loaded_masks(preprocess(lines, 64, h_supported, s_supported))
                expected = MSTATUS_MASK | (MSTATUS_GATE[1] if h_supported else 0)
                self.assertGreater(len(masks), 1)
                self.assertEqual(masks[0], expected)
                self.assertEqual(set(masks[1:]), {expected & ~(3 << 11)})

    def test_gate_bits_cannot_reintroduce_reserved_fields(self):
        gate = ("defined(H_SUPPORTED)", (3 << 11) | (1 << 38))
        lines, _ = generate(csr_walk_test, ("mstatus", 0xFFFF), gate, [("mpp", 11, 2, 2)])
        masks = loaded_masks(preprocess(lines, 64, True))
        self.assertEqual(masks[0], 0xFFFF | (1 << 38))
        self.assertEqual(set(masks[1:]), {(0xFFFF & ~(3 << 11)) | (1 << 38)})

    def test_sm_generator_uses_both_xlen_gates(self):
        random.seed(12345)
        data = TestData(TestConfig(xlen=64, flen=64, testsuite="Sm"))
        chunks = []
        _generate_mcsr_tests(data, chunks)
        if data.test_chunk is not None:
            chunks.append(data.end_test_chunk())
        lines = [line for chunk in chunks for line in chunk.code]
        for xlen, expected, excluded in (
            (32, MSTATUSH_MASK | MSTATUSH_GATE[1], MSTATUS_MASK | MSTATUS_GATE[1]),
            (64, MSTATUS_MASK | MSTATUS_GATE[1], MSTATUSH_MASK | MSTATUSH_GATE[1]),
        ):
            with self.subTest(xlen=xlen):
                h_masks = loaded_masks(preprocess(lines, xlen, True))
                non_h_masks = loaded_masks(preprocess(lines, xlen, False))
                self.assertIn(expected, h_masks)
                self.assertNotIn(expected, non_h_masks)
                self.assertNotIn(excluded, h_masks)


if __name__ == "__main__":
    unittest.main(verbosity=2)

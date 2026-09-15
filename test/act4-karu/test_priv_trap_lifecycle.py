#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check emitted ACT privilege-entry, signature-capacity and cleanup contracts.

ACT_H_WORK selects a generated H rvtest_config.h. ACT_ENV optionally selects
an isolated patched header directory. The negative control reverses only the
maintained lifecycle patch, leaving the separate H trap-bank correction intact.
"""

import os
from pathlib import Path
import re
import shutil
import tempfile
import unittest

from test_h_trap_harness import ACT, HERE, WORK, XCHAIN, Image, run


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class LifecycleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="act-priv-lifecycle-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.current = cls.root / "current/tests/env"
        cls.before = cls.root / "before/tests/env"
        headers = Path(os.environ.get("ACT_ENV", ACT / "tests/env"))
        shutil.copytree(headers, cls.current)
        shutil.copytree(headers, cls.before)
        run([
            "patch", "--batch", "--reverse", "--fuzz=0", "--no-backup-if-mismatch", "-p1",
            "-d", str(cls.root / "before"), "-i", str(HERE / "patches/priv-trap-lifecycle.patch"),
        ])
        config = (WORK / "rvtest_config.h").read_text()
        if "#define H_SUPPORTED" not in config or "#define S_SUPPORTED" not in config:
            raise RuntimeError(f"{WORK}/rvtest_config.h must describe H+S")
        cls.images = {}
        for mode in ("M", "S", "H"):
            cfg = cls.root / ("config-" + mode)
            cfg.mkdir()
            text = config
            if mode != "H":
                text = re.sub(r"^#define H_SUPPORTED\s*$", "", text, flags=re.MULTILINE)
            if mode == "M":
                text = re.sub(r"^#define S_SUPPORTED\s*$", "", text, flags=re.MULTILINE)
            (cfg / "rvtest_config.h").write_text(text)
            targets = ["Mmode"]
            if mode != "M":
                targets += ["Smode", "Umode"]
            if mode == "H":
                targets += ["HSmode", "VSmode", "VUmode"]
            source = cls.root / (mode + ".S")
            source.write_text(
                '#define SIGUPD_COUNT 0\n#define BOOT_TO_MMODE\n#include "riscv_arch_test.h"\n'
                + "RVTEST_BEGIN\n"
                + "\n".join(f"entry_{target}:\n RVTEST_GOTO_LOWER_MODE {target}\nend_{target}:" for target in targets)
                + "\nRVTEST_CODE_END\nRVTEST_DATA_BEGIN\nRVTEST_DATA_END\nRVTEST_SIG_SETUP\n"
            )
            for version, env in (("current", cls.current), ("before", cls.before)):
                for capacity in (1, 100, 180):
                    name = f"{mode}-{version}-{capacity}"
                    elf = cls.root / (name + ".elf")
                    run([
                        XCHAIN + "gcc", "-march=rv64i_zicsr_zifencei", "-mabi=lp64",
                        "-nostdlib", "-mcmodel=medany", "-Wl,--no-warn-rwx-segments",
                        "-DTEST_FLEN=0", '-DTEST_FILE="lifecycle.S"', "-DSIGNATURE",
                        f"-DTRAP_SIGUPD_COUNT={capacity}",
                        "-DSAIL_CLINT_BASE_ADDRESS=0x2000000",
                        "-DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0x3000000",
                        "-I" + str(cfg), "-I" + str(env), "-I" + str(HERE / "karu64-rv64gc"),
                        "-T" + str(HERE / "karu64-rv64gc/link.ld"), "-o", str(elf), str(source),
                    ])
                    cls.images[name] = Image(elf)

    def image(self, mode="H", version="current", capacity=180):
        return self.images[f"{mode}-{version}-{capacity}"]

    def entry(self, image, target, poisoned_mpv=True):
        """Evaluate only the branch-free emitted entry macro, stopping at MRET.

        Distinct relocated frame pointers expose a wrong frame even when an
        identity-map execution would hide it. This is not a general ISA oracle.
        """
        mask = (1 << 64) - 1
        registers = [0] + [0x10000 + index for index in range(1, 32)]
        initial = registers[:]
        csrs = {0x340: image.symbols["Mtramptbl_sv"], 0x300: (1 << 39) if poisoned_mpv else 0, 0x302: 4}
        memory = {}
        roots = {"M": 0x80000000, "H": 0x1C0000000, "S": 0x240000000, "V": 0x340000000}
        for mode, root in roots.items():
            if mode + "code_bgn_ptr" in image.symbols:
                memory[image.symbols[mode + "code_bgn_ptr"]] = root
        begin = image.symbols["entry_" + target]
        for index, word in enumerate(image.words("entry_" + target, "end_" + target)):
            pc = begin + 4 * index
            opcode, rd, rs1, rs2 = word & 127, (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
            funct = (word >> 12) & 7
            imm = signed(word >> 20, 12)
            if word == 0x30200073:
                self.assertEqual(registers, initial, "entry must restore every working register")
                return csrs, pc + 4, roots
            if opcode == 0x37:
                registers[rd] = signed(word & 0xFFFFF000, 32)
            elif opcode == 0x17:
                registers[rd] = pc + signed(word & 0xFFFFF000, 32)
            elif opcode in (0x13, 0x1B) and funct == 0:
                registers[rd] = registers[rs1] + imm
                if opcode == 0x1B:
                    registers[rd] = signed(registers[rd] & 0xFFFFFFFF, 32)
            elif opcode == 0x13 and funct == 1:
                registers[rd] = registers[rs1] << ((word >> 20) & 63)
            elif opcode == 0x13 and funct == 5 and not (word >> 30 & 1):
                registers[rd] = registers[rs1] >> ((word >> 20) & 63)
            elif opcode == 0x13 and funct == 7:
                registers[rd] = registers[rs1] & imm
            elif opcode == 0x33 and funct == 0:
                registers[rd] = registers[rs1] + (-registers[rs2] if word >> 30 & 1 else registers[rs2])
            elif opcode == 0x03 and funct == 3:
                registers[rd] = memory[(registers[rs1] + imm) & mask]
            elif opcode == 0x23 and funct == 3:
                offset = signed(((word >> 25) << 5) | ((word >> 7) & 31), 12)
                memory[(registers[rs1] + offset) & mask] = registers[rs2]
            elif opcode == 0x73 and funct:
                csr = word >> 20
                old = csrs.get(csr, 0)
                operand = rs1 if funct & 4 else registers[rs1]
                operation = funct & 3
                csrs[csr] = (operand if operation == 1 else old | operand if operation == 2 else old & ~operand) & mask
                registers[rd] = old
            else:
                self.fail(f"entry evaluator does not recognize {word:08x} at {pc:x}")
            registers[rd] &= mask
            registers[0] = 0
        self.fail("entry does not terminate with MRET")

    def test_host_entries_clear_poisoned_mpv_and_select_host_frame(self):
        for target, frame, mpp in (("Mmode", "M", 3), ("Smode", "H", 1), ("HSmode", "H", 1), ("Umode", "H", 0)):
            with self.subTest(target=target):
                csr, next_pc, roots = self.entry(self.image(), target)
                self.assertEqual(csr[0x300] >> 39 & 1, 0)
                self.assertEqual(csr[0x300] >> 11 & 3, mpp)
                self.assertEqual(csr[0x341], next_pc + roots[frame] - roots["M"])

    def test_guest_entries_set_mpv_and_keep_distinct_vs_frame(self):
        for target, mpp in (("VSmode", 1), ("VUmode", 0)):
            csr, next_pc, roots = self.entry(self.image(), target, poisoned_mpv=False)
            self.assertEqual(csr[0x300] >> 39 & 1, 1)
            self.assertEqual(csr[0x300] >> 11 & 3, mpp)
            self.assertEqual(csr[0x341], next_pc + roots["V"] - roots["M"])

    def test_entry_negative_control_exposes_relocation_and_mpv_errors(self):
        csr, next_pc, roots = self.entry(self.image(version="before"), "Smode")
        self.assertEqual(csr[0x300] >> 39 & 1, 1)
        self.assertEqual(csr[0x341], next_pc + roots["S"] - roots["M"])

    def test_non_h_entry_bytes_are_unchanged(self):
        for mode, targets in (("M", ("Mmode",)), ("S", ("Mmode", "Smode", "Umode"))):
            for target in targets:
                self.assertEqual(self.image(mode).words("entry_" + target, "end_" + target),
                                 self.image(mode, "before").words("entry_" + target, "end_" + target))

    def test_signature_capacity_scales_only_h_and_rounds_up(self):
        for mode in ("M", "S", "H"):
            for capacity in (1, 100, 180):
                for version in ("current", "before"):
                    symbols = self.image(mode, version, capacity).symbols
                    words = (3 * capacity + 1) // 2 if mode == "H" and version == "current" else capacity
                    self.assertEqual(symbols["sig_end_canary"] - symbols["trap_sigptr"], words * 8)
        self.assertGreaterEqual((3 * 180 + 1) // 2, 42 * 6)
        self.assertGreaterEqual((3 * 100 + 1) // 2, 21 * 6)

    def test_cleanup_clears_mprv_before_first_epilog_load(self):
        for mode, first in (("M", "M"), ("S", "S"), ("H", "V")):
            for version in ("current", "before"):
                image = self.image(mode, version)
                words = image.words("cleanup_epilogs", "exit_" + first + "cleanup")
                # All normal and abort paths enter the same cleanup label.
                self.assertEqual(image.symbols["rvtest_code_end"], image.symbols["cleanup_epilogs"])
                self.assertIn(0x00000073, words)  # T-SBI transition to M precedes the clear.
                clear = (0x300 << 20) | (6 << 15) | (3 << 12) | 0x73
                if version == "current":
                    self.assertIn(clear, words)
                    index = words.index(clear)
                    self.assertGreater(index, words.index(0x00000073))
                    self.assertEqual(words[index - 2:index], [0x00100313, 0x01131313])  # x6 = 1 << 17
                    self.assertFalse(any(word & 127 == 3 for word in words))
                else:
                    self.assertNotIn(clear, words)

    def test_s_epilog_selects_its_allocated_frame(self):
        for mode in ("S", "H"):
            for version in ("current", "before"):
                image = self.image(mode, version)
                words = image.words("exit_Scleanup", "resto_Sedeleg")
                offset = signed(words[1] >> 20, 12)
                stride = image.symbols["Msv_area_end"] - image.symbols["Mtramptbl_sv"]
                expected = 2 * stride if mode == "H" or version == "before" else stride
                self.assertEqual(offset, expected)
                if version == "current":
                    self.assertEqual(image.symbols["Mtramptbl_sv"] + offset, image.symbols["Stramptbl_sv"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

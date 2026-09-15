#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Assemble the ACT4 trap harness and check its H layout/CSR contract.

Requires the generated karu64-h rvtest_config.h (an ACT H reference build
produces it), the RISC-V GNU toolchain, and patch. No simulator is needed.
The inverse maintained patch is applied only to a temporary header copy.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
ACT = HERE.parent / "riscv-arch-test"
WORK = Path(os.environ.get("ACT_H_WORK", ACT / "work/karu64-h"))
XCHAIN = os.environ.get("XCHAIN", "riscv64-unknown-elf-")
FIXTURE = """\
#define SIGUPD_COUNT 0
#define BOOT_TO_MMODE
#include "riscv_arch_test.h"
RVTEST_BEGIN
  nop
RVTEST_CODE_END
RVTEST_DATA_BEGIN
RVTEST_DATA_END
RVTEST_SIG_SETUP
"""


def run(command):
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, command))}\n{result.stdout}{result.stderr}")
    return result.stdout


class Image:
    def __init__(self, elf):
        self.symbols = {}
        for line in run([XCHAIN + "nm", "-an", "--defined-only", str(elf)]).splitlines():
            fields = line.split()
            if len(fields) == 3:
                self.symbols[fields[2]] = int(fields[0], 16)
        binary = elf.with_suffix(".bin")
        run([XCHAIN + "objcopy", "-O", "binary", str(elf), str(binary)])
        self.data = binary.read_bytes()
        self.base = self.symbols["rvtest_entry_point"]

    def words(self, begin, end=None, count=None):
        first = self.symbols[begin] - self.base
        last = self.symbols[end] - self.base if end else first + 4 * count
        return [int.from_bytes(self.data[i : i + 4], "little") for i in range(first, last, 4)]

    def csrs(self, begin, end):
        return [word >> 20 for word in self.words(begin, end) if word & 0x7F == 0x73 and word >> 12 & 7]


class TrapHarnessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="act-h-trap-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.current = cls.root / "current/tests/env"
        cls.before = cls.root / "before/tests/env"
        shutil.copytree(ACT / "tests/env", cls.current)
        shutil.copytree(ACT / "tests/env", cls.before)
        run([
            "patch", "--batch", "--reverse", "--fuzz=0", "--no-backup-if-mismatch", "-p1",
            "-d", str(cls.root / "before"), "-i", str(HERE / "patches/h-trap-harness.patch"),
        ])
        config = (WORK / "rvtest_config.h").read_text()
        if "#define H_SUPPORTED" not in config or "#define S_SUPPORTED" not in config:
            raise RuntimeError(f"{WORK}/rvtest_config.h must describe an H+S configuration")
        cls.images = {}
        for mode in ("M", "S", "H"):
            includes = cls.root / ("config-" + mode)
            includes.mkdir()
            mode_config = config
            if mode != "H":
                mode_config = re.sub(r"^#define H_SUPPORTED\s*$", "", mode_config, flags=re.MULTILINE)
            if mode == "M":
                mode_config = re.sub(r"^#define S_SUPPORTED\s*$", "", mode_config, flags=re.MULTILINE)
            (includes / "rvtest_config.h").write_text(mode_config)
            for version, headers in (("current", cls.current), ("before", cls.before)):
                for selfcheck in ((False, True) if mode == "H" and version == "current" else (False,)):
                    image_name = f"{mode}-{version}-{'dut' if selfcheck else 'sig'}"
                    source = cls.root / "fixture.S"
                    source.write_text(FIXTURE)
                    elf = cls.root / (image_name + ".elf")
                    run([
                        XCHAIN + "gcc", "-march=rv64i_zicsr_zifencei", "-mabi=lp64",
                        "-nostdlib", "-mcmodel=medany", "-Wl,--no-warn-rwx-segments",
                        "-DRVTEST_NOSIG", "-DTEST_FLEN=0", '-DTEST_FILE="harness.S"',
                        "-DSAIL_CLINT_BASE_ADDRESS=0x2000000",
                        "-DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0x3000000",
                        "-DRVTEST_SELFCHECK" if selfcheck else "-DSIGNATURE",
                        "-I" + str(includes), "-I" + str(headers),
                        "-I" + str(HERE / "karu64-rv64gc"),
                        "-T" + str(HERE / "karu64-rv64gc/link.ld"),
                        "-o", str(elf), str(source),
                    ])
                    cls.images[image_name] = Image(elf)

    def test_non_h_loadable_bytes_unchanged(self):
        for mode in ("M", "S"):
            with self.subTest(mode=mode):
                self.assertEqual(self.images[f"{mode}-current-sig"].data, self.images[f"{mode}-before-sig"].data)

    def test_save_area_offsets_match_all_handler_indices(self):
        image = self.images["H-current-sig"]
        symbols = image.symbols
        stride = symbols["Msv_area_end"] - symbols["Mtramptbl_sv"]
        for index, mode in enumerate(("M", "H", "S", "V")):
            self.assertEqual(symbols[mode + "tramptbl_sv"] - symbols["Mtramptbl_sv"], index * stride)
        # The HS pointer load is relative to its frame minus one full stride.
        words = image.words("Htrap_sig_sv", count=2)
        adjust = words[0] >> 20
        if adjust & 0x800:
            adjust -= 0x1000
        load_offset = words[1] >> 20
        self.assertEqual(symbols["Htramptbl_sv"] + adjust + load_offset, symbols["Mtrap_sig"])
        for mode in ("M", "S"):
            non_h = self.images[f"{mode}-current-sig"].symbols
            self.assertNotIn("Htramptbl_sv", non_h)
            if mode == "S":
                self.assertEqual(non_h["Stramptbl_sv"] - non_h["Mtramptbl_sv"], stride)

    def test_hs_runtime_csrs_are_not_h_auxiliary_banks(self):
        image = self.images["H-current-sig"]
        self.assertEqual(image.csrs("common_Hint_handler", "spcl_Hhandler")[:2], [0x104, 0x144])
        snapshot = image.csrs("Htrap_sig_sv", "sv_Hvect")
        self.assertEqual(snapshot, [0x141, 0x143, 0x100])
        self.assertIn(0x600, image.csrs("sv_Hvect", "sv_Hcause"))
        # The M-mode prolog retains the separate hypervisor delegation/root bank.
        prolog = image.csrs("init_Hscratch", "rvtest_Hprolog_done")
        self.assertIn(0x602, prolog)
        self.assertIn(0x680, prolog)

    def test_unpatched_negative_control_has_the_reported_defects(self):
        image = self.images["H-before-sig"]
        self.assertEqual(image.csrs("common_Hint_handler", "spcl_Hhandler")[:2], [0x604, 0x644])
        self.assertNotIn("tsbi_Hdispatch", image.symbols)
        self.assertNotIn("sv_HHtval", image.symbols)
        stride = image.symbols["Msv_area_end"] - image.symbols["Mtramptbl_sv"]
        self.assertEqual(image.symbols["Htramptbl_sv"] - image.symbols["Mtramptbl_sv"], 2 * stride)

    def test_hs_six_word_exception_metadata_is_written(self):
        image = self.images["H-current-sig"]
        # csrr x8, CSR followed by sd x8, slot*8(x6); all are actual emitted words.
        for label, csr, slot in (("sv_HHtval", 0x643, 4), ("sv_HHtinst", 0x64A, 5)):
            words = image.words(label, count=2)
            self.assertEqual(words[0], (csr << 20) | (2 << 12) | (8 << 7) | 0x73)
            store = words[1]
            immediate = ((store >> 25) << 5) | ((store >> 7) & 31)
            self.assertEqual((store & 0x7F, store >> 15 & 31, store >> 20 & 31, immediate), (0x23, 6, 8, slot * 8))
        self.assertEqual(image.csrs("skp_adj_Hepc", "sv_Htval"), [0x143])
        self.assertEqual(image.words("Hxcpt_sig_sv", count=1), [0x03000393])

    def test_host_tsbi_does_not_consume_guest_ecalls(self):
        image = self.images["H-current-sig"]
        words = image.words("Hgoto_schk", count=3)
        self.assertEqual(words[0], 0x600024F3)  # csrr x9,hstatus
        self.assertEqual(words[1], 0x0804F493)  # andi x9,x9,SPV
        self.assertEqual(words[2] & 0x707F, 0x1063)  # bne: SPV != 0 -> normal trap
        instruction = words[2]
        offset = (((instruction >> 31) & 1) << 12) | (((instruction >> 7) & 1) << 11)
        offset |= (((instruction >> 25) & 63) << 5) | (((instruction >> 8) & 15) << 1)
        if offset & 0x1000:
            offset -= 0x2000
        self.assertEqual(image.symbols["Hgoto_schk"] + 8 + offset, image.symbols["Htrapsig_ptr_upd"])
        for operation in ("dispatch", "goto_s", "goto_u", "forward_goto_m", "csr_access", "ecall_test"):
            self.assertIn("tsbi_H" + operation, image.symbols)
        self.assertIn("Hrtn2smode", image.symbols)
        self.assertNotIn("tsbi_Vdispatch", image.symbols)

    def test_host_and_guest_epc_use_distinct_roots(self):
        image = self.images["H-current-sig"]
        self.assertEqual(image.csrs("common_Hexcpt_handler", "guest_Hepc"), [0x141, 0x600, 0x180])
        self.assertEqual(image.csrs("guest_Hepc", "vmem_adj_Hepc"), [0x680, 0x280])

    def test_reference_and_selfcheck_labels_match(self):
        signature = self.images["H-current-sig"].symbols
        selfcheck = self.images["H-current-dut"].symbols
        for label in (
            "rvtest_code_begin", "rvtest_code_end", "rvtest_data_begin", "rvtest_data_end",
            "Mtrampoline", "Htrampoline", "Strampoline", "Vtrampoline", "tsbi_Hdispatch",
            "sv_HHtval", "sv_HHtinst", "Mtramptbl_sv", "Htramptbl_sv", "begin_signature",
        ):
            with self.subTest(label=label):
                self.assertEqual(signature[label], selfcheck[label])


if __name__ == "__main__":
    unittest.main(verbosity=2)

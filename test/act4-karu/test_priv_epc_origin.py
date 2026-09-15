#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check ACT EPC interpretation using nominal trap origin, not data privilege.

This evaluates only the emitted, bounded root-selection block, terminating at
its relocation decision. Full exception execution is checked by ACT references.
ACT_ENV may select an isolated patched header copy for pre-application checks.
"""

import os
from pathlib import Path
import shutil
import tempfile
import unittest

from test_h_trap_harness import ACT, HERE, WORK, XCHAIN, FIXTURE, Image, run
from test_priv_trap_lifecycle import signed


class OriginTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="act-epc-origin-")
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        cls.images = {}
        for version in ("current", "before"):
            headers = root / version / "tests/env"
            shutil.copytree(Path(os.environ.get("ACT_ENV", ACT / "tests/env")), headers)
            if version == "before":
                run([
                    "patch", "--batch", "--reverse", "--fuzz=0", "--no-backup-if-mismatch", "-p1",
                    "-d", str(root / version), "-i", str(HERE / "patches/priv-epc-origin.patch"),
                ])
            source = root / "fixture.S"
            source.write_text(FIXTURE)
            elf = root / (version + ".elf")
            run([
                XCHAIN + "gcc", "-march=rv64i_zicsr_zifencei", "-mabi=lp64",
                "-nostdlib", "-mcmodel=medany", "-Wl,--no-warn-rwx-segments",
                "-DRVTEST_NOSIG", "-DTEST_FLEN=0", '-DTEST_FILE="origin.S"', "-DSIGNATURE",
                "-DSAIL_CLINT_BASE_ADDRESS=0x2000000",
                "-DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0x3000000",
                "-I" + str(WORK), "-I" + str(headers), "-I" + str(HERE / "karu64-rv64gc"),
                "-T" + str(HERE / "karu64-rv64gc/link.ld"), "-o", str(elf), str(source),
            ])
            cls.images[version] = Image(elf)

    def decision(self, *, version="current", mpp=1, mpv=0, mprv=0, satp=0, vsatp=0, hgatp=0):
        image = self.images[version]
        symbols = image.symbols
        base = symbols["Mtramptbl_sv"]
        regs = [0] * 32
        regs[2] = base
        csrs = {0x341: 0x14000D002, 0x300: (mpp << 11) | (mprv << 17) | (mpv << 39),
                0x180: satp << 60, 0x280: vsatp << 60, 0x680: hgatp << 60, 0x301: 0x80}
        reads = []
        pc = symbols["common_Mexcpt_handler"]
        stops = {symbols["sv_Mepc"]: "virtual", symbols["vmem_adj_Mepc"]: "relocate"}
        mask = (1 << 64) - 1
        for _ in range(100):
            if pc in stops:
                return stops[pc], regs[9] - base, reads
            word = int.from_bytes(image.data[pc - image.base:pc - image.base + 4], "little")
            opcode, rd, rs1, rs2, funct = word & 127, word >> 7 & 31, word >> 15 & 31, word >> 20 & 31, word >> 12 & 7
            next_pc = pc + 4
            imm = signed(word >> 20, 12)
            if opcode == 0x73 and funct == 2:
                reads.append(word >> 20)
                regs[rd] = csrs[word >> 20]
            elif opcode == 0x13 and funct == 0:
                regs[rd] = regs[rs1] + imm
            elif opcode == 0x13 and funct == 1:
                regs[rd] = regs[rs1] << (word >> 20 & 63)
            elif opcode == 0x13 and funct == 5:
                regs[rd] = regs[rs1] >> (word >> 20 & 63)
            elif opcode == 0x13 and funct == 7:
                regs[rd] = regs[rs1] & imm
            elif opcode == 0x33 and funct == 0:
                regs[rd] = regs[rs1] + regs[rs2]
            elif opcode == 0x37:
                regs[rd] = signed(word & 0xFFFFF000, 32)
            elif opcode == 0x03:
                # The old MPRV path reads a never-populated saved-MPP field.
                regs[rd] = 0
            elif opcode == 0x63:
                offset = signed(((word >> 31) << 12) | ((word >> 7 & 1) << 11)
                                | ((word >> 25 & 63) << 5) | ((word >> 8 & 15) << 1), 13)
                condition = {0: regs[rs1] == regs[rs2], 1: regs[rs1] != regs[rs2],
                             4: signed(regs[rs1], 64) < signed(regs[rs2], 64),
                             5: signed(regs[rs1], 64) >= signed(regs[rs2], 64)}[funct]
                if condition:
                    next_pc = pc + offset
            elif opcode == 0x6F:
                offset = signed(((word >> 31) << 20) | (word & 0xFF000)
                                | ((word >> 20 & 1) << 11) | ((word >> 21 & 1023) << 1), 21)
                regs[rd] = pc + 4
                next_pc = pc + offset
            else:
                self.fail(f"unrecognized root-selection instruction {word:08x} at {pc:x}")
            regs[rd] &= mask
            regs[0] = 0
            pc = next_pc
        self.fail("root-selection block did not reach a bounded decision")

    def test_host_ignores_guest_roots_and_mprv(self):
        stride = self.images["current"].symbols["Msv_area_end"] - self.images["current"].symbols["Mtramptbl_sv"]
        for mpp in (0, 1):
            for mprv in (0, 1):
                for satp, guest in ((8, 0), (0, 8)):
                    decision, frame, reads = self.decision(mpp=mpp, mprv=mprv, satp=satp, vsatp=guest, hgatp=guest)
                    self.assertEqual(decision, "virtual" if satp else "relocate")
                    self.assertEqual(frame, stride)
                    self.assertNotIn(0x280, reads)
                    self.assertNotIn(0x680, reads)

    def test_guest_checks_both_stages_and_uses_vs_frame(self):
        stride = self.images["current"].symbols["Msv_area_end"] - self.images["current"].symbols["Mtramptbl_sv"]
        for mpp in (0, 1):
            for mprv in (0, 1):
                for vsatp, hgatp in ((0, 0), (8, 0), (0, 8), (8, 8)):
                    decision, frame, reads = self.decision(mpp=mpp, mpv=1, mprv=mprv, satp=8, vsatp=vsatp, hgatp=hgatp)
                    self.assertEqual(decision, "virtual" if vsatp or hgatp else "relocate")
                    self.assertEqual(frame, 3 * stride)
                    self.assertNotIn(0x180, reads)

    def test_nominal_m_fetch_ignores_all_data_context(self):
        for mprv in (0, 1):
            for mpv in (0, 1):
                decision, frame, reads = self.decision(mpp=3, mpv=mpv, mprv=mprv, satp=8, vsatp=8, hgatp=8)
                self.assertEqual((decision, frame), ("relocate", 0))
                self.assertEqual(reads, [0x341, 0x300])

    def test_prepatch_controls_expose_wrong_root_and_mprv_semantics(self):
        decision, _, reads = self.decision(version="before", satp=8, hgatp=0)
        self.assertEqual(decision, "relocate")
        self.assertIn(0x680, reads)
        decision, _, _ = self.decision(version="before", mpp=3, mprv=1, satp=8, hgatp=8)
        self.assertEqual(decision, "virtual")


if __name__ == "__main__":
    unittest.main(verbosity=2)

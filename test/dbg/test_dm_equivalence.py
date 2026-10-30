"""AUTOEXEC=0 reuse must prove the dead guard and reject a live alteration."""
# SPDX-License-Identifier: BSD-2-Clause
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "dbg"))
import dm_equivalence
import source_equivalence


class DmEquivalenceTest(unittest.TestCase):
    def test_dead_parameter_and_failing_control(self):
        if not shutil.which("yosys"):
            self.skipTest("Yosys not installed")
        with tempfile.TemporaryDirectory(dir=source_equivalence.REPO / "_build/dbg") as directory:
            root = Path(directory)
            old, new = root / "old.v", root / "new.v"
            template = """module karudbg #(
parameter AUTOEXEC=0,
`ifdef KARU_DBG_SBA
parameter SBA=1
`else
parameter SBA=0
`endif
)(input clk,rst,explicit_write,valid,input [3:0] word,output reg [3:0] q);
always @(posedge clk) begin
if(rst)q<=0;
else begin
GUARD
if(explicit_write&&valid)q<=word;
end
end
endmodule
"""
            old.write_text(template.replace("GUARD", ""))
            new.write_text(template.replace("GUARD", "if(AUTOEXEC&&explicit_write)q<=word;"))
            for flags in ([], ["KARU_DBG_SBA"], ["KARU_DBG_TRIGGERS"]):
                row = "sba" if "KARU_DBG_SBA" in flags else "triggers" if flags else "base"
                result = dm_equivalence.execute(source_equivalence.REPO, flags, [old], [new], old, new,
                                                root / row, source_equivalence.record)
                self.assertEqual(result["parameters"]["AUTOEXEC"], 0)
                dm_equivalence.verify(result, source_equivalence.REPO, flags, [old], [new], old, new,
                                      root / row, source_equivalence.record)
            with self.assertRaisesRegex(ValueError, "enabled autoexec"):
                dm_equivalence.execute(source_equivalence.REPO, ["KARU_DBG_AUTOEXEC"], [old], [new],
                                       old, new, root / "ae", source_equivalence.record)
            new.write_text(template.replace("GUARD", "if(!AUTOEXEC&&explicit_write)q<=word;"))
            with self.assertRaisesRegex(ValueError, "equivalence failed"):
                dm_equivalence.execute(source_equivalence.REPO, [], [old], [new], old, new,
                                       root / "corrupt", source_equivalence.record)


if __name__ == "__main__":
    unittest.main()

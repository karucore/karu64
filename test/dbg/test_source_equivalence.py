"""Lexical reuse proofs retain semantic tokens and cover macro leakage."""
# SPDX-License-Identifier: BSD-2-Clause
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "dbg"))
import source_equivalence as proof


class SourceEquivalenceTest(unittest.TestCase):
    def test_whitespace_and_line_bookkeeping_only(self):
        left = '`line 1 "old.v" 0\nmodule m; wire [7:0] x; endmodule\n'
        right = '`line 99 "current.v" 2\n module\tm ;\nwire [ 7 : 0 ] x ; endmodule\n'
        self.assertEqual(proof.tokenize(left), proof.tokenize(right))

    def test_strings_and_escaped_identifiers_are_not_comments(self):
        a = r'module m; wire \a//b ; initial $display("/* value */ //"); endmodule'
        self.assertIn(("escaped_identifier", r"\a//b"), proof.tokenize(a))
        self.assertIn(("string", '"/* value */ //"'), proof.tokenize(a))
        self.assertNotEqual(proof.tokenize(a), proof.tokenize(a.replace("value", "other")))
        self.assertNotEqual(proof.tokenize(r"wire \a.b ;"), proof.tokenize(r"wire \a .b;"))

    def test_synthesis_comments_and_attributes_are_retained(self):
        a = "module m; // synthesis translate_off\nwire x; // synthesis translate_on\nendmodule"
        self.assertNotEqual(proof.tokenize(a), proof.tokenize(a.replace("translate_off", "translate_on")))
        self.assertNotEqual(proof.tokenize("// synopsys full_case\ncase(x)"),
                            proof.tokenize("// synopsys parallel_case\ncase(x)"))
        self.assertNotEqual(proof.tokenize('(* keep = 1 *) wire a;'), proof.tokenize('wire a;'))
        self.assertNotEqual(proof.tokenize("a/**/b"), proof.tokenize("ab"))

    def test_operators_and_literals_preserve_boundaries(self):
        self.assertNotEqual(proof.tokenize("a <= b"), proof.tokenize("a < = b"))
        self.assertNotEqual(proof.tokenize("64'hffff"), proof.tokenize("32'hffff"))
        self.assertEqual(proof.tokenize("64'h ff"), proof.tokenize("64'hff"))
        self.assertNotEqual(proof.tokenize("a >>> b"), proof.tokenize("a >> b"))

    def test_invalid_lexical_input_is_rejected(self):
        for text in ('"unterminated', "/* unterminated", "wire\u00a0a;", "\\ "):
            with self.subTest(text=text), self.assertRaises(ValueError):
                proof.tokenize(text)

    def test_entire_manifest_detects_macro_leakage(self):
        if not shutil.which("iverilog"):
            self.skipTest("iverilog not installed")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, new, later, prelude = (root / name for name in ("old.v", "new.v", "later.v", "prelude.vh"))
            old.write_text("`define LEAK\n")
            new.write_text("`undef LEAK\n")
            later.write_text("module m;\n`ifdef LEAK\nwire a;\n`else\nwire b;\n`endif\nendmodule\n")
            prelude.write_text(proof.PRELUDE)
            tool = Path(shutil.which("iverilog")).resolve()
            _, old_one = proof.preprocess(tool, [], prelude, [old])
            _, new_one = proof.preprocess(tool, [], prelude, [new])
            self.assertEqual(proof.token_identity(old_one), proof.token_identity(new_one))
            _, old_all = proof.preprocess(tool, [], prelude, [old, later])
            _, new_all = proof.preprocess(tool, [], prelude, [new, later])
            self.assertNotEqual(proof.token_identity(old_all), proof.token_identity(new_all))


if __name__ == "__main__":
    unittest.main()

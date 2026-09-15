#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Positive and negative controls for the KVM UART completion protocol."""

from pathlib import Path
import sys
import tempfile
import time
import unittest

from run import run

PASS_LINES = (
    "[KVM-KARU] RUN ebreak_test\n"
    "[KVM-KARU] PASS ebreak_test exit=0\n"
    "[KVM-KARU] RUN arch_timer\n"
    "[KVM-KARU] PASS arch_timer exit=0\n"
    "[KVM-KARU] COMPLETE tests=2 failed=0 skipped=0\n"
)


class RunnerTest(unittest.TestCase):
    def check_transcript(self, transcript, expected, hold=False):
        with tempfile.TemporaryDirectory(prefix="karu-kvm-runner-") as temporary:
            # One small pipe write keeps completion and any following failure
            # in the same available output chunk for the parser controls.
            code = f"import os,time;os.write(1, {transcript.encode()!r})"
            if hold:
                code += ";time.sleep(10)"
            result = run([sys.executable, "-c", code], Path(temporary) / "run.log", 0.5, echo=False)
            self.assertEqual(result, expected)

    def test_both_completed_guests_pass_and_stop(self):
        self.check_transcript(PASS_LINES, 0, hold=True)

    def test_host_boot_is_not_guest_completion(self):
        self.check_transcript("Linux version 7.1.2\nkvm: hypervisor extension available\n", 1)

    def test_completion_without_guest_results_fails(self):
        self.check_transcript(PASS_LINES.splitlines()[-1] + "\n", 1)

    def test_skipped_guest_fails(self):
        self.check_transcript("[KVM-KARU] RUN ebreak_test\n[KVM-KARU] FAIL ebreak_test wait_status=1024\n", 1)

    def test_duplicate_guest_result_fails(self):
        self.check_transcript(PASS_LINES.split("[KVM-KARU] RUN arch_timer")[0] + PASS_LINES, 1)

    def test_missing_marker_fails(self):
        self.check_transcript(PASS_LINES.rsplit("[KVM-KARU] COMPLETE", 1)[0], 1)

    def test_partial_line_timeout_fails(self):
        self.check_transcript("[KVM-KARU] COMPL", 1, hold=True)

    def test_kernel_panic_fails(self):
        self.check_transcript("Kernel panic - not syncing: test panic\n" + PASS_LINES, 1)

    def test_buffered_kernel_panic_after_completion_fails(self):
        self.check_transcript(PASS_LINES + "Kernel panic - not syncing: test panic\n", 1, hold=True)

    def test_buffered_rtl_error_after_completion_fails(self):
        self.check_transcript(PASS_LINES + "%Error: test assertion\n", 1, hold=True)

    def test_buffered_failure_after_completion_fails(self):
        self.check_transcript(PASS_LINES + "[KVM-KARU] FAIL timeout\n", 1, hold=True)

    def test_buffered_duplicate_result_after_completion_fails(self):
        self.check_transcript(PASS_LINES + "[KVM-KARU] PASS arch_timer exit=0\n", 1, hold=True)

    def test_buffered_duplicate_completion_fails(self):
        self.check_transcript(PASS_LINES + PASS_LINES.splitlines()[-1] + "\n", 1, hold=True)

    def test_buffered_benign_output_after_completion_passes(self):
        self.check_transcript(PASS_LINES + "[linux_tb] heartbeat\n", 0, hold=True)

    def test_closed_output_does_not_wait_for_live_process(self):
        with tempfile.TemporaryDirectory(prefix="karu-kvm-runner-") as temporary:
            code = "import os,time;os.close(1);os.close(2);time.sleep(2)"
            started = time.monotonic()
            result = run([sys.executable, "-c", code], Path(temporary) / "run.log", 0.1, echo=False)
            self.assertEqual(result, 1)
            # Leave scheduling slack but reject waiting for the child's sleep.
            self.assertLess(time.monotonic() - started, 1.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

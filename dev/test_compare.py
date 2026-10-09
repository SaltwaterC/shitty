#!/usr/bin/env python3
# Copyright (C) 2026 Shitty team
# MIT licensed
# See the file LICENSE.MIT for the full license.

"""Process lifecycle regressions for compare.py; no GUI required."""

import contextlib
import io
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import termios
import time
import unittest

import compare


class FakeTerminal:
    name = "fake"

    def __init__(self, program):
        self.program = program
        self.calls = 0

    def argv(self, command):
        self.calls += 1
        return [sys.executable, "-c", self.program]


class CompareTests(unittest.TestCase):
    def assert_stopped(self, pid):
        # An orphan may briefly remain a zombie until init reaps it.
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            status = Path(f"/proc/{pid}/stat")
            if status.exists() and status.read_text().split(") ", 1)[1].startswith("Z"):
                return
            time.sleep(0.01)
        self.fail(f"process {pid} is still running")

    def child_program(self, pidfile, exit_parent):
        return (
            "import os, time\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "    time.sleep(60)\n"
            "else:\n"
            f"    open({str(pidfile)!r}, 'w').write(str(pid))\n"
            + ("    os._exit(0)\n" if exit_parent else "    time.sleep(60)\n")
        )

    def test_exited_parent_with_inherited_stderr_does_not_hang(self):
        with tempfile.TemporaryDirectory() as work:
            pidfile = Path(work) / "pid"
            started = time.monotonic()
            result = compare.run([sys.executable, "-c", self.child_program(pidfile, True)], timeout=2)
            self.assertEqual(result.returncode, 0)
            self.assertLess(time.monotonic() - started, 2)
            self.assert_stopped(int(pidfile.read_text()))

    def test_timeout_cleans_descendants_and_preserves_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                     start_new_session=True)
        try:
            with tempfile.TemporaryDirectory() as work:
                pidfile = Path(work) / "pid"
                with self.assertRaises(subprocess.TimeoutExpired):
                    compare.run([sys.executable, "-c", self.child_program(pidfile, False)], timeout=0.3)
                self.assert_stopped(int(pidfile.read_text()))
                self.assertIsNone(unrelated.poll())
        finally:
            unrelated.kill()
            unrelated.wait(timeout=5)

    def test_crash_is_rejected_even_when_time_reports_measurements(self):
        terminal = FakeTerminal("import os; os._exit(139)")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = compare.bench(terminal, Path("random.bin"), 3, timeout=2)
        self.assertIsNone(result)
        self.assertEqual(terminal.calls, 1)
        self.assertIn("exit 139", output.getvalue())

    def test_timeout_is_reported_and_next_terminal_can_run(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            failed = compare.bench(FakeTerminal("import time; time.sleep(60)"),
                                   Path("random.bin"), 1, timeout=0.1)
            success = compare.bench(FakeTerminal("import time; time.sleep(0.1)"),
                                    Path("random.bin"), 1, timeout=2)
        self.assertIsNone(failed)
        self.assertIn("timed out", output.getvalue())
        self.assertGreater(success["real"], 0)

    def test_ctrl_c_cleans_descendants(self):
        with tempfile.TemporaryDirectory() as work:
            pidfile = Path(work) / "pid"
            program = self.child_program(pidfile, False)
            # The launched parent interrupts the test runner after recording its child.
            program = program.rsplit("    time.sleep(60)\n", 1)[0] + (
                "    import signal\n"
                "    os.kill(os.getppid(), signal.SIGINT)\n"
                "    time.sleep(60)\n"
            )
            with self.assertRaises(KeyboardInterrupt):
                compare.run([sys.executable, "-c", program], timeout=2)
            self.assert_stopped(int(pidfile.read_text()))


class WriterTests(unittest.TestCase):
    """WRITER must put on the wire exactly what cat would, and leave the tty as it found it."""

    PAYLOAD = b"line\nalready crlf\r\nbare cr\rtab\tbackspace\b\x04eot\xff\xfe\n\n"

    def through_pty(self, argv, oflag_change=lambda oflag: oflag):
        master, slave = pty.openpty()
        try:
            attrs = termios.tcgetattr(slave)
            attrs[1] = oflag_change(attrs[1])
            termios.tcsetattr(slave, termios.TCSANOW, attrs)
            before = termios.tcgetattr(slave)
            subprocess.run(argv, stdout=slave, check=True, timeout=10)
            after = termios.tcgetattr(slave)
            # The test keeps the slave open to read its settings back, so the
            # master never reports end of file; read until it goes quiet.
            received = b""
            while select.select([master], [], [], 0.2)[0]:
                received += os.read(master, 65536)
            return received, before, after
        finally:
            os.close(master)
            os.close(slave)

    def assert_matches_cat(self, oflag_change=lambda oflag: oflag):
        with tempfile.TemporaryDirectory() as work:
            payload = Path(work) / "payload.bin"
            payload.write_bytes(self.PAYLOAD)
            writer = Path(work) / "write.py"
            writer.write_text(compare.WRITER)
            expected, _, _ = self.through_pty(["cat", str(payload)], oflag_change)
            received, before, after = self.through_pty(
                [sys.executable, str(writer), str(payload)], oflag_change)
        self.assertEqual(received, expected)
        self.assertEqual(after, before)
        return received

    def test_default_output_processing_is_reproduced(self):
        received = self.assert_matches_cat()
        self.assertIn(b"line\r\nalready crlf\r\r\n", received)

    def test_output_processing_is_off_while_writing(self):
        # Matching bytes cannot tell the fast path from the kernel's, so look
        # at the tty while the writer waits for its payload to be opened.
        with tempfile.TemporaryDirectory() as work:
            payload = Path(work) / "payload"
            os.mkfifo(payload)
            writer = Path(work) / "write.py"
            writer.write_text(compare.WRITER)
            master, slave = pty.openpty()
            process = subprocess.Popen([sys.executable, str(writer), str(payload)], stdout=slave)
            try:
                deadline = time.monotonic() + 5
                while termios.tcgetattr(slave)[1] & termios.OPOST:
                    self.assertLess(time.monotonic(), deadline, "OPOST was never switched off")
                    time.sleep(0.01)
                payload.write_bytes(b"done\n")
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertTrue(termios.tcgetattr(slave)[1] & termios.OPOST)
            finally:
                process.kill()
                process.wait()
                os.close(master)
                os.close(slave)

    def test_other_output_flags_are_left_to_the_kernel(self):
        self.assert_matches_cat(lambda oflag: oflag | termios.OCRNL)

    def test_disabled_output_processing_passes_bytes_through(self):
        received = self.assert_matches_cat(lambda oflag: oflag & ~termios.OPOST)
        self.assertEqual(received, self.PAYLOAD)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
# Copyright (C) 2026 Shitty team
# MIT licensed
# See the file LICENSE.MIT for the full license.

"""Native Windows benchmark lifecycle regressions; no GUI required."""

import array
import ctypes
from ctypes import wintypes
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import compare_windows as compare


class GeometryTests(unittest.TestCase):
    def fixture(self):
        # Two columns by two rows of 4x6 pixels, surrounded by window chrome.
        colors = [blue | green << 8 | red << 16
                  for red, green, blue in compare.geometry.COLORS]
        pixels = array.array("I", [0xF0F0F0] * (12 * 16))
        for y in range(12):
            for x in range(8):
                pixels[(y + 2) * 12 + x + 2] = colors[(x // 4 + y // 6) % 2]
        return pixels

    def test_measures_content_independently_of_chrome(self):
        self.assertEqual(compare.geometry.measure_pixels(self.fixture().tobytes(), 12, 16, 2, 2), (4, 6))

    def test_rejects_occluded_content(self):
        pixels = self.fixture()
        pixels[3 * 12 + 3] = 0xF0F0F0
        with self.assertRaisesRegex(RuntimeError, "occluded"):
            compare.geometry.measure_pixels(pixels.tobytes(), 12, 16, 2, 2)

    def test_rejects_inconsistent_spacing(self):
        pixels = self.fixture()
        pixels[4 * 12 + 3] = pixels[4 * 12 + 7]
        with self.assertRaisesRegex(RuntimeError, "inconsistent"):
            compare.geometry.measure_pixels(pixels.tobytes(), 12, 16, 2, 2)

    def test_accepts_fractional_dpi_edge_rounding(self):
        pixels = self.fixture()
        for y in range(12):
            pixels[(y + 2) * 12 + 6] = pixels[(y + 2) * 12 + 5]
        self.assertEqual(compare.geometry.measure_pixels(pixels.tobytes(), 12, 16, 2, 2), (4, 6))


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell required")
class PowerShellTests(unittest.TestCase):
    def test_powershell_preserves_arguments_and_native_exit_code(self):
        with tempfile.TemporaryDirectory(prefix="shell ' $ Ω ") as directory:
            output = Path(directory) / "arguments.json"
            terminal = compare.Alacritty(Path(directory), sys.executable)
            arguments = ["a'b", "$env:PATH", "a`b", 'double"quote', "space value", "Ω", ""]
            program = (
                "import json, sys; from pathlib import Path; "
                "Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:])); sys.exit(7)"
            )
            for name in ("pwsh.exe", "powershell.exe"):
                shell = compare.shutil.which(name)
                if shell is None:
                    continue
                with self.subTest(shell=name):
                    terminal.powershell = shell
                    command = compare.powershell_command([sys.executable, "-c", program, str(output), *arguments], shell=shell)
                    completed = subprocess.run(command, capture_output=True, timeout=10)
                    self.assertEqual(completed.returncode, 7, completed.stderr)
                    self.assertEqual(json.loads(output.read_text()), arguments)

    def test_cat_preserves_payload_bytes_and_records_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload.bin"
            result = root / "result.json"
            data = bytes(range(256)) * 16
            payload.write_bytes(data)
            command = compare.powershell_command([str(compare.find_cat()), "--", str(payload)],
                                                 result, {"bytes": len(data)})
            completed = subprocess.run(command, capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout, data)
            self.assertEqual(json.loads(result.read_text(encoding="utf-8-sig")), {"bytes": len(data)})

    def test_failed_cat_does_not_record_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "result.json"
            command = compare.powershell_command([str(compare.find_cat()), "--", str(root / "missing.bin")],
                                                 result, {"bytes": 0})
            completed = subprocess.run(command, capture_output=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(result.exists())


class AlacrittyDownloadTests(unittest.TestCase):
    def terminal(self, root):
        with mock.patch.object(compare.Alacritty, "discover", return_value=None):
            return compare.Alacritty(Path(root) / "session")

    def test_missing_installation_downloads_and_reuses_complete_cache(self):
        archive = io.BytesIO(b"MZtest executable")
        with tempfile.TemporaryDirectory() as directory:
            terminal = self.terminal(directory)
            terminal.powershell = "powershell.exe"
            with mock.patch.object(compare.urllib.request, "urlopen", return_value=archive) as download:
                self.assertTrue(terminal.prepare())
                executable = terminal.executable
                self.assertEqual(executable.read_bytes(), b"MZtest executable")
                self.assertEqual(self.terminal(directory).portable_source(), executable)
                download.assert_called_once()
                self.assertIn(f"/releases/download/v{compare.ALACRITTY_VERSION}/Alacritty-v", download.call_args.args[0])

    def test_broken_download_does_not_create_cache_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = self.terminal(directory)
            with mock.patch.object(compare.urllib.request, "urlopen", return_value=io.BytesIO(b"broken ZIP")):
                with self.assertRaisesRegex(RuntimeError, "not a Windows executable"):
                    terminal.portable_source()
            self.assertEqual(list((Path(directory) / "alacritty-cache").iterdir()), [])

    def test_invalid_explicit_path_does_not_download(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = compare.Alacritty(Path(directory), Path(directory) / "missing.exe")
            terminal.powershell = "powershell.exe"
            with mock.patch.object(compare.urllib.request, "urlopen") as download:
                with self.assertRaisesRegex(RuntimeError, "does not exist"):
                    terminal.prepare()
                download.assert_not_called()


class StoreSourceTests(unittest.TestCase):
    PACKAGE = subprocess.CompletedProcess([], 0,
        stdout='{"version":"1.24.12741.0","architecture":"x64"}', stderr="")

    def terminal(self, root):
        with mock.patch.object(compare.WindowsTerminal, "discover", return_value=None):
            return compare.WindowsTerminal(Path(root) / "session")

    def test_download_matches_installed_version_and_is_cached(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as distribution:
            distribution.writestr("terminal/WindowsTerminal.exe", b"test executable")
            distribution.writestr("terminal/dependency.dll", b"test dependency")
        archive.seek(0)
        with tempfile.TemporaryDirectory() as directory:
            terminal = self.terminal(directory)
            with mock.patch.object(compare.subprocess, "run", return_value=self.PACKAGE), \
                 mock.patch.object(compare.urllib.request, "urlopen", return_value=archive) as download:
                executable = terminal.store_source()
                self.assertEqual(executable.read_bytes(), b"test executable")
                self.assertEqual(executable.with_name("dependency.dll").read_bytes(), b"test dependency")
                self.assertEqual(terminal.store_source(), executable)
                download.assert_called_once_with(
                    "https://github.com/microsoft/terminal/releases/download/v1.24.12741.0/"
                    "Microsoft.WindowsTerminal_1.24.12741.0_x64.zip", timeout=30)

    def test_broken_download_does_not_create_cache_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = self.terminal(directory)
            with mock.patch.object(compare.subprocess, "run", return_value=self.PACKAGE), \
                 mock.patch.object(compare.urllib.request, "urlopen", return_value=io.BytesIO(b"broken ZIP")):
                with self.assertRaisesRegex(RuntimeError, "portable download failed"):
                    terminal.store_source()
            self.assertEqual(list((Path(directory) / "windows-terminal-cache").iterdir()), [])

    def test_missing_installation_does_not_download(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = self.terminal(directory)
            with mock.patch.object(compare.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="")), \
                 mock.patch.object(compare.urllib.request, "urlopen") as download:
                with self.assertRaisesRegex(RuntimeError, "not installed"):
                    terminal.store_source()
                download.assert_not_called()


class FakeTerminal:
    name = "fake"

    def __init__(self, work, program):
        self.work = work
        self.program = program

    def argv(self, command):
        return [sys.executable, "-c", self.program.replace("RESULT_PATH", repr(command[4]))]


@unittest.skipUnless(sys.platform == "win32", "Windows job objects required")
class CompareWindowsTests(unittest.TestCase):
    def assert_stopped(self, pid):
        dll = ctypes.WinDLL("kernel32", use_last_error=True)
        dll.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        dll.OpenProcess.restype = wintypes.HANDLE
        dll.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        dll.WaitForSingleObject.restype = wintypes.DWORD
        dll.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = dll.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
        if handle:
            try:
                self.assertEqual(dll.WaitForSingleObject(handle, 2000), 0)
            finally:
                dll.CloseHandle(handle)
        else:
            self.assertEqual(ctypes.get_last_error(), 87)  # PID no longer exists.

    def test_workload_timing_excludes_startup_wall_and_cpu(self):
        with tempfile.TemporaryDirectory() as directory:
            timing = Path(directory) / "workload.time.json"
            program = "\n".join([
                "import time; from pathlib import Path",
                f"timing = Path({str(timing)!r})",
                "def burn(seconds):",
                "    end = time.process_time() + seconds",
                "    while time.process_time() < end: pass",
                "burn(0.5)",
                "time.sleep(0.5)",
                "timing.with_suffix('.ready').touch()",
                "while not timing.with_suffix('.start').exists(): time.sleep(0.01)",
                "timing.with_suffix('.started').write_text(str(time.perf_counter()))",
                "burn(0.1)",
                "time.sleep(0.2)",
            ])
            completed = subprocess.run([
                sys.executable, str(compare.SCRIPT), "--supervise", str(timing),
                json.dumps([sys.executable, "-c", program]), "cat",
            ], capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            measured = json.loads(timing.read_text())
            self.assertGreaterEqual(measured["real"], 0.3)
            self.assertLess(measured["real"], 1.0)
            cpu = measured["user"] + measured["sys"]
            self.assertGreater(cpu, 0.05)
            self.assertLess(cpu, 0.4)

    def test_workload_exit_before_ready_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            timing = Path(directory) / "workload.time.json"
            completed = subprocess.run([
                sys.executable, str(compare.SCRIPT), "--supervise", str(timing),
                json.dumps([sys.executable, "-c", "pass"]), "cat",
            ], capture_output=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(b"workload never became ready", completed.stderr)
            self.assertFalse(timing.exists())

    def test_waits_for_descendant_after_launcher_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            child = (
                "import time; from pathlib import Path; time.sleep(0.2); "
                "Path(RESULT_PATH).write_text('[80, 24]')"
            )
            terminal = FakeTerminal(work, "")
            # Replace the placeholder inside the child program without nested
            # quoting ambiguities in the launcher source.
            def argv(command):
                program = child.replace("RESULT_PATH", repr(command[4]))
                return [sys.executable, "-c",
                        f"import subprocess, sys; subprocess.Popen([sys.executable, '-c', {program!r}])"]
            terminal.argv = argv
            result, timing = compare.run(terminal, "probe", 5)
            self.assertEqual(result, [80, 24])
            self.assertGreater(timing["real"], 0.2)
            self.assertGreaterEqual(timing["user"], 0)
            self.assertEqual(list(work.iterdir()), [])

    def test_crash_with_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = FakeTerminal(Path(directory),
                "import os; from pathlib import Path; Path(RESULT_PATH).write_text('[80, 24]'); os._exit(7)")
            with self.assertRaisesRegex(RuntimeError, "exit 7"):
                compare.run(terminal, "probe", 5)

    def test_success_without_child_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = FakeTerminal(Path(directory), "pass")
            with self.assertRaisesRegex(RuntimeError, "missing or failed child"):
                compare.run(terminal, "probe", 5)

    def test_timeout_kills_orphan_and_preserves_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            with tempfile.TemporaryDirectory() as directory:
                work = Path(directory)
                pidfile = work / "pid"
                program = (
                    "import subprocess, sys; from pathlib import Path; "
                    "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                    f"Path({str(pidfile)!r}).write_text(str(child.pid))"
                )
                with self.assertRaises(subprocess.TimeoutExpired):
                    compare.run(FakeTerminal(work, program), "probe", 1)
                self.assert_stopped(int(pidfile.read_text()))
                self.assertIsNone(unrelated.poll())
        finally:
            unrelated.kill()
            unrelated.wait(timeout=5)



@unittest.skipUnless(sys.platform == "win32", "Windows ConPTY required")
class NativeRelayTests(unittest.TestCase):
    def test_supervised_relay_completes_and_cleans_timing_handshake(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload.bin"
            data = bytes(range(256)) * 1024
            payload.write_bytes(data)
            terminal = FakeTerminal(root, "")
            terminal.argv = lambda command: command
            completed, timing = compare.run(terminal, "cat", 10, payload)
            self.assertEqual(completed, {"bytes": len(data)})
            self.assertGreater(timing["real"], 0)
            self.assertGreaterEqual(timing["user"], 0)
            self.assertGreaterEqual(timing["sys"], 0)
            self.assertEqual(list(root.iterdir()), [payload])

    def test_partial_console_writes_keep_every_byte(self):
        data = bytes(range(256))
        buffer = ctypes.create_string_buffer(data)
        chunks = []
        dll = mock.Mock()
        def write(handle, pointer, size, written, overlapped):
            count = min(size, 7)
            chunks.append(ctypes.string_at(pointer, count))
            ctypes.cast(written, ctypes.POINTER(wintypes.DWORD)).contents.value = count
            return True
        dll.WriteFile.side_effect = write
        compare.write_console_bytes(dll, 1, buffer, len(data))
        self.assertEqual(b"".join(chunks), data)

    def test_zero_console_write_fails_instead_of_spinning(self):
        dll = mock.Mock()
        dll.WriteFile.return_value = True
        with self.assertRaisesRegex(RuntimeError, "no progress"):
            compare.write_console_bytes(dll, 1, ctypes.create_string_buffer(b"x"), 1)

    def test_invalid_utf8_and_escape_bytes_complete_in_real_conpty(self):
        from conpty_test_support import run_in_conpty
        import random
        cats = [compare.find_cat()]
        msys_cat = Path("C:/msys64/usr/bin/cat.exe")
        if msys_cat.is_file() and msys_cat not in cats:
            cats.append(msys_cat)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "random.bin"
            result = root / "result.json"
            data = random.Random(0x5117).randbytes(1_000_000)
            payload.write_bytes(data)
            for cat in cats:
                with self.subTest(cat=cat):
                    result.unlink(missing_ok=True)
                    code, output = run_in_conpty([sys.executable, str(compare.SCRIPT),
                        "--child", "cat", str(result), str(payload), str(cat)])
                    self.assertEqual(code, 0, bytes(output[-2000:]))
                    self.assertEqual(json.loads(result.read_text()), {"bytes": len(data)})
                    self.assertTrue(output)

    def test_relay_does_not_publish_success_for_a_failed_cat(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "result.json"
            completed = subprocess.run([sys.executable, str(compare.SCRIPT), "--child", "cat",
                                       str(result), str(root / "missing.bin"), str(compare.find_cat())],
                                      capture_output=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(result.exists())

    def test_relay_pipe_output_preserves_every_payload_byte(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, result = root / "payload.bin", root / "result.json"
            data = bytes(range(256)) * 1024
            payload.write_bytes(data)
            completed = subprocess.run([sys.executable, str(compare.SCRIPT), "--child", "cat",
                                       str(result), str(payload), str(compare.find_cat())],
                                      capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout, data)
            self.assertEqual(json.loads(result.read_text()), {"bytes": len(data)})

if __name__ == "__main__":
    unittest.main()

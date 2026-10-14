#!/usr/bin/env python3
# Copyright (C) 2026 Shitty team
# MIT licensed
# See the file LICENSE.MIT for the full license.

"""Native Windows throughput comparison of Windows Terminal, Zetta and Alacritty.

Uses cat.exe with the same 1GB ASCII and 100MB random payloads as compare.py. All GUIs
use Consolas 12pt (16 logical pixels), an 80x24 grid and 500 scrollback
lines. A visible checkerboard measures backing pixel cell dimensions before
benchmarking. Windows Terminal supplies the reference size; Zetta's --cell-size
and Alacritty's font.offset are adjusted to match and measured again.
Zetta uses its embedded console-server backend; Windows Terminal and Alacritty
use ConPTY. Random bytes pass through the selected Windows console backend;
results are not directly comparable to the Unix invalid-UTF-8 parser benchmark.

Measurements start when the shell has launched the byte relay and it is ready
to run cat, excluding GUI, shell and relay startup (including Defender delays).
Wall time includes workload execution and shutdown. CPU time covers the same
interval for the launcher, terminal and all children. Each launch has its own Windows job; timeouts and
Ctrl+C terminate that job without killing unrelated terminal instances.

Windows Terminal runs from a portable directory under --work with isolated
settings. If only the Store version is installed, its matching portable ZIP
is downloaded from Microsoft's GitHub releases and cached under --work.
An unpackaged WindowsTerminal.exe on PATH or supplied with --windows-terminal
is used directly as the source for the portable copy.
Requires Windows Terminal 1.18 or newer (portable mode) and Python 3.9+.
Portable mode: https://learn.microsoft.com/windows/terminal/distributions

Alacritty uses an isolated TOML configuration and runs cat through
PowerShell with profiles disabled, preferring pwsh.exe over powershell.exe.
Shell startup is excluded from its measurements. If Alacritty is
not installed, its portable release is downloaded and cached under --work.
The downloaded version is pinned for reproducible comparisons.
All benchmark targets launch the same byte relay through PowerShell. The relay
reads cat through a binary pipe and writes bytes to the console with WriteFile.
This avoids Rust console UTF-8 validation and MSYS console escape parsing in
cat itself. The relay waits for the supervisor to snapshot job CPU time before
starting cat; relay startup is excluded from every measurement.
cat.exe must be on PATH, supplied with --cat, or available in Git for Windows.
Keep every benchmark window visible and in front throughout its run.
An occluded geometry probe is rejected. Visibility during payload runs is not checked.

Usage:
    python dev/compare_windows.py --runs 3 --terminal windows-terminal
    python dev/compare_windows.py --terminal zetta --zetta C:\\Zetta\\zetta.exe
    python dev/compare_windows.py --terminal alacritty
"""

import argparse
import base64
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.request
import zipfile

import compare
import compare_windows_geometry as geometry

FONT = "Consolas"
FONT_POINTS = 12
FONT_PIXELS = 16
SCRIPT = Path(__file__).resolve()
ALACRITTY_VERSION = "0.17.0"


def kernel32():
    dll = ctypes.WinDLL("kernel32", use_last_error=True)
    signatures = {
        "CreateJobObjectW": ([ctypes.c_void_p, wintypes.LPCWSTR], wintypes.HANDLE),
        "SetInformationJobObject": ([wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD], wintypes.BOOL),
        "QueryInformationJobObject": ([wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p], wintypes.BOOL),
        "AssignProcessToJobObject": ([wintypes.HANDLE, wintypes.HANDLE], wintypes.BOOL),
        "GetCurrentProcess": ([], wintypes.HANDLE),
        "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
        "GetStdHandle": ([wintypes.DWORD], wintypes.HANDLE),
        "GetConsoleScreenBufferInfo": ([wintypes.HANDLE, ctypes.c_void_p], wintypes.BOOL),
        "GetConsoleMode": ([wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
        "SetConsoleMode": ([wintypes.HANDLE, wintypes.DWORD], wintypes.BOOL),
        "WriteFile": ([wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                       ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p], wintypes.BOOL),
    }
    for name, (args, result) in signatures.items():
        function = getattr(dll, name)
        function.argtypes = args
        function.restype = result
    return dll


def checked(result):
    if not result:
        raise ctypes.WinError(ctypes.get_last_error())
    return result


class JobLimits(ctypes.Structure):
    _fields_ = [
        ("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
        ("flags", wintypes.DWORD), ("min_working_set", ctypes.c_size_t),
        ("max_working_set", ctypes.c_size_t), ("active_limit", wintypes.DWORD),
        ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
        ("scheduling", wintypes.DWORD), ("io", ctypes.c_uint64 * 6),
        ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
        ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t),
    ]


class JobAccounting(ctypes.Structure):
    _fields_ = [
        ("user", ctypes.c_int64), ("kernel", ctypes.c_int64),
        ("period_user", ctypes.c_int64), ("period_kernel", ctypes.c_int64),
        ("faults", wintypes.DWORD), ("total", wintypes.DWORD),
        ("active", wintypes.DWORD), ("terminated", wintypes.DWORD),
    ]


class JobProcessIds(ctypes.Structure):
    _fields_ = [("assigned", wintypes.DWORD), ("count", wintypes.DWORD),
                ("ids", ctypes.c_size_t * 256)]


def supervise(argv, timing, workload=False):
    # Assign this helper before spawning anything: no race in which a GUI
    # launches descendants before it belongs to the job. The parent can kill
    # the helper to close the sole job handle and terminate every descendant.
    dll = kernel32()
    job = checked(dll.CreateJobObjectW(None, None))
    limits = JobLimits()
    limits.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    checked(dll.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
    checked(dll.AssignProcessToJobObject(job, dll.GetCurrentProcess()))
    started = time.perf_counter()
    process = subprocess.Popen(argv)
    accounting = JobAccounting()
    baseline = None
    ready = Path(timing).with_suffix(".ready")
    release = Path(timing).with_suffix(".start")
    ids = JobProcessIds()
    previous = None
    while True:
        checked(dll.QueryInformationJobObject(job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None))
        checked(dll.QueryInformationJobObject(job, 3, ctypes.byref(ids), ctypes.sizeof(ids), None))
        current = list(ids.ids[:ids.count])
        if current != previous:
            Path(timing).with_suffix(".pids.json").write_text(json.dumps(current), encoding="utf-8")
            previous = current
        if workload and baseline is None and ready.exists():
            # The relay is blocked until this snapshot excludes all startup CPU.
            baseline = (accounting.user, accounting.kernel)
            release.touch()
        code = process.poll()
        if code is not None and accounting.active == 1:  # Only this helper remains.
            break
        time.sleep(0.01)
    finished = time.perf_counter()
    if workload:
        if baseline is None:
            raise RuntimeError("workload never became ready")
        started = float(Path(timing).with_suffix(".started").read_text(encoding="utf-8"))
    else:
        baseline = (0, 0)
    Path(timing).write_text(json.dumps({
        "real": finished - started,
        "user": (accounting.user - baseline[0]) / 10_000_000,
        "sys": (accounting.kernel - baseline[1]) / 10_000_000,
    }), encoding="utf-8")
    # Leave the job handle open until helper exit; closing it kills us too.
    return code


def write_console_bytes(dll, output, buffer, size):
    offset = 0
    while offset < size:
        written = wintypes.DWORD()
        checked(dll.WriteFile(output, ctypes.byref(buffer, offset), size - offset,
                             ctypes.byref(written), None))
        if not 0 < written.value <= size - offset:
            raise RuntimeError("console write made no progress or returned an invalid count")
        offset += written.value


def cat_payload(result, payload, cat, timing=None):
    # A console stdout invokes Rust UTF-8 validation or MSYS escape parsing
    # inside cat. A binary pipe keeps cat a byte producer; only Windows' own
    # console backend should interpret bytes in this Windows benchmark.
    dll = kernel32()
    output = checked(dll.GetStdHandle(-11 & 0xFFFFFFFF))
    total = 0
    buffer = ctypes.create_string_buffer(65536)
    if timing is not None:
        Path(timing).with_suffix(".ready").touch()
        while not Path(timing).with_suffix(".start").exists():
            time.sleep(0.01)
        # Record the actual start in this process, avoiding supervisor polling
        # latency in wall time. perf_counter uses the same clock across processes.
        Path(timing).with_suffix(".started").write_text(str(time.perf_counter()), encoding="utf-8")
    process = subprocess.Popen([cat, "--", payload], stdout=subprocess.PIPE)
    try:
        with process.stdout:
            while size := process.stdout.readinto(buffer):
                write_console_bytes(dll, output, buffer, size)
                total += size
        code = process.wait()
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
    if code != 0:
        raise RuntimeError(f"cat exited with status {code}")
    expected = Path(payload).stat().st_size
    if total != expected:
        raise RuntimeError(f"cat wrote {total} bytes, expected {expected}")
    Path(result).write_text(json.dumps({"bytes": total}), encoding="utf-8")


def child(action, result, release=None, cat=None, timing=None):
    if action == "cat":
        cat_payload(result, release, cat, timing)
        return
    if action != "probe":
        raise ValueError(f"unknown child action: {action}")
    dll = kernel32()
    output = checked(dll.GetStdHandle(-11 & 0xFFFFFFFF))
    if action == "probe":
        class BufferInfo(ctypes.Structure):
            _fields_ = [("size", ctypes.c_short * 2), ("cursor", ctypes.c_short * 2),
                        ("attributes", wintypes.WORD), ("window", ctypes.c_short * 4),
                        ("maximum", ctypes.c_short * 2)]
        info = BufferInfo()
        deadline = time.monotonic() + 2
        last, since = None, time.monotonic()
        while True:
            checked(dll.GetConsoleScreenBufferInfo(output, ctypes.byref(info)))
            left, top, right, bottom = info.window
            data = [right - left + 1, bottom - top + 1]
            now = time.monotonic()
            if data != last:
                last, since = data, now
            if (data == [compare.COLUMNS, compare.ROWS] and now - since >= 0.3) or now >= deadline:
                break
            time.sleep(0.02)
    saved = wintypes.DWORD()
    if release:
        checked(dll.GetConsoleMode(output, ctypes.byref(saved)))
        checked(dll.SetConsoleMode(output, saved.value | 4))
        # A small fixture stays clear of scrollbars and rounded window corners.
        sys.stdout.write(geometry.checkerboard(min(data[0], 16), min(data[1], 8)))
        sys.stdout.flush()
        time.sleep(0.2)
    Path(result).write_text(json.dumps(data), encoding="utf-8")
    if release:
        try:
            deadline = time.monotonic() + 10
            while not Path(release).exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError("physical cell measurement did not complete")
                time.sleep(0.02)
        finally:
            sys.stdout.write("\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()
            dll.SetConsoleMode(output, saved.value)


class WindowsTerminal:
    name = "windows-terminal"

    def __init__(self, work, executable=None):
        self.work = work
        self.source = Path(executable) if executable else self.discover()
        self.executable = None

    @staticmethod
    def discover():
        executable = shutil.which("WindowsTerminal.exe")
        if executable and "windowsapps" not in str(Path(executable).parent).lower():
            return Path(executable)
        return None

    def store_source(self):
        installed = subprocess.run([
            "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
            "$package = Get-AppxPackage Microsoft.WindowsTerminal | "
            "Sort-Object Version -Descending | Select-Object -First 1; "
            "if ($package) { @{ version = $package.Version.ToString(); "
            "architecture = $package.Architecture.ToString().ToLowerInvariant() } | "
            "ConvertTo-Json -Compress }",
        ], capture_output=True, text=True, timeout=15)
        if installed.returncode != 0:
            raise RuntimeError("Windows Terminal discovery failed: " + installed.stderr.strip())
        if not installed.stdout.strip():
            raise RuntimeError("Windows Terminal not installed; install it or pass --windows-terminal")
        package = json.loads(installed.stdout)
        version, architecture = package["version"], package["architecture"]
        if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", version) or architecture not in {"x64", "x86", "arm64"}:
            raise RuntimeError(f"unsupported Windows Terminal package: {package}")
        cache_root = self.work.parent / "windows-terminal-cache"
        cache = cache_root / f"{version}-{architecture}"
        executable = cache / "WindowsTerminal.exe"
        if executable.is_file():
            return executable
        asset = f"Microsoft.WindowsTerminal_{version}_{architecture}.zip"
        url = f"https://github.com/microsoft/terminal/releases/download/v{version}/{asset}"
        print(f"windows-terminal: downloading portable {version} ({architecture})", flush=True)
        cache_root.mkdir(parents=True, exist_ok=True)
        # Publish only a complete extraction, so interrupted downloads never
        # become a cache hit. A temporary directory also separates concurrent runs.
        with tempfile.TemporaryDirectory(prefix="download-", dir=cache_root) as staging:
            staging = Path(staging)
            archive = staging / "terminal.zip"
            try:
                with urllib.request.urlopen(url, timeout=30) as response, archive.open("wb") as output:
                    shutil.copyfileobj(response, output)
                unpacked = staging / "unpacked"
                with zipfile.ZipFile(archive) as distribution:
                    distribution.extractall(unpacked)
                candidates = list(unpacked.rglob("WindowsTerminal.exe"))
                if len(candidates) != 1:
                    raise RuntimeError("portable archive does not contain one WindowsTerminal.exe")
                try:
                    candidates[0].parent.rename(cache)
                except FileExistsError:
                    if not executable.is_file():
                        raise
            except (OSError, zipfile.BadZipFile) as error:
                raise RuntimeError(f"portable download failed: {error}; "
                                   "pass --windows-terminal to use a local portable build") from error
        return executable

    def prepare(self):
        if self.source is None:
            self.source = self.store_source()
        if not self.source.is_file():
            raise RuntimeError(f"WindowsTerminal.exe does not exist: {self.source}")
        self.source = self.source.resolve()
        if "windowsapps" in str(self.source.parent).lower():
            raise RuntimeError("the Store executable requires its package; use the portable ZIP distribution")
        # A distinct path for this invocation also prevents handoff to another
        # benchmark invocation, which would escape this invocation's job.
        directory = self.work / f"windows-terminal-{uuid.uuid4().hex}"
        shutil.copytree(self.source.parent, directory,
                        ignore=shutil.ignore_patterns("settings", ".portable"))
        (directory / ".portable").touch()
        settings = directory / "settings"
        settings.mkdir()
        profile = "{" + str(uuid.uuid4()) + "}"
        (settings / "settings.json").write_text(json.dumps({
            # Startup sizing uses the default profile's font, even when
            # new-tab later selects a different profile.
            "defaultProfile": profile,
            "initialCols": compare.COLUMNS,
            "initialRows": compare.ROWS,
            "firstWindowPreference": "defaultProfile",
            "windowingBehavior": "useNew",
            "disabledProfileSources": ["Windows.Terminal.Wsl", "Windows.Terminal.Azure", "Windows.Terminal.PowershellCore"],
            "profiles": {"list": [{
                "guid": profile, "name": "compare", "font": {"face": FONT, "size": FONT_POINTS},
                "historySize": compare.SCROLLBACK_LINES, "closeOnExit": "always",
                "padding": "0", "suppressApplicationTitle": True,
            }]},
        }), encoding="utf-8")
        self.executable = directory / "WindowsTerminal.exe"
        return True

    def argv(self, command):
        return [str(self.executable), "-w", "new", "--size",
                f"{compare.COLUMNS},{compare.ROWS}", "new-tab", "-p", "compare", *command]


class Zetta:
    name = "zetta"

    def __init__(self, work, executable=None):
        self.work = work
        self.executable = executable or shutil.which("zetta.exe")
        self.cell_size = None

    def prepare(self):
        return self.executable is not None and Path(self.executable).is_file()

    def argv(self, command):
        config = self.work / "zetta.json"
        config.write_text(json.dumps({
            "terminal_font_family": FONT, "terminal_font_size": FONT_PIXELS,
            "max_scroll_history_lines": compare.SCROLLBACK_LINES,
            "windows_console_backend": "console-server",
            "profiles": [{"name": "compare", "program": command[0], "args": command[1:]}],
        }), encoding="utf-8")
        return [str(self.executable), "--config", str(config), "--no-mux",
                "--geometry", f"{compare.COLUMNS}x{compare.ROWS}",
                *(["--cell-size", "%dx%d" % self.cell_size] if self.cell_size else []),
                "--profile", "compare"]


class Alacritty:
    name = "alacritty"

    def __init__(self, work, executable=None):
        self.work = work
        self.executable = executable or self.discover()
        self.powershell = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
        self.offset = [0, 0]

    @staticmethod
    def discover():
        executable = shutil.which("alacritty.exe")
        if executable:
            return executable
        for variable, suffix in (("ProgramFiles", "Alacritty"),
                                 ("LOCALAPPDATA", "Programs/Alacritty"),
                                 ("ProgramFiles(x86)", "Alacritty")):
            root = os.environ.get(variable)
            if root:
                candidate = Path(root) / suffix / "alacritty.exe"
                if candidate.is_file():
                    return candidate
        return None

    def portable_source(self):
        cache_root = self.work.parent / "alacritty-cache"
        cache = cache_root / ALACRITTY_VERSION
        executable = cache / "alacritty.exe"
        if executable.is_file():
            return executable
        asset = f"Alacritty-v{ALACRITTY_VERSION}-portable.exe"
        url = f"https://github.com/alacritty/alacritty/releases/download/v{ALACRITTY_VERSION}/{asset}"
        print(f"alacritty: downloading portable {ALACRITTY_VERSION}", flush=True)
        cache_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="download-", dir=cache_root) as staging:
            downloaded = Path(staging) / "alacritty.exe"
            try:
                with urllib.request.urlopen(url, timeout=30) as response, downloaded.open("wb") as output:
                    shutil.copyfileobj(response, output)
                with downloaded.open("rb") as binary:
                    if binary.read(2) != b"MZ":
                        raise RuntimeError("portable download is not a Windows executable")
                cache.mkdir(exist_ok=True)
                try:
                    downloaded.rename(executable)
                except FileExistsError:
                    if not executable.is_file():
                        raise
            except OSError as error:
                raise RuntimeError(f"portable download failed: {error}; "
                                   "pass --alacritty to use a local build") from error
        return executable

    def prepare(self):
        if self.powershell is None:
            raise RuntimeError("PowerShell not installed; pwsh.exe or powershell.exe is required")
        if self.executable is None:
            self.executable = self.portable_source()
        if not Path(self.executable).is_file():
            raise RuntimeError(f"Alacritty executable does not exist: {self.executable}")
        return True

    def argv(self, command):
        config = self.work / "alacritty.toml"
        if command[0] == sys.executable:
            command = powershell_command(command, shell=self.powershell)
        config.write_text(
            "[general]\nlive_config_reload = false\n"
            "[window]\n"
            f"dimensions = {{ columns = {compare.COLUMNS}, lines = {compare.ROWS} }}\n"
            "padding = { x = 0, y = 0 }\ndynamic_title = false\n"
            "[font]\n"
            f"normal = {{ family = {json.dumps(FONT)} }}\nsize = {FONT_POINTS}\n"
            f"offset = {{ x = {self.offset[0]}, y = {self.offset[1]} }}\n"
            "[scrolling]\n"
            f"history = {compare.SCROLLBACK_LINES}\n"
            "[terminal.shell]\n"
            f"program = {json.dumps(command[0], ensure_ascii=False)}\n"
            f"args = {json.dumps(command[1:], ensure_ascii=False)}\n", encoding="utf-8")
        return [str(self.executable), "--config-file", str(config)]


def powershell_command(command, result=None, data=None, shell=None):
    # PowerShell single quotes preserve $, backticks and double quotes.
    # EncodedCommand avoids Windows command-line quoting changing the script.
    # Pass a complete Windows command line to Start-Process: Windows
    # PowerShell 5's native argument binder loses empty/quoted arguments.
    shell = shell or shutil.which("pwsh.exe") or shutil.which("powershell.exe")
    if shell is None:
        raise RuntimeError("PowerShell not installed; pwsh.exe or powershell.exe is required")
    quote = lambda value: "'" + value.replace("'", "''") + "'"
    script = "$process = Start-Process -FilePath " + quote(command[0])
    if len(command) > 1:
        script += " -ArgumentList " + quote(subprocess.list2cmdline(command[1:]))
    script += " -NoNewWindow -Wait -PassThru -ErrorAction Stop; "
    if result is not None:
        script += "if ($process.ExitCode -eq 0) { [IO.File]::WriteAllText(" + quote(str(result))
        script += ", " + quote(json.dumps(data)) + ") }; "
    script += "exit $process.ExitCode"
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return [str(shell), "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]


def find_cat(executable=None):
    if executable is not None:
        candidate = Path(executable)
        if candidate.is_file():
            return candidate.resolve()
        raise RuntimeError(f"cat executable does not exist: {candidate}")
    found = shutil.which("cat.exe")
    if found:
        return Path(found)
    for variable, suffix in (("ProgramFiles", "Git/usr/bin/cat.exe"),
                             ("LOCALAPPDATA", "Programs/Git/usr/bin/cat.exe"),
                             ("ProgramFiles(x86)", "Git/usr/bin/cat.exe")):
        root = os.environ.get(variable)
        if root and (Path(root) / suffix).is_file():
            return Path(root) / suffix
    raise RuntimeError("cat.exe not found; install coreutils or Git for Windows, or pass --cat")


def run(terminal, action, timeout, payload=None):
    result = terminal.work / f"{terminal.name}-{uuid.uuid4().hex}.json"
    timing = result.with_suffix(".time.json")
    release = result.with_suffix(".release")
    physical = action == "probe" and isinstance(terminal, (WindowsTerminal, Zetta, Alacritty))
    measured = None
    if action == "probe":
        command = [sys.executable, str(SCRIPT), "--child", action, str(result)]
        if physical:
            command.append(str(release))
    elif action == "cat":
        cat = getattr(terminal, "cat", None) or find_cat()
        command = powershell_command([sys.executable, str(SCRIPT), "--child",
                                      "cat", str(result), str(payload), str(cat), str(timing)])
    else:
        raise ValueError(f"unknown benchmark action: {action}")
    argv = terminal.argv(command)
    try:
        # A file avoids pipe EOF hangs from descendants inheriting stderr.
        with tempfile.TemporaryFile() as stderr:
            process = subprocess.Popen([
                sys.executable, str(SCRIPT), "--supervise", str(timing), json.dumps(argv), action,
            ], stdout=subprocess.DEVNULL, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
            try:
                if physical:
                    deadline = time.monotonic() + timeout
                    error = "probe did not produce a grid"
                    while process.poll() is None:
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f"physical measurement failed: {error}")
                        if result.exists():
                            try:
                                grid = json.loads(result.read_text(encoding="utf-8"))
                                pids = json.loads(timing.with_suffix(".pids.json").read_text())
                                measured = {"grid": grid, **geometry.measure_window(
                                    process.pid, min(grid[0], 16), min(grid[1], 8), pids)}
                                release.touch()
                                break
                            except (OSError, RuntimeError, ValueError) as failure:
                                error = str(failure)
                        time.sleep(0.05)
                    code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
                    if measured is None:
                        raise RuntimeError(f"physical measurement failed: {error}")
                else:
                    code = process.wait(timeout=timeout)
            finally:
                if process.poll() is None:
                    process.kill()  # Closing the helper's job kills descendants.
                process.wait(timeout=5)
            if code != 0 or not result.exists() or not timing.exists():
                end = stderr.seek(0, os.SEEK_END)
                stderr.seek(max(0, end - 2000))
                raise RuntimeError(f"exit {code}, missing or failed child: "
                                   + stderr.read().decode("utf-8", errors="replace"))
        return measured or json.loads(result.read_text(encoding="utf-8")), json.loads(timing.read_text(encoding="utf-8"))
    finally:
        result.unlink(missing_ok=True)
        timing.unlink(missing_ok=True)
        timing.with_suffix(".pids.json").unlink(missing_ok=True)
        for suffix in (".ready", ".start", ".started"):
            timing.with_suffix(suffix).unlink(missing_ok=True)
        release.unlink(missing_ok=True)


def bench(terminal, payload, runs, timeout, verbose):
    best = None
    for attempt in range(1, runs + 1):
        if verbose:
            print(f"  {terminal.name}: {payload.stem}, run {attempt}/{runs}", flush=True)
        try:
            completed, timing = run(terminal, "cat", timeout, payload)
            if completed.get("bytes") != payload.stat().st_size or timing["real"] <= 0:
                raise RuntimeError("incomplete payload or invalid timing")
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"  {terminal.name}: {error}; skipping payload", flush=True)
            return None
        if best is None or timing["real"] < best["real"]:
            best = timing
        time.sleep(0.3)
    return best


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=compare.RUN_TIMEOUT)
    parser.add_argument("--work", type=Path, default=Path(tempfile.gettempdir()) / "shitty-compare-windows")
    parser.add_argument("--terminal", action="append", choices=["windows-terminal", "zetta", "alacritty"])
    parser.add_argument("--windows-terminal", type=Path, help="path to WindowsTerminal.exe")
    parser.add_argument("--zetta", type=Path, help="path to zetta.exe")
    parser.add_argument("--alacritty", type=Path, help="path to alacritty.exe (PowerShell only)")
    parser.add_argument("--cat", type=Path, help="path to the native cat.exe used for every payload")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--probe-only", action="store_true",
                        help="report terminal geometry without generating payloads or benchmarking")
    arguments = parser.parse_args()
    if sys.platform != "win32":
        parser.error("this benchmark requires Windows")
    if arguments.runs < 1 or not 0 < arguments.timeout < float("inf"):
        parser.error("--runs and --timeout must be positive and finite")
    try:
        cat = None if arguments.probe_only else find_cat(arguments.cat)
    except RuntimeError as error:
        parser.error(str(error))
    work = arguments.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    # Keep GUI settings/results separate from cached payloads and other runs.
    with tempfile.TemporaryDirectory(prefix="session-", dir=work) as session:
        session = Path(session)
        factories = {"windows-terminal": (WindowsTerminal, arguments.windows_terminal),
                     "zetta": (Zetta, arguments.zetta),
                     "alacritty": (Alacritty, arguments.alacritty)}
        selected = list(dict.fromkeys(arguments.terminal or factories))
        ready = []
        reference = None
        # Measure the reference even when only a different target is selected.
        names = list(dict.fromkeys(["windows-terminal", *selected]))
        for name in names:
            factory, executable = factories[name]
            try:
                terminal = factory(session, executable)
                terminal.cat = cat
                if not terminal.prepare():
                    print(f"{name}: not installed, skipping")
                    continue
                if isinstance(terminal, Zetta) and reference:
                    terminal.cell_size = tuple(reference)
                measured, _ = run(terminal, "probe", compare.PROBE_TIMEOUT)
                if measured["grid"] != [compare.COLUMNS, compare.ROWS]:
                    raise RuntimeError(f"grid {measured['grid']} != {[compare.COLUMNS, compare.ROWS]}")
                if reference is None:
                    reference = measured["cell"]
                    print(f"Reference: {name}, cell {reference[0]}x{reference[1]} backing px", flush=True)
                elif isinstance(terminal, Alacritty) and measured["cell"] != reference:
                    terminal.offset = [target - actual for target, actual in zip(reference, measured["cell"])]
                    measured, _ = run(terminal, "probe", compare.PROBE_TIMEOUT)
                if measured["grid"] != [compare.COLUMNS, compare.ROWS]:
                    raise RuntimeError(f"grid {measured['grid']} != {[compare.COLUMNS, compare.ROWS]}")
                if measured["cell"] != reference:
                    raise RuntimeError(f"cell {measured['cell']} != reference {reference}")
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                print(f"{name}: probe failed: {error}; skipping")
                continue
            print(f"{name}: grid {compare.COLUMNS}x{compare.ROWS}, "
                  f"cell {reference[0]}x{reference[1]} backing px, "
                  f"content {compare.COLUMNS * reference[0]}x{compare.ROWS * reference[1]} px, "
                  f"{FONT} {FONT_POINTS}pt", flush=True)
            if name in selected:
                ready.append(terminal)
        if not ready:
            sys.exit("no terminals to compare")
        print("Verified matching backing pixel cell sizes; window chrome may differ.")
        print("Keep each benchmark window visible and in front throughout its run; visibility is not checked.",
              flush=True)
        if arguments.probe_only:
            return
        print(f"cat: {cat}", flush=True)
        for label, payload, size in compare.ensure_payloads(work):
            mib = size / (1 << 20)
            print(f"\n{label} {mib:.0f}MiB (cat, best wall of {arguments.runs}):", flush=True)
            rows = [(terminal.name, bench(terminal, payload, arguments.runs,
                                          arguments.timeout, arguments.verbose)) for terminal in ready]
            rows.sort(key=lambda row: row[1]["real"] if row[1] else float("inf"))
            print(f"  {'terminal':<16} {'wall':>7} {'user':>7} {'throughput':>12}")
            for name, timing in rows:
                if timing is None:
                    print(f"  {name:<16} {'-':>7} {'-':>7} {'-':>12}")
                else:
                    print(f"  {name:<16} {timing['real']:>6.2f}s {timing['user']:>6.2f}s"
                          f" {mib / timing['real']:>8.0f} MiB/s")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--supervise":
        sys.exit(supervise(json.loads(sys.argv[3]), sys.argv[2],
                           len(sys.argv) > 4 and sys.argv[4] == "cat"))
    elif len(sys.argv) > 1 and sys.argv[1] == "--child":
        child(*sys.argv[2:])
    else:
        main()

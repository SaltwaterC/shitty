# Copyright (C) 2026 Shitty team
# MIT licensed
# See the file LICENSE.MIT for the full license.

"""Measure a benchmark's checkerboard in physical screen pixels.

Only visible windows belonging to the benchmark process tree are inspected.
Window chrome is excluded by locating the exact two-color terminal fixture.
Occluded, clipped or inconsistent fixtures are rejected. No images are saved.
"""

import ctypes
from ctypes import wintypes

COLORS = ((17, 203, 91), (219, 43, 187))


def checkerboard(columns, rows):
    parts = ["\x1b[?1049h\x1b[?25l\x1b[?7l"]
    for row in range(rows):
        parts.append(f"\x1b[{row + 1};1H")
        for column in range(columns):
            red, green, blue = COLORS[(row + column) % 2]
            parts.append(f"\x1b[48;2;{red};{green};{blue}m ")
    return "".join(parts)


def measure_pixels(pixels, width, height, columns, rows):
    """Reject anything except a complete, uniformly spaced rendered grid."""
    colors = tuple(blue | green << 8 | red << 16 for red, green, blue in COLORS)
    values = memoryview(pixels).cast("I")
    left, top, right, bottom = width, height, -1, -1
    count = 0
    for offset, value in enumerate(values):
        if value & 0xFFFFFF in colors:
            y, x = divmod(offset, width)
            left, top = min(left, x), min(top, y)
            right, bottom = max(right, x), max(bottom, y)
            count += 1
    box_width, box_height = right - left + 1, bottom - top + 1
    if (not count or count != box_width * box_height
            or box_width % columns or box_height % rows):
        raise RuntimeError(f"terminal checkerboard is occluded, clipped or incomplete "
                           f"({count} fixture pixels in {box_width}x{box_height})")
    cell_width, cell_height = box_width // columns, box_height // rows
    for y in range(box_height):
        for x in range(box_width):
            expected = colors[(x // cell_width + y // cell_height) % 2]
            actual = values[(top + y) * width + left + x] & 0xFFFFFF
            if actual != expected:
                # Zetta rounds logical background rectangles at fractional DPI.
                # Permit a one-pixel edge shift, retaining the exact overall pitch.
                near_x = x % cell_width in (0, cell_width - 1)
                near_y = y % cell_height in (0, cell_height - 1)
                if not (near_x or near_y):
                    raise RuntimeError("terminal checkerboard has inconsistent cell spacing")
    return cell_width, cell_height


def api(dll, name, args, result):
    function = getattr(dll, name)
    function.argtypes, function.restype = args, result
    return function


def descendants(root):
    class ProcessEntry(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("usage", wintypes.DWORD),
                    ("pid", wintypes.DWORD), ("heap", ctypes.c_size_t),
                    ("module", wintypes.DWORD), ("threads", wintypes.DWORD),
                    ("parent", wintypes.DWORD), ("priority", wintypes.LONG),
                    ("flags", wintypes.DWORD), ("exe", wintypes.WCHAR * 260)]
    dll = ctypes.WinDLL("kernel32", use_last_error=True)
    snapshot = api(dll, "CreateToolhelp32Snapshot", [wintypes.DWORD, wintypes.DWORD], wintypes.HANDLE)(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    first = api(dll, "Process32FirstW", [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)], wintypes.BOOL)
    next_entry = api(dll, "Process32NextW", [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)], wintypes.BOOL)
    close = api(dll, "CloseHandle", [wintypes.HANDLE], wintypes.BOOL)
    try:
        entry = ProcessEntry()
        entry.size = ctypes.sizeof(entry)
        more = first(snapshot, ctypes.byref(entry))
        parents = {}
        while more:
            parents[entry.pid] = entry.parent
            more = next_entry(snapshot, ctypes.byref(entry))
    finally:
        close(snapshot)
    owned = {root}
    while True:
        expanded = owned | {pid for pid, parent in parents.items() if parent in owned}
        if expanded == owned:
            return owned
        owned = expanded


def capture(hwnd, user):
    class BitmapHeader(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("width", wintypes.LONG),
                    ("height", wintypes.LONG), ("planes", wintypes.WORD),
                    ("bits", wintypes.WORD), ("compression", wintypes.DWORD),
                    ("image_size", wintypes.DWORD), ("xppm", wintypes.LONG),
                    ("yppm", wintypes.LONG), ("used", wintypes.DWORD),
                    ("important", wintypes.DWORD)]
    rect = wintypes.RECT()
    api(user, "GetClientRect", [wintypes.HWND, ctypes.POINTER(wintypes.RECT)], wintypes.BOOL)(hwnd, ctypes.byref(rect))
    width, height = rect.right, rect.bottom
    if not 0 < width <= 16384 or not 0 < height <= 16384:
        raise RuntimeError("benchmark window has no usable client area")
    origin = wintypes.POINT(0, 0)
    api(user, "ClientToScreen", [wintypes.HWND, ctypes.POINTER(wintypes.POINT)], wintypes.BOOL)(hwnd, ctypes.byref(origin))
    gdi = ctypes.WinDLL("gdi32", use_last_error=True)
    get_dc = api(user, "GetDC", [wintypes.HWND], wintypes.HDC)
    release_dc = api(user, "ReleaseDC", [wintypes.HWND, wintypes.HDC], ctypes.c_int)
    make_dc = api(gdi, "CreateCompatibleDC", [wintypes.HDC], wintypes.HDC)
    make_bitmap = api(gdi, "CreateCompatibleBitmap", [wintypes.HDC, ctypes.c_int, ctypes.c_int], wintypes.HANDLE)
    select = api(gdi, "SelectObject", [wintypes.HDC, wintypes.HANDLE], wintypes.HANDLE)
    delete_object = api(gdi, "DeleteObject", [wintypes.HANDLE], wintypes.BOOL)
    delete_dc = api(gdi, "DeleteDC", [wintypes.HDC], wintypes.BOOL)
    blit = api(gdi, "BitBlt", [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                              wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD], wintypes.BOOL)
    get_bits = api(gdi, "GetDIBits", [wintypes.HDC, wintypes.HANDLE, wintypes.UINT, wintypes.UINT,
                                    ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT], ctypes.c_int)
    screen = get_dc(None)
    memory = make_dc(screen)
    bitmap = make_bitmap(screen, width, height)
    old = select(memory, bitmap)
    try:
        if not blit(memory, 0, 0, width, height, screen, origin.x, origin.y, 0x00CC0020):
            raise ctypes.WinError(ctypes.get_last_error())
        select(memory, old)
        header = BitmapHeader()
        header.size, header.width, header.height = ctypes.sizeof(header), width, -height
        header.planes, header.bits = 1, 32
        pixels = ctypes.create_string_buffer(width * height * 4)
        if get_bits(screen, bitmap, 0, height, pixels, ctypes.byref(header), 0) != height:
            raise ctypes.WinError(ctypes.get_last_error())
        return pixels.raw, width, height
    finally:
        select(memory, old)
        delete_object(bitmap)
        delete_dc(memory)
        release_dc(None, screen)


def measure_window(root, columns, rows, pids=None):
    user = ctypes.WinDLL("user32", use_last_error=True)
    awareness = api(user, "SetThreadDpiAwarenessContext", [wintypes.HANDLE], wintypes.HANDLE)
    previous = awareness(ctypes.c_void_p(-4))  # Per-monitor DPI awareness v2.
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    enum = api(user, "EnumWindows", [callback_type, wintypes.LPARAM], wintypes.BOOL)
    get_pid = api(user, "GetWindowThreadProcessId", [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)], wintypes.DWORD)
    visible = api(user, "IsWindowVisible", [wintypes.HWND], wintypes.BOOL)
    dpi = api(user, "GetDpiForWindow", [wintypes.HWND], wintypes.UINT)
    owned, windows = set(pids) if pids is not None else descendants(root), []

    @callback_type
    def visit(hwnd, unused):
        pid = wintypes.DWORD()
        get_pid(hwnd, ctypes.byref(pid))
        if pid.value in owned and visible(hwnd):
            windows.append(hwnd)
        return True

    errors = []
    try:
        enum(visit, 0)
        for hwnd in windows:
            try:
                pixels, width, height = capture(hwnd, user)
                cell = measure_pixels(pixels, width, height, columns, rows)
                return {"cell": list(cell), "dpi": dpi(hwnd)}
            except RuntimeError as error:
                errors.append(str(error))
                continue
        raise RuntimeError("no complete visible checkerboard in the benchmark window: "
                           + ("; ".join(errors) if errors else "no owned visible windows"))
    finally:
        if previous:
            awareness(previous)

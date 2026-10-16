"""grab_layers.py - dump Explorer desktop layers to PNG for visual inspection.

Debug helper for DynamicWallpaper. It walks the Progman / SHELLDLL_DefView
window chain, finds the wallpaper window by its class name, and saves one PNG
per layer into ./shots/ so you can see what is actually rendered where.

Requires: Pillow  (pip install pillow)
Usage:    python tools/grab_layers.py
"""
import os
import ctypes
from ctypes import wintypes

from PIL import Image

u = ctypes.windll.user32
g = ctypes.windll.gdi32
FindWindow = u.FindWindowW
FindWindowEx = u.FindWindowExW
GetWindowRect = u.GetWindowRect
PrintWindow = u.PrintWindow
GetDC = u.GetDC
ReleaseDC = u.ReleaseDC
CreateCompatibleDC = g.CreateCompatibleDC
CreateCompatibleBitmap = g.CreateCompatibleBitmap
SelectObject = g.SelectObject
DeleteObject = g.DeleteObject
DeleteDC = g.DeleteDC
GetDIBits = g.GetDIBits
GetClassName = u.GetClassNameW

# Output goes next to this script, never to a hard-coded absolute path.
SHOTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shots")


class RECT(ctypes.Structure):
    _fields_ = [("L", ctypes.c_long), ("T", ctypes.c_long), ("R", ctypes.c_long), ("B", ctypes.c_long)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", ctypes.c_uint32),
        ("biWidth", ctypes.c_int32),
        ("biHeight", ctypes.c_int32),
        ("biPlanes", ctypes.c_uint16),
        ("biBitCount", ctypes.c_uint16),
        ("biCompression", ctypes.c_uint32),
        ("biSizeImage", ctypes.c_uint32),
        ("biXPelsPerMeter", ctypes.c_int32),
        ("biYPelsPerMeter", ctypes.c_int32),
        ("biClrUsed", ctypes.c_uint32),
        ("biClrImportant", ctypes.c_uint32),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", ctypes.c_uint32 * 3)]


def grab(hwnd, path):
    """PrintWindow() one window into a PNG. PW_RENDERFULLCONTENT (2) is
    required for DirectComposition content; plain (0) is the fallback."""
    r = RECT()
    GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.R - r.L, r.B - r.T
    if w <= 0 or h <= 0:
        print("skip (empty rect)", path)
        return
    print(path, "hwnd", hex(hwnd), w, h)
    hdc = GetDC(hwnd)
    mem = CreateCompatibleDC(hdc)
    bmp = CreateCompatibleBitmap(hdc, w, h)
    old = SelectObject(mem, bmp)
    ok = PrintWindow(hwnd, mem, 2)
    if not ok:
        ok = PrintWindow(hwnd, mem, 0)
    print(" PrintWindow", ok)
    bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.bmiHeader.biWidth = w
    bmi.bmiHeader.biHeight = -h
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    buf = (ctypes.c_ubyte * (w * h * 4))()
    GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bmi), 0)
    img = Image.frombuffer("RGBA", (w, h), bytes(buf), "raw", "BGRA", 0, 1)
    img.save(path)
    SelectObject(mem, old)
    DeleteObject(bmp)
    DeleteDC(mem)
    ReleaseDC(hwnd, hdc)


def main():
    os.makedirs(SHOTS, exist_ok=True)

    prog = FindWindow("Progman", None)
    defv = FindWindowEx(prog, 0, "SHELLDLL_DefView", None)
    lst = FindWindowEx(defv, 0, "SysListView32", None)

    # The wallpaper window is NOT a top-level window: it is re-parented into
    # Progman/WorkerW, so FindWindow() cannot see it. Enumerate children.
    wp = 0
    h = 0
    while True:
        h = FindWindowEx(defv, h, None, None)
        if not h:
            break
        b = ctypes.create_unicode_buffer(64)
        GetClassName(h, b, 64)
        if b.value == "DynamicWallpaper":
            wp = h

    grab(prog, os.path.join(SHOTS, "shot_progman.png"))
    grab(defv, os.path.join(SHOTS, "shot_defview.png"))
    if lst:
        grab(lst, os.path.join(SHOTS, "shot_list.png"))
    if wp:
        grab(wp, os.path.join(SHOTS, "shot_wp.png"))
    else:
        print("wallpaper window not found (is DynamicWallpaper running?)")
    print("saved to", SHOTS)


if __name__ == "__main__":
    main()

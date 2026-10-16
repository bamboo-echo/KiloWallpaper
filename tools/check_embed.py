"""check_embed.py - dump the Explorer desktop window chain for DynamicWallpaper.

Read-only diagnostic; touches no window attributes. This is the first thing to
run when the wallpaper does not show up, when desktop icons get covered, or
when you want to confirm the wallpaper window is really rendering.

Prints, in z-order (top -> bottom):
  * Progman children   - the icon layer (SHELLDLL_DefView), our wallpaper
                         window, and the system wallpaper layer (WorkerW)
  * DefView children   - the icon list (SysListView32 / DirectUIHWND)
  * a render probe on the wallpaper window: PrintWindow + pixel statistics

The wallpaper window is NOT a top-level window (it is re-parented into Progman),
so FindWindow cannot find it - it has to be enumerated as a child.

Requires: nothing (Python standard library only).
Usage:    python tools/check_embed.py
"""
import ctypes
from ctypes import wintypes

u = ctypes.windll.user32
g = ctypes.windll.gdi32

FindWindow = u.FindWindowW
FindWindowEx = u.FindWindowExW
GetClassName = u.GetClassNameW
GetParent = u.GetParent
GetWindowThreadProcessId = u.GetWindowThreadProcessId
IsWindowVisible = u.IsWindowVisible
GetWindowLong = u.GetWindowLongW
GetWindowRect = u.GetWindowRect
GetDC = u.GetDC
ReleaseDC = u.ReleaseDC
PrintWindow = u.PrintWindow
GetPixel = g.GetPixel
CreateCompatibleDC = g.CreateCompatibleDC
CreateCompatibleBitmap = g.CreateCompatibleBitmap
SelectObject = g.SelectObject
DeleteObject = g.DeleteObject
DeleteDC = g.DeleteDC
GetDIBits = g.GetDIBits

WP_CLASS = "DynamicWallpaper"
GWL_EXSTYLE = -20
CLR_NONE = 0xFFFFFFFF
CLR_INVALID = 0xFFFFFFFF
PW_RENDERFULLCONTENT = 2


class RECT(ctypes.Structure):
    _fields_ = [("L", ctypes.c_long), ("T", ctypes.c_long),
                ("R", ctypes.c_long), ("B", ctypes.c_long)]


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


def cls(h):
    b = ctypes.create_unicode_buffer(256)
    GetClassName(h, b, 256)
    return b.value


def rect_of(h):
    r = RECT()
    GetWindowRect(h, ctypes.byref(r))
    return r.L, r.T, r.R, r.B


def pid_of(h):
    p = wintypes.DWORD()
    GetWindowThreadProcessId(h, ctypes.byref(p))
    return p.value


def kids(p):
    """Child windows of p, in z-order (topmost first)."""
    h = 0
    out = []
    while True:
        h = FindWindowEx(p, h, None, None)
        if not h:
            break
        out.append(h)
    return out


def show(h, tag=""):
    l, t, r, b = rect_of(h)
    ex = GetWindowLong(h, GWL_EXSTYLE) & 0xFFFFFFFF
    print("   {0}{1:<20} hwnd={2:#x} pid={3:<7} vis={4:<5} {5}x{6} ex={7:#010x}"
          .format(tag, cls(h) or "?", h, pid_of(h), bool(IsWindowVisible(h)),
                  r - l, b - t, ex))


def render_stats(h):
    """PrintWindow the window and summarise the pixels.

    PW_RENDERFULLCONTENT (2) is required for DirectComposition content; plain
    PrintWindow would return a black image.
    """
    l, t, r, b = rect_of(h)
    w, hgt = r - l, b - t
    if w <= 0 or hgt <= 0:
        print("   render: empty rect, skipped")
        return
    hdc = GetDC(h)
    mem = CreateCompatibleDC(hdc)
    bmp = CreateCompatibleBitmap(hdc, w, hgt)
    old = SelectObject(mem, bmp)
    ok = PrintWindow(h, mem, PW_RENDERFULLCONTENT)
    if not ok:
        ok = PrintWindow(h, mem, 0)
    bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.bmiHeader.biWidth = w
    bmi.bmiHeader.biHeight = -hgt
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    buf = (ctypes.c_ubyte * (w * hgt * 4))()
    GetDIBits(mem, bmp, 0, hgt, buf, ctypes.byref(bmi), 0)
    SelectObject(mem, old)
    DeleteObject(bmp)
    DeleteDC(mem)
    ReleaseDC(h, hdc)

    step = 4
    total = nonblack = 0
    rs = gs = bs = 0
    colors = set()
    for y in range(0, hgt, step):
        base = y * w * 4
        for x in range(0, w, step):
            i = base + x * 4
            bl, gr, rd = buf[i], buf[i + 1], buf[i + 2]
            total += 1
            rs += rd
            gs += gr
            bs += bl
            colors.add(((rd >> 4) << 8) | ((gr >> 4) << 4) | (bl >> 4))
            if rd or gr or bl:
                nonblack += 1
    if not total:
        return
    print("   render: PrintWindow={0} nonBlack={1:.1f}% avgRGB=({2:.0f},{3:.0f},{4:.0f}) "
          "distinctColors~{5} (sampled {6} px, step {7})"
          .format(ok, 100.0 * nonblack / total, rs / total, gs / total, bs / total,
                  len(colors), total, step))

    # A few absolute pixels, for eyeballing against a screenshot.
    dc = GetDC(h)
    pts = [(w // 5, hgt // 5), (w // 2, hgt // 2), (w * 4 // 5, hgt * 4 // 5)]
    got = []
    for x, y in pts:
        c = GetPixel(dc, x, y) & 0xFFFFFFFF
        got.append("({0},{1})={2}".format(x, y, "CLR_INVALID" if c == CLR_INVALID else hex(c)))
    ReleaseDC(h, dc)
    print("   GetPixel:" + "  ".join(got))


def render_probe(h):
    print("\n[render probe]")
    render_stats(h)


def main():
    prog = FindWindow("Progman", None)
    print("Progman", hex(prog) if prog else 0)
    if not prog:
        print("no Progman - is explorer.exe running?")
        return

    defv = FindWindowEx(prog, 0, "SHELLDLL_DefView", None)

    print("\n[Progman children] (z-order: top -> bottom)")
    wp = 0
    prog_kids = kids(prog)
    for i, ch in enumerate(prog_kids):
        show(ch, "#{0} ".format(i))
        if cls(ch) == WP_CLASS:
            wp = ch

    print("\n[DefView children]")
    listwnd = 0
    if defv:
        for ch in kids(defv):
            show(ch)
            if cls(ch) in ("SysListView32", "DirectUIHWND"):
                listwnd = ch
    else:
        print("   (no SHELLDLL_DefView under Progman)")

    # Fallback: older layouts keep the wallpaper window under DefView / WorkerW.
    if not wp and defv:
        for ch in kids(defv):
            if cls(ch) == WP_CLASS:
                wp = ch
    if not wp:
        for ch in prog_kids:
            if cls(ch) == "WorkerW":
                for sub in kids(ch):
                    if cls(sub) == WP_CLASS:
                        wp = sub

    print("\n[z-order verdict]")
    order = [cls(c) for c in prog_kids]
    print("   Progman child classes, top->bottom:", order or "[]")
    if wp:
        print("   wallpaper window {0:#x} parent={1:#x} ({2})"
              .format(wp, GetParent(wp) or 0, cls(GetParent(wp)) if GetParent(wp) else "-"))
        try:
            wi = prog_kids.index(wp)
            di = next(i for i, c in enumerate(prog_kids) if cls(c) == "SHELLDLL_DefView")
            print("   icon layer DefView index={0}, wallpaper index={1} -> icons {2}"
                  .format(di, wi, "ABOVE wallpaper (OK)" if di < wi else "BELOW wallpaper (BROKEN)"))
            wws = [i for i, c in enumerate(prog_kids) if cls(c) == "WorkerW"]
            if wws:
                print("   system WorkerW index(es)={0} -> wallpaper {1}"
                      .format(wws, "ABOVE WorkerW (OK)" if wi < min(wws) else "UNDER WorkerW (BROKEN)"))
            else:
                print("   no WorkerW under Progman -> desktop is NOT in raised state "
                      "(send 0x052C to Progman)")
        except StopIteration:
            pass
    else:
        print("   wallpaper window NOT found (is DynamicWallpaper running?)")

    if listwnd:
        bk = u.SendMessageW(listwnd, 0x1000, 0, 0) & 0xFFFFFFFF   # LVM_GETBKCOLOR
        ex = GetWindowLong(listwnd, GWL_EXSTYLE) & 0xFFFFFFFF
        print("   icon list bkColor={0} ({1}) layered={2}"
              .format(hex(bk), "CLR_NONE = punched through (OK)" if bk == CLR_NONE else "opaque",
                      bool(ex & 0x80000)))

    if wp:
        render_probe(wp)


if __name__ == "__main__":
    main()

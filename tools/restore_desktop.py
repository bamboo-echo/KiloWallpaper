import ctypes
from ctypes import wintypes

u = ctypes.windll.user32
ux = ctypes.windll.uxtheme
FindWindow = u.FindWindowW
FindWindowEx = u.FindWindowExW
GetWindowLong = u.GetWindowLongW
SetWindowLong = u.SetWindowLongW
SendMessage = u.SendMessageW
InvalidateRect = u.InvalidateRect
RedrawWindow = u.RedrawWindow
SetWindowTheme = ux.SetWindowTheme
SetWindowTheme.argtypes = [wintypes.HWND, wintypes.LPCWSTR, wintypes.LPCWSTR]
SetWindowTheme.restype = ctypes.c_long

LVM_SETBKCOLOR = 0x1001
LVM_SETTEXTBKCOLOR = 0x1026
LVM_SETTEXTCOLOR = 0x1024
LVM_GETEXTENDEDLISTVIEWSTYLE = 0x1037
LVM_SETEXTENDEDLISTVIEWSTYLE = 0x1036
CLR_NONE = 0xFFFFFFFF
GWL_EXSTYLE = -20
WS_EX_LAYERED = 0x80000
LVS_EX_TRANSPARENTBKGND = 0x00400000

prog = FindWindow("Progman", None)
defv = FindWindowEx(prog, 0, "SHELLDLL_DefView", None)
lst = FindWindowEx(defv, 0, "SysListView32", None)
print("list", hex(lst) if lst else 0)
if not lst:
    raise SystemExit(1)

ex = GetWindowLong(lst, GWL_EXSTYLE)
print("ex before", hex(ex & 0xFFFFFFFF))
SetWindowLong(lst, GWL_EXSTYLE, ex & ~WS_EX_LAYERED)
SetWindowTheme(lst, None, None)
SendMessage(lst, LVM_SETBKCOLOR, 0, CLR_NONE)
SendMessage(lst, LVM_SETTEXTBKCOLOR, 0, CLR_NONE)
lvex = SendMessage(lst, LVM_GETEXTENDEDLISTVIEWSTYLE, 0, 0)
SendMessage(lst, LVM_SETEXTENDEDLISTVIEWSTYLE, LVS_EX_TRANSPARENTBKGND, 0)
InvalidateRect(lst, None, True)
RedrawWindow(lst, None, None, 0x0100 | 0x0001 | 0x0080)
print("ex after", hex(GetWindowLong(lst, GWL_EXSTYLE) & 0xFFFFFFFF))
print("restored")

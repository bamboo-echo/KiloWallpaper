// desktop.zig - 桌面嵌入层（对应 cpp/desktop.cpp）
//
// Win11 24H2+/25H2 "raised desktop" 结构与全部踩坑均逐条落实：
//  - 主路径：挂 Progman + WS_EX_LAYERED(bAlpha=0xFF) + 双向 z 锚定
//    （图标层之后、系统壁纸 WorkerW 之前）。
//  - 嵌入前发 0x052C 唤醒 raised；看门狗发现 WorkerW 消失每 5 秒重发自愈。
//  - 绝不用 HWND_BOTTOM 在 Progman 子窗口方案下（会被系统壁纸盖住→消失）。
//  - 图标层零修改（LVM 本就是 CLR_NONE，打穿是死代码）。
//  - 多级兜底：Progman 双向锚定 → 经典结构挂图标层后空 WorkerW → 顶层压底。
const std = @import("std");
const win = @import("win.zig");
const common = @import("common.zig");

const HWND = win.HWND;
const RECT = win.RECT;

// 24H2+ raised desktop 方案的 z 序锚点（进程级，看门狗复用）
var g_wpDefView: ?HWND = null;
var g_wpWorkerW: ?HWND = null;

pub fn getPrimaryMonitorRect() RECT {
    var work: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const pm = win.c.MonitorFromPoint(.{ .x = 0, .y = 0 }, win.c.MONITOR_DEFAULTTOPRIMARY);
    var mi: win.c.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(win.c.MONITORINFO);
    if (pm != null and win.c.GetMonitorInfoW(pm, &mi) != 0) return mi.rcMonitor;
    work.left = win.c.GetSystemMetrics(win.c.SM_XVIRTUALSCREEN);
    work.top = win.c.GetSystemMetrics(win.c.SM_YVIRTUALSCREEN);
    work.right = work.left + win.c.GetSystemMetrics(win.c.SM_CXVIRTUALSCREEN);
    work.bottom = work.top + win.c.GetSystemMetrics(win.c.SM_CYVIRTUALSCREEN);
    return work;
}

pub fn fitToParentOrMonitor(hwnd: HWND) void {
    if (hwnd == null) return;
    var x: i32 = 0;
    var y: i32 = 0;
    var w: i32 = 0;
    var h: i32 = 0;
    const p = win.c.GetParent(hwnd);
    if (p != null) {
        var pr: RECT = undefined;
        _ = win.c.GetClientRect(p, &pr);
        w = pr.right - pr.left;
        h = pr.bottom - pr.top;
    } else {
        const r = getPrimaryMonitorRect();
        x = r.left;
        y = r.top;
        w = r.right - r.left;
        h = r.bottom - r.top;
    }
    if (w <= 0 or h <= 0) return;
    var cr: RECT = undefined;
    _ = win.c.GetClientRect(hwnd, &cr);
    const cw = cr.right - cr.left;
    const ch = cr.bottom - cr.top;
    if (cw == w and ch == h and common.g_winW == w and common.g_winH == h) return;
    _ = win.c.SetWindowPos(hwnd, null, x, y, w, h, win.c.SWP_NOZORDER | win.c.SWP_NOACTIVATE);
    common.g_winW = w;
    common.g_winH = h;
}

// ---------- 窗口枚举回调 ----------
fn enumFindProgman(h: HWND, l: win.LPARAM) callconv(.C) win.BOOL {
    var cls: [64]win.WCHAR = undefined;
    if (win.c.GetClassNameW(h, &cls, 64) > 0 and win.c.wcscmp(&cls, asciiW("Progman")) == 0) {
        const out = @as(*?HWND, @ptrFromInt(@as(usize, @intCast(l))));
        out.* = h;
        return 0; // FALSE：停止枚举（找到了）
    }
    return 1; // TRUE：继续
}

fn enumFindIconWorkerW(hwnd: HWND, l: win.LPARAM) callconv(.C) win.BOOL {
    var cls: [64]win.WCHAR = undefined;
    if (win.c.GetClassNameW(hwnd, &cls, 64) <= 0) return 1;
    if (win.c.wcscmp(&cls, asciiW("WorkerW")) != 0) return 1;
    if (win.c.FindWindowExW(hwnd, null, asciiW("SHELLDLL_DefView"), null) != null) {
        const out = @as(*?HWND, @ptrFromInt(@as(usize, @intCast(l))));
        out.* = hwnd;
        return 0;
    }
    return 1;
}

pub fn findProgman() ?HWND {
    const viaFind = win.c.FindWindowW(asciiW("Progman"), null);
    if (viaFind != null) return viaFind;
    var res: ?HWND = null;
    _ = win.c.EnumWindows(enumFindProgman, @intCast(@intFromPtr(&res)));
    return res;
}

// 找"包含 SHELLDLL_DefView 的 WorkerW"（图标层所在）
fn findWorkerAfterIconWorker() ?HWND {
    var iconWorker: ?HWND = null;
    _ = win.c.EnumWindows(enumFindIconWorkerW, @intCast(@intFromPtr(&iconWorker)));
    if (iconWorker == null) return null;
    return win.c.FindWindowExW(null, iconWorker.?, asciiW("WorkerW"), null);
}

// 方案A 用：Progman 的全屏 WorkerW 子窗口（24H2+/25H2 系统壁纸层）。
// 只认覆盖主屏 >=90% 的，排除 135x37 占位 WorkerW。
fn findWallpaperWorkerW(progman: HWND) ?HWND {
    if (progman == null) return null;
    const m = getPrimaryMonitorRect();
    var w = win.c.FindWindowExW(progman.?, null, asciiW("WorkerW"), null);
    while (w != null) : (w = win.c.FindWindowExW(progman.?, w, asciiW("WorkerW"), null)) {
        var r: RECT = undefined;
        if (win.c.GetWindowRect(w, &r) != 0 and
            (r.right - r.left) >= @divTrunc((m.right - m.left) * 9, 10) and
            (r.bottom - r.top) >= @divTrunc((m.bottom - m.top) * 9, 10))
        {
            return w;
        }
    }
    return null;
}

// 把壁纸窗口插到图标列表(SysListView32)正后方。
pub fn ensureWallpaperZOrder(hwnd: HWND) void {
    if (hwnd == null) return;
    const parent = win.c.GetParent(hwnd);
    if (parent == null) {
        // 顶层模式：直接压到 z 序最底（DWM 壁纸之上、图标层之下）
        _ = win.c.SetWindowPos(hwnd, @as(win.HWND, @ptrFromInt(0)), 0, 0, 0, 0,
            win.c.SWP_NOMOVE | win.c.SWP_NOSIZE | win.c.SWP_NOACTIVATE);
        common.logImpl("embed", "zorder: toplevel bottom", .{});
        return;
    }
    var pcls: [64]win.WCHAR = undefined;
    _ = win.c.GetClassNameW(parent, &pcls, 64);
    if (win.c.wcscmp(&pcls, asciiW("Progman")) == 0) {
        // 双向 z 锚定：
        //  1) 壁纸窗口插到 DefView(图标层) 之后 = 图标之下
        //  2) 系统 WorkerW(壁纸层) 压到壁纸窗口之后 = 壁纸之下
        //  缺第 2 步会被黑壁纸 WorkerW 盖住（实测复现）。
        var defView: ?HWND = null;
        if (g_wpDefView != null and win.c.IsWindow(g_wpDefView.?) != 0 and
            win.c.GetParent(g_wpDefView.?) == parent)
        {
            defView = g_wpDefView;
        } else {
            defView = win.c.FindWindowExW(parent, null, asciiW("SHELLDLL_DefView"), null);
        }
        var ok: bool = true;
        if (defView != null) {
            ok = win.c.SetWindowPos(hwnd, defView.?, 0, 0, 0, 0,
                win.c.SWP_NOMOVE | win.c.SWP_NOSIZE | win.c.SWP_NOACTIVATE) != 0;
        } else ok = false;

        var workerW: ?HWND = null;
        if (g_wpWorkerW != null and win.c.IsWindow(g_wpWorkerW.?) != 0 and
            win.c.GetParent(g_wpWorkerW.?) == parent)
        {
            workerW = g_wpWorkerW;
        } else {
            workerW = win.c.FindWindowExW(parent, null, asciiW("WorkerW"), null);
        }
        const parentProgman = win.c.GetParent(hwnd);
        if (workerW != null and workerW.? != hwnd) {
            if (win.c.SetWindowPos(workerW.?, hwnd, 0, 0, 0, 0,
                win.c.SWP_NOMOVE | win.c.SWP_NOSIZE | win.c.SWP_NOACTIVATE) == 0) ok = false;
        } else if (workerW == null and parentProgman != null) {
            // ★ 结构退化自愈：Progman 下的系统 WorkerW（壁纸层）消失了
            // （explorer 刷新/未 raised 状态）。重发 0x052C 让系统重建 WorkerW，
            // 下一轮看门狗即可恢复双向锚定。不刷日志防刷屏。
            const now = win.c.GetTickCount();
            if (now - s_lastRaise > 5000) {
                _ = win.c.SendMessageTimeoutW(parentProgman, 0x052C, 0, 0, win.c.SMTO_NORMAL, 1000, null);
                s_lastRaise = now;
            }
            ok = false;
        }
        if (!ok) common.logImpl("embed", "zorder: anchor FAILED (will retry)", .{});
    } else if (win.c.wcscmp(&pcls, asciiW("SHELLDLL_DefView")) == 0) {
        var anchor = win.c.FindWindowExW(parent, null, asciiW("SysListView32"), null);
        if (anchor == null) anchor = win.c.FindWindowExW(parent, null, asciiW("DirectUIHWND"), null);
        if (anchor != null) {
            _ = win.c.SetWindowPos(hwnd, anchor, 0, 0, 0, 0,
                win.c.SWP_NOMOVE | win.c.SWP_NOSIZE | win.c.SWP_NOACTIVATE);
            common.logImpl("embed", "zorder: after icon-list", .{});
        } else {
            _ = win.c.SetWindowPos(hwnd, @as(win.HWND, @ptrFromInt(0)), 0, 0, 0, 0,
                win.c.SWP_NOMOVE | win.c.SWP_NOSIZE | win.c.SWP_NOACTIVATE);
            common.logImpl("embed", "zorder: defview bottom", .{});
        }
    } else {
        _ = win.c.SetWindowPos(hwnd, @as(win.HWND, @ptrFromInt(0)), 0, 0, 0, 0,
            win.c.SWP_NOMOVE | win.c.SWP_NOSIZE | win.c.SWP_NOACTIVATE);
        common.logImpl("embed", "zorder: workerw bottom", .{});
    }
}
var s_lastRaise: win.DWORD = 0;

fn attachTo(hwnd: HWND, parent: HWND) bool {
    if (hwnd == null or parent == null) return false;
    var style = win.c.GetWindowLongPtrW(hwnd, win.c.GWL_STYLE);
    style = style & ~@as(win.c.LONG_PTR, win.c.WS_POPUP | win.c.WS_CAPTION | win.c.WS_THICKFRAME | win.c.WS_SYSMENU);
    style |= win.c.WS_CHILD | win.c.WS_VISIBLE;
    _ = win.c.SetWindowLongPtrW(hwnd, win.c.GWL_STYLE, style);
    // 不要 WS_EX_TRANSPARENT：会让窗口在兄弟窗口之后绘制，盖住图标。
    var ex = win.c.GetWindowLongPtrW(hwnd, win.c.GWL_EXSTYLE);
    ex = ex & ~@as(win.c.LONG_PTR, win.c.WS_EX_TRANSPARENT);
    ex = ex | win.c.WS_EX_NOACTIVATE;
    _ = win.c.SetWindowLongPtrW(hwnd, win.c.GWL_EXSTYLE, ex);
    if (win.c.SetParent(hwnd, parent) == null) return false;
    var pr: RECT = undefined;
    _ = win.c.GetClientRect(parent, &pr);
    var w = pr.right - pr.left;
    var h = pr.bottom - pr.top;
    if (w <= 0 or h <= 0) {
        const mr = getPrimaryMonitorRect();
        w = mr.right - mr.left;
        h = mr.bottom - mr.top;
    }
    common.g_parent = parent;
    common.g_winW = w;
    common.g_winH = h;
    ensureWallpaperZOrder(hwnd);
    return win.c.IsWindowVisible(hwnd) != 0;
}

fn applyFallbackTopLevel(hwnd: HWND) void {
    var style = win.c.GetWindowLongPtrW(hwnd, win.c.GWL_STYLE);
    style = style & ~@as(win.c.LONG_PTR, win.c.WS_CHILD);
    style |= win.c.WS_POPUP | win.c.WS_VISIBLE;
    _ = win.c.SetWindowLongPtrW(hwnd, win.c.GWL_STYLE, style);
    var ex = win.c.GetWindowLongPtrW(hwnd, win.c.GWL_EXSTYLE);
    ex = ex | win.c.WS_EX_NOACTIVATE | win.c.WS_EX_TOOLWINDOW;
    _ = win.c.SetWindowLongPtrW(hwnd, win.c.GWL_EXSTYLE, ex);
    _ = win.c.SetParent(hwnd, null);
    const r = getPrimaryMonitorRect();
    const w = r.right - r.left;
    const h = r.bottom - r.top;
    _ = win.c.SetWindowPos(hwnd, @as(win.HWND, @ptrFromInt(0)), r.left, r.top, w, h,
        win.c.SWP_NOACTIVATE | win.c.SWP_SHOWWINDOW | win.c.SWP_FRAMECHANGED);
    common.g_parent = null;
    common.g_winW = w;
    common.g_winH = h;
}

pub fn embedOrFallback(hwnd: HWND) bool {
    const progman = findProgman();
    // ★ 固定唤醒 "raised desktop"：0x052C 让系统把壁纸画进 Progman 下的全屏
    // WorkerW。开机/explorer 刷新后桌面可能退化回未 raised 状态（Progman 下只有
    // DefView，无 WorkerW），此时系统壁纸由 DWM 直绘在最底层，会盖住我们的窗口
    // → 壁纸"消失"。每次嵌入前都发 0x052C 强制恢复三层结构。
    if (progman != null) {
        _ = win.c.SendMessageTimeoutW(progman.?, 0x052C, 0, 0, win.c.SMTO_NORMAL, 1000, null);
    }
    _ = win.c.Sleep(120);

    // ---- 主方案（Win11 24H2+/25H2）：Progman 的 LAYERED 子窗口 + 双向 z 锚定 ----
    var defView = if (progman != null)
        win.c.FindWindowExW(progman.?, null, asciiW("SHELLDLL_DefView"), null)
    else
        null;
    if (defView == null) {
        _ = win.c.Sleep(150);
        defView = if (progman != null)
            win.c.FindWindowExW(progman.?, null, asciiW("SHELLDLL_DefView"), null)
        else
            null;
    }
    if (progman != null and defView != null) {
        var style = win.c.GetWindowLongPtrW(hwnd, win.c.GWL_STYLE);
        style = style & ~@as(win.c.LONG_PTR, win.c.WS_POPUP | win.c.WS_CAPTION | win.c.WS_THICKFRAME | win.c.WS_SYSMENU);
        style |= win.c.WS_CHILD | win.c.WS_VISIBLE;
        _ = win.c.SetWindowLongPtrW(hwnd, win.c.GWL_STYLE, style);
        var ex = win.c.GetWindowLongPtrW(hwnd, win.c.GWL_EXSTYLE);
        ex |= win.c.WS_EX_LAYERED | win.c.WS_EX_NOACTIVATE;
        ex &= ~@as(win.c.LONG_PTR, win.c.WS_EX_TOPMOST);
        _ = win.c.SetWindowLongPtrW(hwnd, win.c.GWL_EXSTYLE, ex);
        _ = win.c.SetLayeredWindowAttributes(hwnd, 0, 255, win.c.LWA_ALPHA);
        if (win.c.SetParent(hwnd, progman.?) != null) {
            common.g_parent = progman;
            g_wpDefView = defView;
            g_wpWorkerW = findWallpaperWorkerW(progman.?);
            var pr: RECT = undefined;
            _ = win.c.GetClientRect(progman.?, &pr);
            var w = pr.right - pr.left;
            var h = pr.bottom - pr.top;
            if (w <= 0 or h <= 0) {
                const mr = getPrimaryMonitorRect();
                w = mr.right - mr.left;
                h = mr.bottom - mr.top;
            }
            common.g_winW = w;
            common.g_winH = h;
            _ = win.c.SetWindowPos(hwnd, null, 0, 0, w, h,
                win.c.SWP_NOZORDER | win.c.SWP_NOACTIVATE | win.c.SWP_SHOWWINDOW);
            ensureWallpaperZOrder(hwnd);
            _ = win.c.RedrawWindow(hwnd, null, null, win.c.RDW_INVALIDATE | win.c.RDW_UPDATENOW);
            common.logImpl("embed", "embed: progman-layered anchor", .{});
            return true;
        }
        common.logImpl("embed", "embed: setparent failed", .{});
    }

    // ---- 备选（pre-24H2 / Win10）：挂进图标层后面的空 WorkerW ----
    var workerW = findWorkerAfterIconWorker();
    if (workerW == null and progman != null) {
        _ = win.c.SendMessageTimeoutW(progman.?, 0x052C, 0, 0, win.c.SMTO_NORMAL, 1000, null);
        _ = win.c.Sleep(150);
        workerW = findWorkerAfterIconWorker();
    }
    if (workerW != null and win.c.IsWindow(workerW.?) != 0) {
        if (attachTo(hwnd, workerW.?)) {
            g_wpDefView = null;
            g_wpWorkerW = null;
            common.logImpl("embed", "embed: classic workerw-child", .{});
            return true;
        }
    }

    // ---- 兜底：顶层窗口压底（已知会盖图标，仅保底不黑屏） ----
    common.logImpl("embed", "embed: toplevel fallback", .{});
    applyFallbackTopLevel(hwnd);
    return true;
}

// 给看门狗用的便捷包装
fn asciiW(comptime s: []const u8) [*:0]const win.WCHAR {
    const arr = comptime blk: {
        var a: [s.len:0]win.WCHAR = undefined;
        for (s, 0..) |c, i| a[i] = c;
        break :blk a;
    };
    return @ptrCast(&arr);
}

// main.zig - KiloWallpaper (Zig) 入口 / 窗口 / 看门狗 / 渲染调度 / 配置
//
// 对齐 cpp/main.cpp。Zig 没有 wWinMain 的隐式入口，这里用 pub fn main +
// build.zig 的 .Windows subsystem；命令行从 std.process.argsAlloc 取（UTF-8 → UTF-16）。
//
// 编译期依赖 Windows SDK 头文件（@cImport 翻译 COM vtable/GUID），运行时零依赖。
const std = @import("std");
const win = @import("win.zig");
const common = @import("common.zig");
const desktop = @import("desktop.zig");
const media = @import("media.zig");
const render = @import("render.zig");
const d3d = @import("d3dplayer.zig");

var g_hInst: win.HINSTANCE = undefined;

// ---------- 小工具 ----------
fn asciiW(comptime s: []const u8) [*:0]const win.WCHAR {
    const lit: [s.len:0]win.WCHAR = comptime blk: {
        var a: [s.len:0]win.WCHAR = undefined;
        for (s, 0..) |c, i| a[i] = c;
        break :blk a;
    };
    return @ptrCast(&lit);
}

fn loword(v: usize) u16 {
    return @truncate(v & 0xFFFF);
}
fn hiword(v: usize) u16 {
    return @truncate((v >> 16) & 0xFFFF);
}
fn isNullHwnd(h: win.HWND) bool {
    return @intFromPtr(h) == 0;
}

/// 取 exe 目录（含尾随 '\'）写入 buf，返回长度。
fn exeDir(buf: []win.WCHAR) usize {
    const n = win.c.GetModuleFileNameW(null, buf.ptr, @intCast(buf.len));
    var last: usize = 0;
    var i: usize = 0;
    while (i < n and i < buf.len) : (i += 1) {
        if (buf[i] == '\\' or buf[i] == '/') last = i + 1;
    }
    return last;
}

/// 把 ASCII 名字追加到 dir 后（dir 已含尾随 '\'），返回总长度（不含 0）。
fn joinName(buf: []win.WCHAR, dir_len: usize, name: []const u8) usize {
    var i = dir_len;
    var j: usize = 0;
    while (j < name.len and i + 1 < buf.len) : ({
        i += 1;
        j += 1;
    }) {
        buf[i] = name[j];
    }
    buf[i] = 0;
    return i;
}

// ---------- 优雅关闭 / 守护互保（对齐 cpp/main.cpp） ----------
fn consumeQuitSignal() bool {
    if (common.fileExists("wallpaper.quit")) {
        common.deleteFileIf("wallpaper.quit");
        return true;
    }
    return false;
}

fn launchGuard() void {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = exeDir(&buf);
    const full_len = joinName(&buf, dir_len, "DynamicWallpaperGuard.exe");
    if (win.c.GetFileAttributesW(&buf) == win.c.INVALID_FILE_ATTRIBUTES) return;
    if (full_len >= win.c.MAX_PATH) return;

    var si: win.c.STARTUPINFOW = std.mem.zeroes(win.c.STARTUPINFOW);
    si.cb = @sizeOf(win.c.STARTUPINFOW);
    var pi: win.c.PROCESS_INFORMATION = std.mem.zeroes(win.c.PROCESS_INFORMATION);
    const ok = win.c.CreateProcessW(
        &buf,
        &buf,
        null,
        null,
        win.FALSE,
        win.c.DETACHED_PROCESS,
        null,
        null,
        &si,
        &pi,
    );
    if (ok != 0) {
        _ = win.c.CloseHandle(pi.hProcess);
        _ = win.c.CloseHandle(pi.hThread);
    }
}

fn ensureGuardAlive() void {
    if (common.isOurProcess(common.readPidFile("wallpaper.guard.pid"), "DynamicWallpaperGuard.exe")) return;
    launchGuard();
}

fn advanceFrame() void {
    if (common.g_hwnd == null) return;
    if (common.g_isVideo) {
        var next = d3d.d3dPumpFrame();
        if (next < 10) next = 10;
        _ = win.c.SetTimer(common.g_host.?, common.TIMER_FRAME, next, null);
    } else if (media.g_frameCount > 0) {
        if (media.g_frameCount == 1) {
            _ = win.c.InvalidateRect(common.g_hwnd.?, null, win.FALSE);
            return;
        }
        media.g_curFrame = (media.g_curFrame + 1) % media.g_frameCount;
        var delay = media.g_delays[media.g_curFrame];
        if (delay < 10) delay = 10;
        _ = win.c.SetTimer(common.g_host.?, common.TIMER_FRAME, delay, null);
        _ = win.c.InvalidateRect(common.g_hwnd.?, null, win.FALSE);
    }
}

fn createWallpaperWindow() bool {
    const work = desktop.getPrimaryMonitorRect();
    const w = work.right - work.left;
    const h = work.bottom - work.top;
    const hwnd = win.c.CreateWindowExW(
        win.c.WS_EX_NOACTIVATE | win.c.WS_EX_TOOLWINDOW,
        asciiW("DynamicWallpaper"),
        asciiW("DynamicWallpaper"),
        win.c.WS_POPUP,
        work.left,
        work.top,
        w,
        h,
        null,
        null,
        g_hInst,
        null,
    );
    if (isNullHwnd(hwnd)) return false;
    common.g_hwnd = hwnd;
    common.g_winW = w;
    common.g_winH = h;
    return true;
}

fn watchdogTick() void {
    if (consumeQuitSignal()) {
        common.writeFileMarker("wallpaper.graceful");
        win.c.PostQuitMessage(0);
        return;
    }
    if (common.g_hwnd == null or win.c.IsWindow(common.g_hwnd.?) == 0) {
        if (!createWallpaperWindow()) return;
        _ = desktop.embedOrFallback(common.g_hwnd.?);
        d3d.d3dSetWindow(common.g_hwnd.?);
        return;
    }
    const hwnd = common.g_hwnd.?;
    const p = win.c.GetParent(hwnd);
    if (isNullHwnd(p) or win.c.IsWindow(p) == 0 or
        (common.g_parent != null and win.c.IsWindow(common.g_parent.?) == 0))
    {
        _ = desktop.embedOrFallback(hwnd);
        d3d.d3dSetWindow(hwnd);
    } else {
        desktop.fitToParentOrMonitor(hwnd);
        desktop.ensureWallpaperZOrder(hwnd);
    }
    ensureGuardAlive();
}

// ---------- 窗口过程 ----------
fn wndProc(hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) callconv(.C) win.LRESULT {
    switch (msg) {
        win.c.WM_CREATE => {
            var rc: win.RECT = undefined;
            _ = win.c.GetClientRect(hwnd, &rc);
            common.g_winW = rc.right - rc.left;
            common.g_winH = rc.bottom - rc.top;
            return 0;
        },
        win.c.WM_SIZE => {
            common.g_winW = @intCast(loword(@intCast(lp)));
            common.g_winH = @intCast(hiword(@intCast(lp)));
            _ = win.c.InvalidateRect(hwnd, null, win.FALSE);
            return 0;
        },
        win.c.WM_DISPLAYCHANGE, win.c.WM_DPICHANGED => {
            desktop.fitToParentOrMonitor(hwnd);
            _ = win.c.InvalidateRect(hwnd, null, win.FALSE);
            return 0;
        },
        win.c.WM_PAINT => {
            // 父窗口尺寸变化时先对齐
            const p = win.c.GetParent(hwnd);
            if (!isNullHwnd(p) and win.c.IsWindow(p) != 0) {
                var pr: win.RECT = undefined;
                _ = win.c.GetClientRect(p, &pr);
                const pw = pr.right - pr.left;
                const ph = pr.bottom - pr.top;
                if (pw > 0 and ph > 0) {
                    if (common.g_winW != pw or common.g_winH != ph) {
                        _ = win.c.SetWindowPos(hwnd, null, 0, 0, pw, ph, win.c.SWP_NOZORDER | win.c.SWP_NOACTIVATE);
                        common.g_winW = pw;
                        common.g_winH = ph;
                    }
                }
            }
            var ps: win.c.PAINTSTRUCT = undefined;
            const dc = win.c.BeginPaint(hwnd, &ps);
            defer _ = win.c.EndPaint(hwnd, &ps);
            var rc: win.RECT = undefined;
            _ = win.c.GetClientRect(hwnd, &rc);
            const w = rc.right - rc.left;
            const h = rc.bottom - rc.top;
            if (w <= 0 or h <= 0) return 0;
            if (common.g_isVideo) return 0; // D3D 交换链常驻呈现
            render.ensureBackbuffer(dc, w, h);
            const mem = render.getMemDC() orelse return 0;
            const br = win.c.CreateSolidBrush(0); // 黑底（COLORREF 0）
            _ = win.c.FillRect(mem, &rc, br);
            _ = win.c.DeleteObject(br);
            render.drawGifFrame(mem, w, h);
            _ = win.c.BitBlt(dc, 0, 0, w, h, mem, 0, 0, win.c.SRCCOPY);
            return 0;
        },
        win.c.WM_ERASEBKGND => return 1,
        win.c.WM_DESTROY => {
            if (common.g_hwnd) |h| {
                if (h == hwnd) common.g_hwnd = null;
            }
            return 0;
        },
        else => {},
    }
    return win.c.DefWindowProcW(hwnd, msg, wp, lp);
}

fn hostProc(hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) callconv(.C) win.LRESULT {
    if (common.g_taskbarCreated != 0 and msg == common.g_taskbarCreated) {
        watchdogTick();
        return 0;
    }
    switch (msg) {
        win.c.WM_TIMER => {
            if (wp == common.TIMER_WATCHDOG) {
                watchdogTick();
            } else if (wp == common.TIMER_FRAME) {
                advanceFrame();
            }
            return 0;
        },
        win.c.WM_DISPLAYCHANGE => {
            if (common.g_hwnd) |h| {
                desktop.fitToParentOrMonitor(h);
                _ = win.c.InvalidateRect(h, null, win.FALSE);
            }
            return 0;
        },
        win.c.WM_DESTROY => {
            win.c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win.c.DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------- 配置解析（命令行优先，其次 wallpaper.txt 首行） ----------
fn trimPathW(w: []win.WCHAR) []win.WCHAR {
    var s: usize = 0;
    var e: usize = w.len;
    while (s < e and (w[s] == ' ' or w[s] == '"' or w[s] == '\t')) s += 1;
    while (e > s and (w[e - 1] == ' ' or w[e - 1] == '"' or w[e - 1] == '\t' or w[e - 1] == '\r' or w[e - 1] == '\n')) e -= 1;
    // 截断到首个换行
    var i = s;
    while (i < e) : (i += 1) {
        if (w[i] == '\r' or w[i] == '\n') {
            e = i;
            break;
        }
    }
    return w[s..e];
}

fn resolveMediaPath(alloc: std.mem.Allocator, cmd_utf8: []const u8) ?[:0]win.WCHAR {
    var path_w: ?[:0]win.WCHAR = null;

    if (cmd_utf8.len > 0) {
        const wcmd = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8) catch return null;
        path_w = wcmd;
    }

    if (path_w == null) {
        var dir_buf: [win.c.MAX_PATH]win.WCHAR = undefined;
        const dir_len = exeDir(&dir_buf);
        var cfg_buf: [win.c.MAX_PATH]win.WCHAR = undefined;
        _ = joinName(&cfg_buf, dir_len, "wallpaper.txt");
        const fh = win.c._wfopen(&cfg_buf, asciiW("rb"));
        if (fh == null) return null;
        defer _ = win.c.fclose(fh.?);
        var raw: [1024]u8 = undefined;
        const rd = win.c.fread(&raw, 1, raw.len - 1, fh.?);
        if (rd == 0) return null;
        var bytes = raw[0..rd];
        // 容忍 UTF-8 BOM
        if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF)
            bytes = bytes[3..];
        // 只取首行
        var line = bytes;
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |nl| line = bytes[0..nl];
        // 严格 UTF-8（非法字节直接判配置无效）
        const wline = std.unicode.utf8ToUtf16LeAllocZ(alloc, line) catch return null;
        defer alloc.free(wline);
        const trimmed = trimPathW(wline);
        if (trimmed.len == 0) return null;
        // 重新分配一个 0 结尾的切片
        const out = alloc.allocSentinel(win.WCHAR, trimmed.len, 0) catch return null;
        @memcpy(out, trimmed);
        path_w = out;
    }

    // 相对路径按 exe 目录解析
    const s = path_w.?;
    if (win.c.PathIsRelativeW(s.ptr) != 0) {
        var dir_buf: [win.c.MAX_PATH]win.WCHAR = undefined;
        const dir_len = exeDir(&dir_buf);
        const joined = alloc.allocSentinel(win.WCHAR, dir_len + s.len, 0) catch return null;
        @memcpy(joined[0..dir_len], dir_buf[0..dir_len]);
        @memcpy(joined[dir_len..], s);
        path_w = joined;
    }

    const full = alloc.allocSentinel(win.WCHAR, win.c.MAX_PATH, 0) catch return null;
    const n = win.c.GetFullPathNameW(path_w.?.ptr, win.c.MAX_PATH, full.ptr, null);
    if (n > 0 and n < win.c.MAX_PATH) {
        full[n] = 0;
        const res = alloc.allocSentinel(win.WCHAR, n, 0) catch return null;
        @memcpy(res, full[0..n]);
        return res;
    }
    if (n == 0) return null;
    // 超长路径：按截断路径试一次
    if (win.c.GetFileAttributesW(path_w.?.ptr) == win.c.INVALID_FILE_ATTRIBUTES) return null;
    return path_w;
}

// ---------- 入口 ----------
pub fn main() void {
    common.logImpl("main", "enter", .{});
    std.debug.print("zig main enter\n", .{});
    const alloc = std.heap.page_allocator;
    const argv = std.process.argsAlloc(alloc) catch null;
    std.debug.print("zig args ok\n", .{});
    defer if (argv) |a| std.process.argsFree(alloc, a);
    const cmd: []const u8 = if (argv != null and argv.?.len > 1) argv.?[1] else "";

    // 单实例互斥
    const mutex = win.c.CreateMutexW(null, win.TRUE, asciiW("DynamicWallpaper_SingleInstance"));
    const mErr = win.c.GetLastError();
    common.logImpl("main", "mutex={} err={d} cmd_len={d}", .{ mutex != null, mErr, cmd.len });
    if (mutex == null or mErr == win.c.ERROR_ALREADY_EXISTS) return;

    _ = consumeQuitSignal();
    common.writePidFile("wallpaper.main.pid");

    // 重启管理器（强杀后系统恢复）
    {
        const k32 = win.c.GetModuleHandleW(asciiW("kernel32.dll"));
        if (k32 != null) {
            if (win.c.GetProcAddress(k32, "RegisterApplicationRestart")) |fp| {
                const Fn = *const fn ([*:0]const u16, u32) callconv(.C) win.HRESULT;
                const f: Fn = @ptrCast(fp);
                _ = f(asciiW(""), 0);
            }
        }
    }

    // DPI 必须在建窗前设为 Per-Monitor V2（否则跨 DPI 嵌入纯黑，实测复现）
    if (win.c.GetProcAddress(win.c.GetModuleHandleW(asciiW("user32.dll")), "SetProcessDpiAwarenessContext")) |fp| {
        const Fn = *const fn (win.c.DPI_AWARENESS_CONTEXT) callconv(.C) win.BOOL;
        const f: Fn = @ptrCast(fp);
        _ = f(win.c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    _ = win.c.CoInitializeEx(null, win.c.COINIT_MULTITHREADED);
    _ = win.c.MFStartup(win.c.MF_VERSION, 0);

    var token: win.ULONG_PTR = 0;
    var gsi = win.GdiplusStartupInput{ .GdiplusVersion = 1, .DebugEventCallback = null, .SuppressBackgroundThread = win.FALSE, .SuppressExternalCodecs = win.FALSE };
    _ = win.GdiplusStartup(&token, &gsi, null);

    const media_path = resolveMediaPath(alloc, cmd) orelse {
        common.logImpl("main", "media path null", .{});
        _ = win.GdiplusShutdown(token);
        _ = win.c.MFShutdown();
        win.c.CoUninitialize();
        return;
    };
    common.g_isVideo = media.isVideoFile(media_path);
    common.logImpl("main", "isVideo={}", .{common.g_isVideo});

    if (!common.g_isVideo and !media.loadGif(media_path)) {
        common.logImpl("main", "gif load fail", .{});
        _ = win.GdiplusShutdown(token);
        _ = win.c.MFShutdown();
        win.c.CoUninitialize();
        return;
    }

    g_hInst = win.c.GetModuleHandleW(null);

    var hostWc: win.c.WNDCLASSW = std.mem.zeroes(win.c.WNDCLASSW);
    hostWc.lpfnWndProc = hostProc;
    hostWc.hInstance = g_hInst;
    hostWc.lpszClassName = asciiW("DynamicWallpaperHost");
    _ = win.c.RegisterClassW(&hostWc);

    var wc: win.c.WNDCLASSW = std.mem.zeroes(win.c.WNDCLASSW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = g_hInst;
    wc.hCursor = win.c.LoadCursorW(null, win.c.IDC_ARROW);
    wc.hbrBackground = @ptrCast(@alignCast(win.c.GetStockObject(win.c.BLACK_BRUSH)));
    wc.lpszClassName = asciiW("DynamicWallpaper");
    _ = win.c.RegisterClassW(&wc);

    common.g_taskbarCreated = win.c.RegisterWindowMessageW(asciiW("TaskbarCreated"));
    common.g_host = win.c.CreateWindowExW(0, asciiW("DynamicWallpaperHost"), asciiW(""), 0, 0, 0, 0, 0, @as(win.HWND, @ptrFromInt(0)), null, g_hInst, null);

    if (common.g_host == null or !createWallpaperWindow()) {
        common.logImpl("main", "host/window fail host={}", .{common.g_host != null});
        _ = win.GdiplusShutdown(token);
        _ = win.c.MFShutdown();
        win.c.CoUninitialize();
        return;
    }

    _ = desktop.embedOrFallback(common.g_hwnd.?);

    if (common.g_isVideo) {
        if (!d3d.d3dInit(common.g_hwnd.?, media_path)) {
            d3d.d3dShutdown();
            _ = win.GdiplusShutdown(token);
            _ = win.c.MFShutdown();
            win.c.CoUninitialize();
            return;
        }
    }

    common.writeFileMarker("wallpaper.ok");
    ensureGuardAlive();

    var firstDelay: win.UINT = 33;
    if (common.g_isVideo) {
        firstDelay = 16;
    } else if (media.g_frameCount > 0) {
        firstDelay = if (media.g_delays[0] != 0) media.g_delays[0] else 100;
    }
    _ = win.c.SetTimer(common.g_host.?, common.TIMER_FRAME, firstDelay, null);
    _ = win.c.SetTimer(common.g_host.?, common.TIMER_WATCHDOG, common.WATCHDOG_MS, null);

    var msg: win.MSG = undefined;
    while (win.c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win.c.TranslateMessage(&msg);
        _ = win.c.DispatchMessageW(&msg);
    }

    _ = win.c.KillTimer(common.g_host.?, common.TIMER_FRAME);
    _ = win.c.KillTimer(common.g_host.?, common.TIMER_WATCHDOG);
    if (common.g_hwnd) |h| {
        if (win.c.IsWindow(h) != 0) _ = win.c.DestroyWindow(h);
    }
    d3d.d3dShutdown();
    render.releaseBackbuffer();
    if (media.g_img != null) {
        _ = win.GdipDisposeImage(media.g_img);
        media.g_img = null;
    }
    _ = win.GdiplusShutdown(token);
    _ = win.c.MFShutdown();
    win.c.CoUninitialize();
}

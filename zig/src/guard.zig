// guard.zig - KiloWallpaper (Zig) 独立守护进程
//
// 对齐 cpp/guard.cpp：主进程被外部强杀后约 1 秒内拉起；优雅关闭握手
// （wallpaper.graceful）时自己退出、绝不复活。独立进程名 DynamicWallpaperGuard.exe，
// 优化软件按进程名批量清理时只命中主进程，守护存活即可复活。
const std = @import("std");
const win = @import("win.zig");
const common = @import("common.zig");

fn asciiW(comptime s: []const u8) [*:0]const win.WCHAR {
    const arr = comptime blk: {
        var a: [s.len:0]win.WCHAR = undefined;
        for (s, 0..) |c, i| a[i] = c;
        break :blk a;
    };
    return @ptrCast(&arr);
}

fn exeDir(buf: []win.WCHAR) usize {
    const n = win.c.GetModuleFileNameW(null, buf.ptr, @intCast(buf.len));
    var last: usize = 0;
    var i: usize = 0;
    while (i < n and i < buf.len) : (i += 1) {
        if (buf[i] == '\\' or buf[i] == '/') last = i + 1;
    }
    return last;
}

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

fn launchMain() void {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = exeDir(&buf);
    const full_len = joinName(&buf, dir_len, "DynamicWallpaper.exe");
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

fn registerRestart() void {
    const k32 = win.c.GetModuleHandleW(asciiW("kernel32.dll"));
    if (k32 == null) return;
    if (win.c.GetProcAddress(k32, "RegisterApplicationRestart")) |fp| {
        const Fn = *const fn ([*:0]const u16, u32) callconv(.C) win.HRESULT;
        const f: Fn = @ptrCast(fp);
        _ = f(asciiW(""), 0);
    }
}

pub fn main() void {
    // 单实例：已有守护则退出（先启动者为主）
    const gm = win.c.CreateMutexW(null, win.TRUE, asciiW("DynamicWallpaper_Guard"));
    if (gm == null or win.c.GetLastError() == win.c.ERROR_ALREADY_EXISTS) return;

    common.writePidFile("wallpaper.guard.pid");
    registerRestart();

    var just_launched = false;
    while (true) {
        _ = win.c.Sleep(1000);

        if (common.fileExists("wallpaper.graceful")) {
            // 先确认主进程确实已退出再消费 graceful：否则会在新主进程写入
            // wallpaper.ok 后把残留 graceful 一并清掉，导致该会话失去崩溃自愈。
            if (!common.isOurProcess(common.readPidFile("wallpaper.main.pid"), "DynamicWallpaper.exe")) {
                common.deleteFileIf("wallpaper.graceful");
                common.deleteFileIf("wallpaper.ok");
                return;
            }
            common.deleteFileIf("wallpaper.graceful");
            continue;
        }

        if (common.isOurProcess(common.readPidFile("wallpaper.main.pid"), "DynamicWallpaper.exe")) {
            just_launched = false;
            continue;
        }

        // 主进程不在：从未成功初始化则不保活；刚拉起过一次又不见则停（防重启风暴）
        if (!common.fileExists("wallpaper.ok") or just_launched) return;

        // 注意：不要代删 wallpaper.quit——那是用户的关闭请求，留给主进程消费。
        just_launched = true;
        common.deleteFileIf("wallpaper.ok");
        launchMain();
    }
}

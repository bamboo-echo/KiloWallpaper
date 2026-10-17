// common.zig - 跨模块共享状态与辅助（配置/看门狗/守护共用的工具）
//
// 对应 cpp/ 的 wallpaper.h 全局状态 + main.cpp/guard.cpp 里的 GetExeDir、
// LogFail、pid/marker 文件、IsOurProcess 等工具函数。cpp 用 extern 全局 + 头文件
// 共享，Zig 这里集中到 common 模块，避免循环依赖。
const std = @import("std");
const win = @import("win.zig");

// ---------- 共享状态（cpp 里分散在各 .cpp，这里集中） ----------
pub var g_hwnd: ?win.HWND = null; // 壁纸窗口
pub var g_host: ?win.HWND = null; // 消息宿主窗口（定时器/看门狗）
pub var g_winW: i32 = 0;
pub var g_winH: i32 = 0;
pub var g_taskbarCreated: win.UINT = 0;
pub var g_isVideo: bool = false;
pub var g_parent: ?win.HWND = null; // 当前嵌入的父窗口（看门狗使用）

pub const TIMER_FRAME: win.UINT = 1;
pub const TIMER_WATCHDOG: win.UINT = 2;
pub const WATCHDOG_MS: win.UINT = 3000;

// ---------- 路径工具 ----------
// 把 ASCII 进程名/标记文件名宽化并追加到 out（out 已含目录且以 '\' 结尾）。
fn appendName(out: [*]win.WCHAR, dir_len: usize, name: []const u8) usize {
    var i = dir_len;
    var j: usize = 0;
    while (j < name.len and i < win.c.MAX_PATH) : ({
        i += 1;
        j += 1;
    }) out[i] = name[j];
    if (i < win.c.MAX_PATH) out[i] = 0;
    return i;
}

// 取 exe 目录（含尾随 '\'），写入 dir 并返回其长度。
fn getSelfDir(dir: [*]win.WCHAR) usize {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const n = win.c.GetModuleFileNameW(null, &buf, win.c.MAX_PATH);
    // 截断到最后一个分隔符 + 1
    var last: usize = 0;
    var k: usize = 0;
    while (k < n and k < win.c.MAX_PATH) : (k += 1) {
        dir[k] = buf[k];
        if (buf[k] == '\\' or buf[k] == '/') last = k + 1;
    }
    return last;
}

// ---------- 日志：追加到 exe 目录 debug.log，带结构化前缀 ----------
// 与 cpp 一致：前缀如 [embed]/[d3d]。日志只在异常/关键路径写，避免把日志撑爆。
pub fn logImpl(prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = getSelfDir(&buf);
    const full_len = appendName(&buf, dir_len, "debug.log");
    const fh = win.c._wfopen(buf[0..full_len].ptr, asciiW("a"));
    if (fh == null) return;
    var st: win.c.SYSTEMTIME = undefined;
    win.c.GetLocalTime(&st);
    var hdr: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} [{s}] ",
        .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, prefix }) catch return;
    _ = win.c.fwrite(h.ptr, 1, h.len, fh.?);
    var msg: [512]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, fmt, args) catch return;
    _ = win.c.fwrite(m.ptr, 1, m.len, fh.?);
    _ = win.c.fwrite("\n".ptr, 1, 1, fh.?);
    _ = win.c.fclose(fh.?);
}

// 把 ASCII 字面量宽化为以 0 结尾的 WCHAR 数组（仅用于纯 ASCII 文件名/模式串）
fn asciiW(comptime s: []const u8) [*:0]const win.WCHAR {
    const lit: [s.len:0]win.WCHAR = comptime blk: {
        var a: [s.len:0]win.WCHAR = undefined;
        for (s, 0..) |c, i| a[i] = c;
        break :blk a;
    };
    return @ptrCast(&lit);
}

// ---------- 标记文件 / pid 文件（exe 目录，按 GetModuleFileNameW 定位） ----------
// 关键坑（cpp）：写文件先写 .tmp 再 MoveFileExW 原子替换，否则并发读侧可能读到
// 空文件误判对方已退出而重复拉起。这里完全对齐。
pub fn writePidFile(name: []const u8) void {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = getSelfDir(&buf);
    const tmp_len = appendName(&buf, dir_len, name);
    // tmp = dir/name + ".tmp"
    var tmp: [win.c.MAX_PATH]win.WCHAR = undefined;
    var i: usize = 0;
    while (i < tmp_len and i < tmp.len) : (i += 1) tmp[i] = buf[i];
    const dot = asciiW(".tmp");
    var k: usize = 0;
    while (dot[k] != 0 and i < tmp.len) : ({
        i += 1;
        k += 1;
    }) tmp[i] = dot[k];
    if (i < tmp.len) tmp[i] = 0;

    const fh = win.c._wfopen(tmp[0..i].ptr, asciiW("w"));
    if (fh == null) return;
    const pid = win.c.GetCurrentProcessId();
    var pidbuf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&pidbuf, "{d}", .{pid}) catch return;
    _ = win.c.fwrite(s.ptr, 1, s.len, fh.?);
    _ = win.c.fclose(fh.?);

    // 目标全路径 = dir/name
    var dst: [win.c.MAX_PATH]win.WCHAR = undefined;
    var d: usize = 0;
    while (d < tmp_len and d < dst.len) : (d += 1) dst[d] = buf[d];
    if (d < dst.len) dst[d] = 0;
    _ = win.c.MoveFileExW(tmp[0..i].ptr, dst[0..d].ptr,
        win.c.MOVEFILE_REPLACE_EXISTING | win.c.MOVEFILE_WRITE_THROUGH);
}

pub fn readPidFile(name: []const u8) win.DWORD {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = getSelfDir(&buf);
    const full_len = appendName(&buf, dir_len, name);
    const fh = win.c._wfopen(buf[0..full_len].ptr, asciiW("r"));
    if (fh == null) return 0;
    var b2: [32]win.WCHAR = undefined;
    _ = win.c.fgetws(&b2, 32, fh.?);
    _ = win.c.fclose(fh.?);
    return @intCast(win.c._wtoi(&b2));
}

pub fn writeFileMarker(name: []const u8) void {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = getSelfDir(&buf);
    const full_len = appendName(&buf, dir_len, name);
    const fh = win.c._wfopen(buf[0..full_len].ptr, asciiW("w"));
    if (fh != null) _ = win.c.fclose(fh.?);
}

pub fn fileExists(name: []const u8) bool {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = getSelfDir(&buf);
    const full_len = appendName(&buf, dir_len, name);
    const a = win.c.GetFileAttributesW(buf[0..full_len].ptr);
    return a != win.c.INVALID_FILE_ATTRIBUTES;
}

pub fn deleteFileIf(name: []const u8) void {
    var buf: [win.c.MAX_PATH]win.WCHAR = undefined;
    const dir_len = getSelfDir(&buf);
    const full_len = appendName(&buf, dir_len, name);
    _ = win.c.DeleteFileW(buf[0..full_len].ptr);
}

// pid 进程的可执行文件是否位于本 exe 目录且名为 exeName（守护/主进程互认）
pub fn isOurProcess(pid: win.DWORD, exeName: []const u8) bool {
    if (pid == 0) return false;
    const h = win.c.OpenProcess(win.c.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, pid);
    if (h == null) return false;
    var path: [win.c.MAX_PATH]win.WCHAR = undefined;
    var cch: win.DWORD = win.c.MAX_PATH;
    const got = win.c.QueryFullProcessImageNameW(h, 0, &path, &cch);
    _ = win.c.CloseHandle(h);
    if (got == 0) return true; // 能 Open 到即视为存活（取证失败按活处理，保守避免误判重复拉起）

    var self: [win.c.MAX_PATH]win.WCHAR = undefined;
    _ = win.c.GetModuleFileNameW(null, &self, win.c.MAX_PATH);

    const s1 = lastSlashIdx(path[0..cch]);
    const s2 = lastSlashIdx(self[0..win.c.MAX_PATH]);
    if (s1 == null or s2 == null) return false;
    // 比较目录前缀
    const dir_len = s1.?;
    if (dir_len > self[0..win.c.MAX_PATH].len) return false;
    var i: usize = 0;
    while (i < dir_len) : (i += 1) {
        if (win.c.towlower(path[i]) != win.c.towlower(self[i])) return false;
    }
    // 比较文件名（不区分大小写）
    const name_part = path[s1.?..cch];
    var j: usize = 0;
    while (j < exeName.len and j < name_part.len) : (j += 1) {
        if (win.c.towlower(name_part[j]) != exeName[j]) return false;
    }
    return j == exeName.len and j == name_part.len;
}

fn lastSlashIdx(p: []const win.WCHAR) ?usize {
    var res: ?usize = null;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\' or p[i] == '/') res = i + 1; // 含分隔符本身，作为目录长度
    }
    return res;
}

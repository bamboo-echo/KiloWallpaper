// media.zig - GIF / 静态图解码（对应 cpp/media.cpp，改用 GDI+ 平面 C 接口）
//
// cpp 用 C++ 的 Image::FromFile 等类方法；Zig 不能直连 C++ 类，故改用 gdiplus.dll
// 导出的 Gdip* 平面函数（GdipLoadImageFromFile 等）。逻辑与 cpp 完全对齐：
// 读帧数、读每帧延时属性（单位 1/100 秒，×10 得 ms），cover 缩放交给 render.zig。
const std = @import("std");
const win = @import("win.zig");
const common = @import("common.zig");

pub var g_img: ?*win.GpImage = null;
pub var g_frameCount: win.UINT = 0;
pub var g_curFrame: win.UINT = 0;
pub var g_delays: [256]win.UINT = [_]win.UINT{100} ** 256; // 足够绝大多数 GIF（>256 帧罕见）
pub var g_lastHr: win.HRESULT = win.S_OK;

// FrameDimensionTime GUID（"time" 维度，GIF 帧序列）
pub const FrameDimensionTime = win.GUID{
    .Data1 = 0x6AEDBD6D,
    .Data2 = 0x3FB5,
    .Data3 = 0x418A,
    .Data4 = [_]u8{ 0x83, 0xA6, 0x7F, 0x45, 0x22, 0x9D, 0xC8, 0x72 },
};

pub fn isVideoFile(path: []const win.WCHAR) bool {
    const ext = win.c.PathFindExtensionW(path.ptr);
    if (ext == null or ext[0] == 0) return false;
    const kExts = [_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral(".mp4"),
        std.unicode.utf8ToUtf16LeStringLiteral(".mov"),
        std.unicode.utf8ToUtf16LeStringLiteral(".avi"),
        std.unicode.utf8ToUtf16LeStringLiteral(".wmv"),
        std.unicode.utf8ToUtf16LeStringLiteral(".mkv"),
        std.unicode.utf8ToUtf16LeStringLiteral(".webm"),
        std.unicode.utf8ToUtf16LeStringLiteral(".m4v"),
    };
    for (kExts) |e| {
        if (win.c._wcsicmp(ext, e.ptr) == 0) return true;
    }
    return false;
}

pub fn loadGif(path: []const win.WCHAR) bool {
    if (g_img != null) {
        _ = win.GdipDisposeImage(g_img);
        g_img = null;
    }
    var img: ?*win.GpImage = null;
    const hr = win.GdipLoadImageFromFile(path.ptr, @ptrCast(&img));
    if (hr != win.Ok or img == null) {
        g_lastHr = win.E_FAIL;
        return false;
    }
    g_img = img;

    var dimCount: win.UINT = 0;
    if (win.GdipImageGetFrameDimensionsCount(img, @ptrCast(&dimCount)) != win.Ok or dimCount == 0) return false;
    const dims = std.heap.page_allocator.alloc(win.GUID, dimCount) catch return false;
    defer std.heap.page_allocator.free(dims);
    if (win.GdipImageGetFrameDimensionsList(img, dims.ptr, dimCount) != win.Ok) return false;
    const dim = dims[0];

    var fc: win.UINT = 0;
    if (win.GdipImageGetFrameCount(img, @ptrCast(&dim), @ptrCast(&fc)) != win.Ok or fc == 0) return false;
    g_frameCount = fc;

    // 默认延时表
    var i: usize = 0;
    while (i < fc and i < g_delays.len) : (i += 1) g_delays[i] = 100;

    var sz: win.UINT = 0;
    if (win.GdipGetPropertyItemSize(img, win.PropertyTagFrameDelay, @ptrCast(&sz)) == win.Ok and sz > 0) {
        const buf = std.heap.page_allocator.alloc(u8, sz) catch return false;
        defer std.heap.page_allocator.free(buf);
        if (win.GdipGetPropertyItem(img, win.PropertyTagFrameDelay, sz, buf.ptr) == win.Ok) {
            const pi = @as(*win.PropertyItem, @ptrCast(@alignCast(buf.ptr)));
            const n = pi.length / @sizeOf(c_int); // LONG 每项 4 字节
            const delays: [*]c_int = @ptrCast(@alignCast(pi.value));
            var k: win.UINT = 0;
            while (k < n and k < fc and k < g_delays.len) : (k += 1) {
                g_delays[k] = @intCast(delays[k] * 10);
                if (g_delays[k] < 10) g_delays[k] = 10;
            }
        }
    }
    // 多帧 GIF 末帧若无延时，沿用前一帧（避免末帧闪一下）
    if (fc > 1 and g_delays[fc - 1] < 10) g_delays[fc - 1] = g_delays[fc - 2];
    g_curFrame = 0;
    g_lastHr = win.S_OK;
    return true;
}

fn asciiW(comptime s: []const u8) [*]const win.WCHAR {
    comptime var b: [s.len + 1]win.WCHAR = undefined;
    comptime {
        var i = 0;
        while (i < s.len) : (i += 1) b[i] = s[i];
        b[s.len] = 0;
    }
    return &b;
}

// render.zig - GIF / 静态图绘制（对应 cpp/render.cpp，GDI+ 平面 C 接口）
//
// 双缓冲 DC 避免闪烁：离屏 memDC 画好整帧后 BitBlt 到客户区。cover 缩放用
// HighQualityBicubic（cpp 同款）。视频不走这里——d3dplayer 用 D3D 交换链常驻
// 呈现（见 main 的 WM_PAINT 视频分支直接返回）。
const std = @import("std");
const win = @import("win.zig");
const common = @import("common.zig");
const media = @import("media.zig");

var g_memDC: ?win.HDC = null;
var g_memBmp: ?win.HBITMAP = null;
var g_oldBmp: ?*anyopaque = null;
var g_bmpW: i32 = 0;
var g_bmpH: i32 = 0;

fn coverRect(dstW: i32, dstH: i32, imgW: i32, imgH: i32) [4]i32 {
    const scaleW: f64 = @as(f64, @floatFromInt(dstW)) / @as(f64, @floatFromInt(imgW));
    const scaleH: f64 = @as(f64, @floatFromInt(dstH)) / @as(f64, @floatFromInt(imgH));
    const scale = if (scaleW > scaleH) scaleW else scaleH;
    const w = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(imgW)) * scale)));
    const h = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(imgH)) * scale)));
    const x = @divTrunc(dstW - w, 2);
    const y = @divTrunc(dstH - h, 2);
    return [_]i32{ x, y, w, h };
}

pub fn drawGifFrame(dc: win.HDC, dstW: i32, dstH: i32) void {
    if (media.g_img == null or dc == null) return;
    // 选中对应帧（GDI+ 按时间维度）
    _ = win.GdipImageSelectActiveFrame(media.g_img, @ptrCast(&media.FrameDimensionTime), media.g_curFrame);
    var imgW: win.UINT = 0;
    var imgH: win.UINT = 0;
    if (win.GdipGetImageWidth(media.g_img, @ptrCast(&imgW)) != win.Ok or
        win.GdipGetImageHeight(media.g_img, @ptrCast(&imgH)) != win.Ok) return;
    if (imgW == 0 or imgH == 0) return;

    var graphics: ?*win.GpGraphics = null;
    if (win.GdipCreateFromHDC(dc, @ptrCast(&graphics)) != win.Ok or graphics == null) return;
    defer _ = win.GdipDeleteGraphics(graphics);

    _ = win.GdipSetInterpolationMode(graphics, win.InterpolationModeHighQualityBicubic);
    const c = coverRect(dstW, dstH, @intCast(imgW), @intCast(imgH));
    _ = win.GdipDrawImageRectI(graphics, media.g_img, c[0], c[1], c[2], c[3]);
}

pub fn releaseBackbuffer() void {
    if (g_memDC == null) return;
    _ = win.c.SelectObject(g_memDC.?, g_oldBmp);
    if (g_memBmp != null) _ = win.c.DeleteObject(g_memBmp.?);
    _ = win.c.DeleteDC(g_memDC.?);
    g_memDC = null;
    g_memBmp = null;
    g_oldBmp = null;
    g_bmpW = 0;
    g_bmpH = 0;
}

pub fn ensureBackbuffer(dc: win.HDC, w: i32, h: i32) void {
    if (g_memDC != null and g_bmpW == w and g_bmpH == h) return;
    releaseBackbuffer();
    if (w <= 0 or h <= 0) return; // 非法尺寸：保持空缓冲，下次调用重试
    const m = win.c.CreateCompatibleDC(dc);
    const b = if (m != null) win.c.CreateCompatibleBitmap(dc, w, h) else null;
    if (m == null or b == null) {
        // GDI 创建失败时不留半成品（否则后续全黑且无日志）
        if (m != null) _ = win.c.DeleteDC(m);
        if (b != null) _ = win.c.DeleteObject(b);
        return;
    }
    g_memDC = m;
    g_memBmp = b;
    g_oldBmp = win.c.SelectObject(m, b);
    g_bmpW = w;
    g_bmpH = h;
}

// main 的 WM_PAINT 调用：用 g_memDC 做绘制目标。暴露给 main。
pub fn getMemDC() ?win.HDC {
    return g_memDC;
}

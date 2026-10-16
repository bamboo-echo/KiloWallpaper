// render.cpp - DynamicWallpaper 绘制层（GIF / 静态图，GDI+）
// 视频不经过 GDI：d3dplayer.cpp 用 D3D11 交换链常驻呈现整个客户区，
// main.cpp 的 WM_PAINT 在视频模式下直接返回（见 main.cpp）。
#include "wallpaper.h"

// 双缓冲 DC（GIF；main.cpp 的 WM_PAINT 也使用）
HDC g_memDC = nullptr;
static HBITMAP g_memBmp = nullptr;
static HBITMAP g_oldBmp = nullptr;
static int g_bmpW = 0, g_bmpH = 0;

static void CoverRect(int dstW, int dstH, int imgW, int imgH, int& x, int& y, int& w, int& h) {
    double scaleW = (double)dstW / imgW, scaleH = (double)dstH / imgH;
    double scale = scaleW > scaleH ? scaleW : scaleH;
    w = (int)(imgW * scale);
    h = (int)(imgH * scale);
    x = (dstW - w) / 2;
    y = (dstH - h) / 2;
}

void DrawGifFrame(HDC dc, int dstW, int dstH) {
    if (!g_img) return;
    g_img->SelectActiveFrame(&FrameDimensionTime, g_curFrame);
    int imgW = (int)g_img->GetWidth(), imgH = (int)g_img->GetHeight();
    if (imgW <= 0 || imgH <= 0) return;
    Graphics g(dc);
    g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
    int x, y, w, h;
    CoverRect(dstW, dstH, imgW, imgH, x, y, w, h);
    g.DrawImage(g_img, x, y, w, h);
}

void ReleaseBackbuffer() {
    if (!g_memDC) return;
    SelectObject(g_memDC, g_oldBmp);
    if (g_memBmp) DeleteObject(g_memBmp);
    DeleteDC(g_memDC);
    g_memDC = nullptr;
    g_memBmp = nullptr;
    g_oldBmp = nullptr;
    g_bmpW = g_bmpH = 0;
}

void EnsureBackbuffer(HDC dc, int w, int h) {
    if (g_memDC && g_bmpW == w && g_bmpH == h) return;
    ReleaseBackbuffer();
    if (w <= 0 || h <= 0) return;   // 非法尺寸：保持空缓冲，下次调用重试
    HDC m = CreateCompatibleDC(dc);
    HBITMAP b = m ? CreateCompatibleBitmap(dc, w, h) : nullptr;
    if (!m || !b) {
        // GDI 创建失败时不留半成品：否则 SelectObject(memDC, nullptr) 会让 DC
        // 停留在 1x1 单色默认位图，而 g_bmpW/g_bmpH 仍被记为"已成功" → 之后
        // 既不重试也是全黑（静默黑屏，无日志）。
        if (m) DeleteDC(m);
        if (b) DeleteObject(b);
        return;
    }
    g_memDC = m;
    g_memBmp = b;
    g_oldBmp = (HBITMAP)SelectObject(m, b);
    g_bmpW = w;
    g_bmpH = h;
}

// render.c - DynamicWallpaper (C 版) 绘制层（GIF / 静态图，GDI+ 扁平 C API）
// 视频不经过 GDI：d3dplayer.c 用 D3D11 交换链常驻呈现整个客户区，
// main.c 的 WM_PAINT 在视频模式下直接返回（见 main.c）。
#include "wallpaper.h"

// 双缓冲 DC（GIF；main.c 的 WM_PAINT 也使用）
HDC g_memDC = NULL;
static HBITMAP g_memBmp = NULL;
static HBITMAP g_oldBmp = NULL;
static int g_bmpW = 0, g_bmpH = 0;

static void CoverRect(int dstW, int dstH, int imgW, int imgH,
                      int* x, int* y, int* w, int* h) {
    double scaleW = (double)dstW / imgW, scaleH = (double)dstH / imgH;
    double scale = scaleW > scaleH ? scaleW : scaleH;
    *w = (int)(imgW * scale);
    *h = (int)(imgH * scale);
    *x = (dstW - *w) / 2;
    *y = (dstH - *h) / 2;
}

void DrawGifFrame(HDC dc, int dstW, int dstH) {
    if (!g_img) return;
    // 选帧（GIF 多帧按 g_curFrame 推进；静态图只有 1 帧恒为 0）
    if (GdipImageSelectActiveFrame(g_img, &GDIP_FrameDimensionTime, g_curFrame) != Ok)
        return;
    UINT iw = 0, ih = 0;
    GdipGetImageWidth(g_img, &iw);
    GdipGetImageHeight(g_img, &ih);
    if (iw <= 0 || ih <= 0) return;
    GpGraphics* g = NULL;
    if (GdipCreateFromHDC(dc, &g) != Ok || !g) return;
    GdipSetInterpolationMode(g, InterpolationModeHighQualityBicubic);  // cover 缩放用双三次
    int x, y, w, h;
    CoverRect(dstW, dstH, (int)iw, (int)ih, &x, &y, &w, &h);
    GdipDrawImageRectI(g, g_img, x, y, w, h);
    GdipDeleteGraphics(g);
}

void ReleaseBackbuffer(void) {
    if (!g_memDC) return;
    SelectObject(g_memDC, g_oldBmp);
    if (g_memBmp) DeleteObject(g_memBmp);
    DeleteDC(g_memDC);
    g_memDC = NULL;
    g_memBmp = NULL;
    g_oldBmp = NULL;
    g_bmpW = g_bmpH = 0;
}

void EnsureBackbuffer(HDC dc, int w, int h) {
    if (g_memDC && g_bmpW == w && g_bmpH == h) return;
    ReleaseBackbuffer();
    if (w <= 0 || h <= 0) return;   // 非法尺寸：保持空缓冲，下次调用重试
    HDC m = CreateCompatibleDC(dc);
    HBITMAP b = m ? CreateCompatibleBitmap(dc, w, h) : NULL;
    if (!m || !b) {
        // GDI 创建失败时不留半成品：否则 SelectObject(memDC, NULL) 会让 DC
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

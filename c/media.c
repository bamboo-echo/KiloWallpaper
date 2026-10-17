// media.c - DynamicWallpaper (C 版) 图片解码层（GIF / 静态图，GDI+ 扁平 C API）
// 视频解码不在这里：整条视频链路已迁到 d3dplayer.c（D3D11 + DXVA + 无缝循环），
// 本文件只保留 GDI+ 图片路径（main.c 里 g_isVideo 为 0 时才走这里）。
#include "wallpaper.h"

#include <stdlib.h>   // malloc/free

// ===================== 媒体状态定义（共享） =====================
GpImage* g_img = NULL;
UINT g_frameCount = 0, g_curFrame = 0;
UINT* g_delays = NULL;            // 每帧延时(ms) 动态数组
HRESULT g_lastHr = S_OK;

int IsVideoFile(const wchar_t* path) {
    const wchar_t* ext = PathFindExtensionW(path);
    if (!ext || !*ext) return 0;
    static const wchar_t* kExts[] = {
        L".mp4", L".mov", L".avi", L".wmv", L".mkv", L".webm", L".m4v"
    };
    int n = sizeof(kExts) / sizeof(kExts[0]);
    for (int i = 0; i < n; i++) {
        if (_wcsicmp(ext, kExts[i]) == 0) return 1;
    }
    return 0;
}

int LoadGif(const wchar_t* path) {
    if (g_img) { GdipDisposeImage(g_img); g_img = NULL; }
    if (g_delays) { free(g_delays); g_delays = NULL; }
    if (GdipLoadImageFromFile(path, &g_img) != Ok || !g_img) {
        g_lastHr = E_FAIL;
        return 0;
    }
    // 注：GdipLoadImageFromFile 返回 Ok 即已加载成功；GDI+ flat API 没有
    // GdipGetImageLastStatus（SDK 头里不存在，链接会失败），故不额外查状态。
    UINT dimCount = 0;
    if (GdipImageGetFrameDimensionsCount(g_img, &dimCount) != Ok || dimCount == 0) return 0;
    GUID* dims = (GUID*)malloc(dimCount * sizeof(GUID));
    if (!dims) { g_lastHr = E_FAIL; return 0; }
    GdipImageGetFrameDimensionsList(g_img, dims, dimCount);
    GUID dim = dims[0];          // 取首个维度（动画 GIF 即"time"；静态图为"image"）
    free(dims);

    if (GdipImageGetFrameCount(g_img, &dim, &g_frameCount) != Ok || g_frameCount <= 0)
        return 0;

    g_delays = (UINT*)malloc(sizeof(UINT) * g_frameCount);
    if (!g_delays) { g_lastHr = E_FAIL; return 0; }
    for (UINT i = 0; i < g_frameCount; i++) g_delays[i] = 100;

    UINT sz = 0;
    GdipGetPropertyItemSize(g_img, PropertyTagFrameDelay, &sz);
    if (sz > 0) {
        GpPropertyItem* pi = (GpPropertyItem*)malloc(sz);
        if (pi) {
            if (GdipGetPropertyItem(g_img, PropertyTagFrameDelay, sz, pi) == Ok) {
                LONG* delays = (LONG*)pi->value;
                LONG n = (LONG)(pi->length / sizeof(LONG));
                for (LONG i = 0; i < n && (UINT)i < g_frameCount; i++) {
                    g_delays[i] = (UINT)(delays[i] * 10);   // 单位 1/100s → ms
                    if (g_delays[i] < 10) g_delays[i] = 10;
                }
            }
            free(pi);
        }
    }
    // 末帧延时缺失时复用上一帧，避免 GIF 末帧卡顿（cpp 同款处理）
    if (g_frameCount > 1 && g_delays[g_frameCount - 1] < 10)
        g_delays[g_frameCount - 1] = g_delays[g_frameCount - 2];
    g_curFrame = 0;
    g_lastHr = S_OK;
    return 1;
}

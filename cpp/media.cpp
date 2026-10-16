// media.cpp - DynamicWallpaper 图片解码层（GIF / 静态图，GDI+）
// 视频解码不在这里：整条视频链路已迁到 d3dplayer.cpp（D3D11 + DXVA + 无缝循环），
// 本文件只保留 GDI+ 图片路径（main.cpp 里 g_isVideo 为 false 时才走这里）。
#include "wallpaper.h"

// ---------- 媒体状态定义（共享） ----------
Image* g_img = nullptr;
UINT g_frameCount = 0, g_curFrame = 0;
std::vector<UINT> g_delays;
HRESULT g_lastHr = S_OK;

bool IsVideoFile(const std::wstring& path) {
    const wchar_t* ext = PathFindExtensionW(path.c_str());
    if (!ext || !*ext) return false;
    static const wchar_t* kExts[] = {
        L".mp4", L".mov", L".avi", L".wmv", L".mkv", L".webm", L".m4v"
    };
    for (const wchar_t* e : kExts) {
        if (_wcsicmp(ext, e) == 0) return true;
    }
    return false;
}

bool LoadGif(const std::wstring& path) {
    if (g_img) { delete g_img; g_img = nullptr; }
    g_img = Image::FromFile(path.c_str());
    if (!g_img || g_img->GetLastStatus() != Ok) {
        g_lastHr = E_FAIL;
        return false;
    }
    GUID dim; UINT dimCount = g_img->GetFrameDimensionsCount();
    if (dimCount == 0) return false;
    std::vector<GUID> dims(dimCount);
    g_img->GetFrameDimensionsList(dims.data(), dimCount);
    dim = dims[0];
    g_frameCount = g_img->GetFrameCount(&dim);
    if (g_frameCount <= 0) return false;
    g_delays.assign(g_frameCount, 100);
    UINT sz = g_img->GetPropertyItemSize(PropertyTagFrameDelay);
    if (sz > 0) {
        std::vector<BYTE> buf(sz);
        if (g_img->GetPropertyItem(PropertyTagFrameDelay, sz, (PropertyItem*)buf.data()) == Ok) {
            PropertyItem* pi = (PropertyItem*)buf.data();
            LONG n = pi->length / sizeof(LONG);
            LONG* delays = (LONG*)pi->value;
            for (LONG i = 0; i < n && (UINT)i < g_frameCount; i++) {
                g_delays[i] = (UINT)(delays[i] * 10);
                if (g_delays[i] < 10) g_delays[i] = 10;
            }
        }
    }
    if (g_frameCount > 1 && g_delays[g_frameCount - 1] < 10)
        g_delays[g_frameCount - 1] = g_delays[g_frameCount - 2];
    g_curFrame = 0;
    g_lastHr = S_OK;
    return true;
}

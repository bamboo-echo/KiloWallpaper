// wallpaper.h - DynamicWallpaper (C 版) 跨模块共享声明
//
// 项目结构（与 cpp 完全对齐）：
//   main.c     入口/窗口/看门狗/渲染调度/配置/单实例/守护互保
//   media.c    GIF/静态图解码（GDI+ 扁平 C API）
//   render.c   绘制（cover 缩放 + 双缓冲）
//   desktop.c  桌面嵌入（Progman/WorkerW 探测、双向 z 锚定）
//   d3dplayer.c 视频（MF SourceReader + DXVA 硬解 + D3D11 VideoProcessor + DComp）
//   guard.c    独立进程名守护
//
// 纯 C（C11）+ Win32 API，零第三方依赖。COM 在 C 中通过接口首成员 lpVtbl
// （函数指针表）手动调用：iface->lpVtbl->Method(iface, ...)。
#ifndef WALLPAPER_H
#define WALLPAPER_H

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shlwapi.h>
#include <mfapi.h>      // MF_VERSION / MFStartup（main.c 启动 Media Foundation 需要）
#include <stddef.h>

// ===================== GDI+ 扁平 C API 垫片 =====================
// GDI+ 是 C++ 封装库，C 下只能用 gdiplus.dll 导出的"flat"函数。SDK 的
// gdiplusflat.h 不暴露 GdiplusStartup，且 gdiplusinit.h 的 startup 结构带
// C++ 构造函数无法在 C 编译。这里自包含声明我们需要的少量 flat 函数，
// 链接 gdiplus.lib 即可（与 C++ 版链接同一份 gdiplus.dll，行为一致）。
#ifndef GDIP_C_SHIM
#define GDIP_C_SHIM
typedef struct GpImage    GpImage;     // 不透明：图片/位图（含 GIF 各帧）
typedef struct GpGraphics GpGraphics;  // 不透明：绘制上下文
typedef INT GpStatus;

#define Ok 0   // GDI+ 成功状态码

// GDI+ startup 输入结构（与 gdiplusinit.h 的布局完全一致，只是去掉构造函数）
typedef struct {
    UINT32 GdiplusVersion;          // 必须为 1
    void*  DebugEventCallback;      // 自由构建忽略
    BOOL   SuppressBackgroundThread;
    BOOL   SuppressExternalCodecs;
} GdiplusStartupInput;

// 属性项：与 SDK PropertyItem 布局一致（PROPID=ULONG, length=ULONG, type=WORD）
typedef struct {
    ULONG id;
    ULONG length;
    WORD  type;
    VOID* value;
} GpPropertyItem;

GpStatus __stdcall GdiplusStartup(ULONG_PTR* token, const GdiplusStartupInput* input, void* output);
void     __stdcall GdiplusShutdown(ULONG_PTR token);

GpStatus __stdcall GdipLoadImageFromFile(const WCHAR* filename, GpImage** image);
GpStatus __stdcall GdipGetImageWidth(GpImage* image, UINT* width);
GpStatus __stdcall GdipGetImageHeight(GpImage* image, UINT* height);
GpStatus __stdcall GdipImageGetFrameDimensionsCount(GpImage* image, UINT* count);
GpStatus __stdcall GdipImageGetFrameDimensionsList(GpImage* image, GUID* dimensionIDs, UINT count);
GpStatus __stdcall GdipImageGetFrameCount(GpImage* image, const GUID* dimensionID, UINT* count);
GpStatus __stdcall GdipGetPropertyItemSize(GpImage* image, ULONG propId, UINT* size);
GpStatus __stdcall GdipGetPropertyItem(GpImage* image, ULONG propId, UINT size, GpPropertyItem* buffer);
GpStatus __stdcall GdipImageSelectActiveFrame(GpImage* image, const GUID* dimensionID, UINT frameIndex);
GpStatus __stdcall GdipCreateFromHDC(HDC hdc, GpGraphics** graphics);
GpStatus __stdcall GdipSetInterpolationMode(GpGraphics* graphics, INT interpolationMode);
GpStatus __stdcall GdipDrawImageRectI(GpGraphics* graphics, GpImage* image, INT x, INT y, INT width, INT height);
GpStatus __stdcall GdipDeleteGraphics(GpGraphics* graphics);
GpStatus __stdcall GdipDisposeImage(GpImage* image);

// 帧延时属性标签（gdiplusimaging.h: 0x5100）
#ifndef PropertyTagFrameDelay
#define PropertyTagFrameDelay 0x5100
#endif

// 时间维度 GUID（gdiplusimaging.h 中的 FrameDimensionTime）。GIF 多帧靠它索引。
static const GUID GDIP_FrameDimensionTime = {
    0x6aedbd6d, 0x3fb5, 0x418a, { 0x83, 0xa6, 0x7f, 0x45, 0x22, 0x9d, 0xc8, 0x72 }
};

// 高质量双三次插值（InterpolationModeHighQualityBicubic = 7）
#ifndef InterpolationModeHighQualityBicubic
#define InterpolationModeHighQualityBicubic 7
#endif
#endif // GDIP_C_SHIM

// ===================== 常量 =====================
extern const UINT TIMER_FRAME;
extern const UINT TIMER_WATCHDOG;
extern const UINT WATCHDOG_MS;

// ===================== 主控制状态（main.c 定义） =====================
extern HINSTANCE g_hInst;
extern HWND g_hwnd;          // 壁纸窗口
extern HWND g_host;          // 消息宿主窗口（定时器/看门狗）
extern int  g_winW, g_winH;
extern UINT g_taskbarCreated;
extern int  g_isVideo;       // 1=视频 0=GIF/图片
extern HWND g_parent;        // 当前嵌入的父窗口（desktop.c 定义，看门狗使用）

// ===================== 媒体状态（media.c 定义） =====================
extern GpImage* g_img;               // GIF / 静态图（GDI+）
extern UINT g_frameCount, g_curFrame;
extern UINT* g_delays;               // 每帧延时(ms) 动态数组
extern HRESULT g_lastHr;

// ===================== 接口（media.c） =====================
int   IsVideoFile(const wchar_t* path);  // 扩展名判定：视频交给 d3dplayer.c
int   LoadGif(const wchar_t* path);      // GIF / 静态图

// ===================== 接口（render.c） =====================
extern HDC g_memDC;                 // 双缓冲 DC（GIF）
void DrawGifFrame(HDC dc, int dstW, int dstH);
void ReleaseBackbuffer(void);
void EnsureBackbuffer(HDC dc, int w, int h);

// ===================== 接口（desktop.c） =====================
RECT GetPrimaryMonitorRect(void);
void FitToParentOrMonitor(HWND hwnd);
int  EmbedOrFallback(HWND hwnd);
void EnsureWallpaperZOrder(HWND hwnd);   // 壁纸窗口 z 序校准（图标层后、壁纸层前）

#endif // WALLPAPER_H

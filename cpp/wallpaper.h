// wallpaper.h - DynamicWallpaper 跨模块共享声明
// 项目结构：main.cpp(入口/窗口) media.cpp(GIF解码) render.cpp(绘制)
//           desktop.cpp(嵌入) d3dplayer.cpp(视频播放)
#ifndef WALLPAPER_H
#define WALLPAPER_H

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <gdiplus.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mfobjects.h>
#include <shlwapi.h>
#include <string>
#include <vector>

using namespace Gdiplus;

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "uxtheme.lib")

// ---------- 常量 ----------
extern const UINT TIMER_FRAME;
extern const UINT TIMER_WATCHDOG;
extern const UINT WATCHDOG_MS;

// ---------- 主控制状态（main.cpp 定义） ----------
extern HINSTANCE g_hInst;
extern HWND g_hwnd;          // 壁纸窗口
extern HWND g_host;          // 消息宿主窗口（定时器/看门狗）
extern int g_winW, g_winH;
extern UINT g_taskbarCreated;
extern bool g_isVideo;       // true=视频 false=GIF/图片
extern HWND g_parent;        // 当前嵌入的父窗口（desktop.cpp 定义，看门狗使用）
extern bool g_embedOk;       // 当前窗口是否已嵌入成功（含顶层兜底，desktop.cpp 定义）

// ---------- 媒体状态（media.cpp 定义） ----------
extern Image* g_img;                     // GIF / 静态图（GDI+）
extern UINT g_frameCount, g_curFrame;
extern std::vector<UINT> g_delays;
extern HRESULT g_lastHr;

// ---------- 接口（media.cpp） ----------
bool IsVideoFile(const std::wstring& path);  // 扩展名判定：视频交给 d3dplayer.cpp
bool LoadGif(const std::wstring& path);      // GIF / 静态图

// ---------- 接口（render.cpp） ----------
extern HDC g_memDC;                 // 双缓冲 DC（GIF）
void DrawGifFrame(HDC dc, int dstW, int dstH);
void ReleaseBackbuffer();
void EnsureBackbuffer(HDC dc, int w, int h);

// ---------- 接口（desktop.cpp） ----------
RECT GetPrimaryMonitorRect();
void FitToParentOrMonitor(HWND hwnd);
bool EmbedOrFallback(HWND hwnd);
void EnsureWallpaperZOrder(HWND hwnd);   // 壁纸窗口 z 序校准（图标层后、壁纸层前）

#endif // WALLPAPER_H

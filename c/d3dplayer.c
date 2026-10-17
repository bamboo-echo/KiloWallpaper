// d3dplayer.c - SourceReader(DXVA 硬解) + D3D11 VideoProcessor 视频壁纸播放器（C 版）
//
// 闪屏根治原理（与 cpp 完全一致）：
//   EVR 方案的循环必须"会话结束→重建渲染器"，重启瞬间渲染器清屏→透出系统壁纸（闪）。
//   本方案循环 = ReadSample 到 EOS 后 SetCurrentPosition(0) 回开头继续解码，
//   D3D 交换链全程保留上一帧直到新帧 Present —— 渲染管线从不中断，物理上无闪屏。
//   （mpv / Wallpaper Engine 的无缝循环同一原理，此处用纯系统 API 自己实现。）
//
// 渲染管线：DXVA 硬解 NV12 → UpdateSubresource 上传 → VideoProcessor GPU
//   NV12→RGB 转换 + 缩放到屏幕 → swapchain Present(垂直同步)。
//   CPU 每帧只做一次内存拷贝（~3MB），占用极低。
//
// COM 在 C 中的调用方式：每个 COM 接口首成员是 lpVtbl（函数指针表），
// 通过 iface->lpVtbl->Method(iface, ...) 手动解引用虚函数（等价 C++ 的隐式 this）。
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <initguid.h>   // 在 MF/D3D 头之前，实例化 MF 属性 GUID 与接口 IID
#include <windows.h>
#include "d3dplayer.h"

#include <d3d11.h>
#include <d3d10.h>   // ID3D10Multithread：MF 解码工作线程共用 device 必须开多线程保护
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>

// C 中通过接口首成员 lpVtbl 手动调用虚函数：COMCALL(p, Method, args...)
// 等价于 C++ 的 p->Method(args)，显式传入 this 指针 p。
#define COMCALL(p, m, ...) ((p)->lpVtbl->m((p), __VA_ARGS__))

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")

#include <stdio.h>
#include <wchar.h>

// ============================================================
// DirectComposition 的 C 兼容声明
// ============================================================
// 重要：SDK 自带的 dcomp.h 在 C 下无法包含——它的接口用 C++ 的 ": public"
// 多重继承编写，C 模式下扁平化后会产生方法名重定义（实测编译器报
// "struct 成员重定义"）。因此这里手动声明我们用到的 3 个接口的最小 vtbl。
// 关键点：只要被调用的虚函数在本结构体 vtbl 中的偏移与真实接口一致即可——
// COM 对象持有的是它自己的完整 vtbl，我们只通过正确的偏移去取函数指针。
//   IDCompositionDevice : IUnknown(3) + Commit(3) WaitForCommitCompletion(4)
//                         GetFrameStatistics(5) CreateTargetForHwnd(6) CreateVisual(7)
//   IDCompositionTarget : IUnknown(3) + SetRoot(3)
//   IDCompositionVisual : IUnknown(3) + SetContent(3)  // 基础接口首个方法，偏移恒为 3
// 中间未用到的方法（如 GetFrameStatistics）只要占位以保偏移正确即可，签名可放宽。
typedef struct IDCompositionDevice  IDCompositionDevice;
typedef struct IDCompositionTarget  IDCompositionTarget;
typedef struct IDCompositionVisual  IDCompositionVisual;

typedef struct IDCompositionDeviceVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionDevice* This, const GUID* riid, void** ppv);
    ULONG  (STDMETHODCALLTYPE *AddRef)(IDCompositionDevice* This);
    ULONG  (STDMETHODCALLTYPE *Release)(IDCompositionDevice* This);
    HRESULT (STDMETHODCALLTYPE *Commit)(IDCompositionDevice* This);
    HRESULT (STDMETHODCALLTYPE *WaitForCommitCompletion)(IDCompositionDevice* This);
    HRESULT (STDMETHODCALLTYPE *GetFrameStatistics)(IDCompositionDevice* This, void* statistics);
    HRESULT (STDMETHODCALLTYPE *CreateTargetForHwnd)(IDCompositionDevice* This, HWND hwnd, BOOL topmost, IDCompositionTarget** target);
    HRESULT (STDMETHODCALLTYPE *CreateVisual)(IDCompositionDevice* This, IDCompositionVisual** visual);
} IDCompositionDeviceVtbl;
struct IDCompositionDevice { const IDCompositionDeviceVtbl* lpVtbl; };

typedef struct IDCompositionTargetVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionTarget* This, const GUID* riid, void** ppv);
    ULONG  (STDMETHODCALLTYPE *AddRef)(IDCompositionTarget* This);
    ULONG  (STDMETHODCALLTYPE *Release)(IDCompositionTarget* This);
    HRESULT (STDMETHODCALLTYPE *SetRoot)(IDCompositionTarget* This, IDCompositionVisual* visual);
} IDCompositionTargetVtbl;
struct IDCompositionTarget { const IDCompositionTargetVtbl* lpVtbl; };

typedef struct IDCompositionVisualVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionVisual* This, const GUID* riid, void** ppv);
    ULONG  (STDMETHODCALLTYPE *AddRef)(IDCompositionVisual* This);
    ULONG  (STDMETHODCALLTYPE *Release)(IDCompositionVisual* This);
    // dcomp.h 真实顺序：SetOffsetX/SetOffsetX(anim)/SetOffsetY/SetOffsetY(anim)/
    // SetTransform/SetTransform(anim)/SetTransformParent/SetEffect/
    // SetBitmapInterpolationMode/SetBorderMode/SetClip/SetClip(anim)/SetContent。
    // 只调用 SetContent，其余占位保证偏移正确（否则会跳到 SetOffsetX 而 AV）。
    void* SetOffsetX;
    void* SetOffsetXAnimation;
    void* SetOffsetY;
    void* SetOffsetYAnimation;
    void* SetTransform;
    void* SetTransformAnimation;
    void* SetTransformParent;
    void* SetEffect;
    void* SetBitmapInterpolationMode;
    void* SetBorderMode;
    void* SetClip;
    void* SetClipAnimation;
    HRESULT (STDMETHODCALLTYPE *SetContent)(IDCompositionVisual* This, IUnknown* content);
} IDCompositionVisualVtbl;
struct IDCompositionVisual { const IDCompositionVisualVtbl* lpVtbl; };

// IDCompositionDevice 的 IID（取自 SDK dcomp.h 的 DECLARE_INTERFACE_IID_）
DEFINE_GUID(IID_IDCompositionDevice,
            0xC37EA93A, 0xE7AA, 0x450D, 0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3);

// DirectComposition 设备工厂（dcomp.dll 导出，链接 dcomp.lib）
HRESULT WINAPI DCompositionCreateDevice(IDXGIDevice* dxgiDevice, REFIID riid, void** dcompDevice);

// C 没有接口继承，下面这些"从派生接口指针到基类 IUnknown*/ID3D11Resource*"
// 的传参会被编译器当成不兼容指针类型告警（C4133）。实际 ABI 兼容，统一抑制。
#pragma warning(disable: 4133)

// 空 GUID（C 下 SDK 不暴露 GUID_NULL 变量，用全 0 的局部常量代替）
static const GUID c_GUIDNull = {0};

// ===================== 状态 =====================
static ID3D11Device*              g_dev = NULL;
static ID3D11DeviceContext*       g_ctx = NULL;
static IDXGISwapChain1*           g_swap = NULL;     // Composition 交换链（FLIP 模型）
static IDCompositionDevice*       g_dcomp = NULL;
static IDCompositionTarget*       g_target = NULL;
static IDCompositionVisual*       g_visual = NULL;
static ID3D11VideoDevice*         g_vd = NULL;
static ID3D11VideoContext*        g_vc = NULL;
static ID3D11VideoProcessorEnumerator* g_vpe = NULL;
static ID3D11VideoProcessor*      g_vp = NULL;
static ID3D11VideoProcessorInputView*  g_inView = NULL;
static ID3D11VideoProcessorOutputView* g_outView = NULL;
static IMFDXGIDeviceManager*      g_dxm = NULL;      // DXVA 解码共享
static IMFSourceReader*           g_reader = NULL;
static ID3D11Texture2D*           g_upTex = NULL;    // NV12 / RGB32 上传纹理
static int   g_upIsNv12 = 1;
static UINT  g_vw = 0, g_vh = 0;                    // 视频尺寸
static UINT  g_frameMs = 33;                        // 帧间隔
static UINT  g_scW = 0, g_scH = 0;                  // 交换链尺寸
static HWND  g_hwnd = NULL;
static int   g_active = 0;
static int   g_hwDecode = 0;                        // 是否 DXVA 硬解
static ULONGLONG g_startTick = 0;
static int   g_trimmed = 0;
static UINT  g_loopCount = 0;
static LONGLONG g_lastTs = 0;     // 最近一帧时间戳（100ns）
static LONGLONG g_duration = 0;   // 演示时长（100ns）
static int   g_loopRetry = 0;     // seek 后仍 EOS 的重试次数
static wchar_t g_pathW[MAX_PATH]; // 重建 reader 用
static LONGLONG g_startWall = 0;  // 本轮播放起始墙上时钟（ms）
static LONGLONG g_startTs = 0;    // 本轮播放起始视频时间戳（100ns）

static void DpLog(const wchar_t* msg, HRESULT hr) {
    wchar_t exe[MAX_PATH] = {0};
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    wchar_t* slash = wcsrchr(exe, L'\\');
    if (slash) *slash = L'\0';
    wchar_t logPath[MAX_PATH + 16];
    // 拼接 exe 目录 + "debug.log"。swnprintf 安全截断，避免溢出。
    int n = _snwprintf(logPath, MAX_PATH + 16, L"%s\\debug.log", exe);
    if (n < 0) logPath[MAX_PATH + 15] = L'\0';
    FILE* f = _wfopen(logPath, L"a");
    if (!f) return;
    SYSTEMTIME st = {0};
    GetLocalTime(&st);
    fwprintf(f, L"%04u-%02u-%02u %02u:%02u:%02u [d3d] %s hr=0x%08X\n",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
             msg ? msg : L"fail", (unsigned)hr);
    fclose(f);
}

// ===================== 解码器：优先 DXVA 硬解（配 D3D manager），失败逐级回退 =====================
static IMFSourceReader* CreateReader(const wchar_t* path, int useDxva) {
    IMFAttributes* attr = NULL;
    if (FAILED(MFCreateAttributes(&attr, 4))) return NULL;

    if (useDxva && g_dxm) {
        COMCALL(attr, SetUnknown, &MF_SOURCE_READER_D3D_MANAGER, (IUnknown*)g_dxm);
        COMCALL(attr, SetUINT32, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
        // 注意：不开 ADVANCED_VIDEO_PROCESSING —— 该模式在部分源上
        // 会引发"第一帧即 EOS / 时长解析为 0"的异常（实测复现）
    }

    // 用字节流方式打开（MFCreateSourceReaderFromURL 对含中文的路径解析
    // 异常：duration=0 / 首帧即 EOS / NO_MORE_TYPES，实测复现）
    IMFByteStream* stream = NULL;
    HRESULT hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                              MF_FILEFLAGS_NONE, path, &stream);
    if (FAILED(hr) || !stream) { COMCALL(attr, Release); return NULL; }

    IMFSourceReader* reader = NULL;
    hr = MFCreateSourceReaderFromByteStream(stream, attr, &reader);
    COMCALL(stream, Release);
    COMCALL(attr, Release);
    if (FAILED(hr) || !reader) { if (reader) COMCALL(reader, Release); return NULL; }

    COMCALL(reader, SetStreamSelection, (DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    COMCALL(reader, SetStreamSelection, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);

    // 输出类型协商：
    //   DXVA 模式 → 优先 RGB32：强制插入转换 MFT，由它把解码器的 GPU 纹理
    //     下载为系统内存（NV12 直通路径实测数据流断：首帧即 EOS）
    //   软解模式 → 优先 NV12（解码器原生输出，零转换）
    const GUID* first  = useDxva ? &MFVideoFormat_RGB32 : &MFVideoFormat_NV12;
    const GUID* second = useDxva ? &MFVideoFormat_NV12  : &MFVideoFormat_RGB32;
    IMFMediaType* mt = NULL;
    if (FAILED(MFCreateMediaType(&mt)) || !mt) { COMCALL(reader, Release); return NULL; }
    COMCALL(mt, SetGUID, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    COMCALL(mt, SetGUID, &MF_MT_SUBTYPE, first);
    hr = COMCALL(reader, SetCurrentMediaType, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, mt);
    COMCALL(mt, Release);
    mt = NULL;   // 置空：下面那次 MFCreateMediaType 失败时不会留下悬垂指针
    if (SUCCEEDED(hr)) return reader;

    if (FAILED(MFCreateMediaType(&mt)) || !mt) { COMCALL(reader, Release); return NULL; }
    COMCALL(mt, SetGUID, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    COMCALL(mt, SetGUID, &MF_MT_SUBTYPE, second);
    hr = COMCALL(reader, SetCurrentMediaType, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, mt);
    COMCALL(mt, Release);
    if (SUCCEEDED(hr)) return reader;

    COMCALL(reader, Release);
    return NULL;
}

// ===================== 交换链 / VideoProcessor =====================
static void ReleaseDrawChain(void) {
    if (g_inView)  { COMCALL(g_inView, Release);  g_inView = NULL; }
    if (g_outView) { COMCALL(g_outView, Release); g_outView = NULL; }
    if (g_vp)      { COMCALL(g_vp, Release);      g_vp = NULL; }
    if (g_vpe)     { COMCALL(g_vpe, Release);     g_vpe = NULL; }
    if (g_visual)  { COMCALL(g_visual, Release);  g_visual = NULL; }
    if (g_target)  { COMCALL(g_target, Release);  g_target = NULL; }
    if (g_dcomp)   { COMCALL(g_dcomp, Release);   g_dcomp = NULL; }
    if (g_swap)    { COMCALL(g_swap, Release);    g_swap = NULL; }
}

static int BuildDrawChain(void) {
    ReleaseDrawChain();
    if (!g_dev || !g_vd || !g_hwnd || !g_vw) return 0;

    RECT rc = {0};
    GetClientRect(g_hwnd, &rc);
    UINT w = rc.right > 0 ? (UINT)rc.right : (UINT)GetSystemMetrics(SM_CXSCREEN);
    UINT h = rc.bottom > 0 ? (UINT)rc.bottom : (UINT)GetSystemMetrics(SM_CYSCREEN);
    if (w == 0 || h == 0) return 0;
    // 注意：g_scW/g_scH 在函数**成功返回前**才赋值（见函数末尾）。
    // 若在此处提前提交尺寸，一旦后续 DComp/DXGI/VP 创建失败（return 0），
    // D3DPumpFrame 的"尺寸变了就重建"守卫会因为尺寸已更新而永不重试 → 永久停帧。

    // Composition 交换链（FLIP 模型）+ DComp visual。
    // 24H2+ 壁纸窗口是 Progman 的 LAYERED 子窗口：DXGI blt present 写的
    // 重定向表面对 layered 窗口不生效（实测黑屏）。DComp 直接向 DWM 提交纹理，
    // 不经过窗口重定向表面，是 layered 子窗口上唯一可靠的 D3D11 呈现路径。
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = w;
    sd.Height = h;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    IDXGIFactory2* factory2 = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory2, (void**)&factory2);
    if (SUCCEEDED(hr)) {
        hr = COMCALL(factory2, CreateSwapChainForComposition, g_dev, &sd, NULL, &g_swap);
        COMCALL(factory2, Release);
    }
    if (FAILED(hr) || !g_swap) { DpLog(L"comp swapchain failed", hr); return 0; }

    // DComp：设备 → 目标(绑壁纸窗口) → visual(内容=交换链) → 提交
    IDXGIDevice* dxgiDev = NULL;
    hr = COMCALL(g_dev, QueryInterface, &IID_IDXGIDevice, (void**)&dxgiDev);
    if (FAILED(hr)) { DpLog(L"dcomp: qi dxgidevice", hr); ReleaseDrawChain(); return 0; }
    hr = DCompositionCreateDevice(dxgiDev, &IID_IDCompositionDevice, (void**)&g_dcomp);
    COMCALL(dxgiDev, Release);
    if (FAILED(hr)) { DpLog(L"dcomp: create device", hr); ReleaseDrawChain(); return 0; }
    hr = COMCALL(g_dcomp, CreateTargetForHwnd, g_hwnd, TRUE, &g_target);
    if (FAILED(hr)) { DpLog(L"dcomp: create target", hr); ReleaseDrawChain(); return 0; }
    hr = COMCALL(g_dcomp, CreateVisual, &g_visual);
    if (FAILED(hr)) { DpLog(L"dcomp: create visual", hr); ReleaseDrawChain(); return 0; }
    hr = COMCALL(g_visual, SetContent, (IUnknown*)g_swap);   // Composition 交换链直接作为 visual 内容
    if (FAILED(hr)) { DpLog(L"dcomp: set content", hr); ReleaseDrawChain(); return 0; }
    hr = COMCALL(g_target, SetRoot, g_visual);
    if (SUCCEEDED(hr)) hr = COMCALL(g_dcomp, Commit);
    if (FAILED(hr)) { DpLog(L"dcomp: commit", hr); ReleaseDrawChain(); return 0; }
    DpLog(L"swapchain: dcomp-model", S_OK);

    // VideoProcessor：视频尺寸 → 屏幕尺寸（拉伸铺满 = 原方案的 ARMode_None）
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd = {0};
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = g_vw;
    cd.InputHeight = g_vh;
    cd.OutputWidth = w;
    cd.OutputHeight = h;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    hr = COMCALL(g_vd, CreateVideoProcessorEnumerator, &cd, &g_vpe);
    if (SUCCEEDED(hr)) hr = COMCALL(g_vd, CreateVideoProcessor, g_vpe, 0, &g_vp);
    if (FAILED(hr) || !g_vp) { DpLog(L"vp failed", hr); ReleaseDrawChain(); return 0; }

    // 输入视图：绑定上传纹理
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {0};
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ivd.Texture2D.MipSlice = 0;
    ivd.Texture2D.ArraySlice = 0;
    hr = COMCALL(g_vd, CreateVideoProcessorInputView, g_upTex, g_vpe, &ivd, &g_inView);

    // 输出视图：交换链后备缓冲
    ID3D11Texture2D* bb = NULL;
    if (SUCCEEDED(hr)) hr = COMCALL(g_swap, GetBuffer, 0, &IID_ID3D11Texture2D, (void**)&bb);
    if (SUCCEEDED(hr)) {
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {0};
        ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        hr = COMCALL(g_vd, CreateVideoProcessorOutputView, bb, g_vpe, &ovd, &g_outView);
        COMCALL(bb, Release);
    }
    if (FAILED(hr) || !g_inView || !g_outView) {
        DpLog(L"view failed", hr);
        ReleaseDrawChain();
        return 0;
    }

    // 源矩形铺满目标（全屏拉伸）+ 色彩空间（BT.709 视频 → 全量程 RGB）
    RECT src = { 0, 0, (LONG)g_vw, (LONG)g_vh };
    RECT dst = { 0, 0, (LONG)w, (LONG)h };
    COMCALL(g_vc, VideoProcessorSetStreamSourceRect, g_vp, 0, TRUE, &src);
    COMCALL(g_vc, VideoProcessorSetStreamDestRect, g_vp, 0, TRUE, &dst);
    COMCALL(g_vc, VideoProcessorSetStreamFrameFormat, g_vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE cs = {0};
    cs.Usage = 0;            // 播放
    cs.RGB_Range = 0;        // 0-255
    cs.YCbCr_Matrix = 1;     // BT.709
    cs.YCbCr_xvYCC = 0;
    cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    COMCALL(g_vc, VideoProcessorSetStreamColorSpace, g_vp, 0, &cs);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE ocs = {0};
    ocs.Usage = 0;
    ocs.RGB_Range = 0;       // 输出全量程
    COMCALL(g_vc, VideoProcessorSetOutputColorSpace, g_vp, &ocs);

    // 全部成功后才提交交换链尺寸：失败路径保持旧值（或 0），
    // 让 D3DPumpFrame 的尺寸守卫能在下个 tick 重试重建。
    g_scW = w;
    g_scH = h;
    return 1;
}

// ===================== 初始化 =====================
int D3DInit(HWND hwnd, const wchar_t* videoPath) {
    D3DShutdown();
    g_hwnd = hwnd;
    wcsncpy(g_pathW, videoPath, MAX_PATH - 1);
    g_pathW[MAX_PATH - 1] = L'\0';

    // 1. D3D11 设备（需要 VIDEO_SUPPORT 供 DXVA / VideoProcessor）
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags,
                                   NULL, 0, D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
    if (FAILED(hr) || !g_dev) {
        // 首个调用可能"失败但仍写出非空对象" → 重试前先释放，避免设备/上下文泄漏
        if (g_dev) { COMCALL(g_dev, Release); g_dev = NULL; }
        if (g_ctx) { COMCALL(g_ctx, Release); g_ctx = NULL; }
        flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;   // 老驱动退级重试
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags,
                               NULL, 0, D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
        if (FAILED(hr) || !g_dev) { DpLog(L"device failed", hr); D3DShutdown(); return 0; }
    }
    // 关键：MF 的 DXVA 解码器在工作线程使用本 device，必须开多线程保护，
    // 否则并发访问 device 导致数据流断（实测：首帧即 EOS）
    {
        ID3D10Multithread* mt = NULL;
        if (SUCCEEDED(COMCALL(g_dev, QueryInterface, &IID_ID3D10Multithread, (void**)&mt)) && mt) {
            COMCALL(mt, SetMultithreadProtected, TRUE);
            COMCALL(mt, Release);
        }
    }
    if (FAILED(COMCALL(g_dev, QueryInterface, &IID_ID3D11VideoDevice, (void**)&g_vd)) ||
        FAILED(COMCALL(g_ctx, QueryInterface, &IID_ID3D11VideoContext, (void**)&g_vc))) {
        DpLog(L"video ifaces failed", E_NOINTERFACE);
        D3DShutdown();
        return 0;
    }

    // 2. DXVA 共享管理器（解码器 GPU 硬解）
    UINT resetToken = 0;
    if (SUCCEEDED(MFCreateDXGIDeviceManager(&resetToken, &g_dxm))) {
        if (FAILED(COMCALL(g_dxm, ResetDevice, g_dev, resetToken))) {
            COMCALL(g_dxm, Release); g_dxm = NULL;
        }
    }

    // 3. 解码器：优先 DXVA 硬解，失败退软解
    g_reader = CreateReader(videoPath, 1);
    g_hwDecode = (g_reader != NULL);
    if (!g_reader) {
        g_reader = CreateReader(videoPath, 0);
        if (!g_reader) { DpLog(L"reader failed", E_FAIL); D3DShutdown(); return 0; }
    }

    // 4. 读输出格式信息：尺寸/帧率/子类型/时长
    IMFMediaType* cur = NULL;
    hr = COMCALL(g_reader, GetCurrentMediaType, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur);
    if (FAILED(hr) || !cur) { DpLog(L"cur type failed", hr); D3DShutdown(); return 0; }
    UINT32 num = 0, den = 1;
    // MFGetAttributeSize/Ratio 不在 mfplat/mfreadwrite 导入库中（实测链接失败），
    // 改用 IMFAttributes::GetUINT64 手动拆包：高 32 位 / 低 32 位。
    {
        UINT64 packed = 0;
        if (SUCCEEDED(COMCALL(cur, GetUINT64, &MF_MT_FRAME_SIZE, &packed))) {
            g_vw = (UINT)(packed >> 32);
            g_vh = (UINT)(packed & 0xFFFFFFFFu);
        }
        packed = 0;
        if (SUCCEEDED(COMCALL(cur, GetUINT64, &MF_MT_FRAME_RATE, &packed))) {
            num = (UINT32)(packed >> 32);
            den = (UINT32)(packed & 0xFFFFFFFFu);
        }
    }
    GUID sub = c_GUIDNull;
    COMCALL(cur, GetGUID, &MF_MT_SUBTYPE, &sub);
    COMCALL(cur, Release);
    PROPVARIANT dur;
    PropVariantInit(&dur);
    if (SUCCEEDED(COMCALL(g_reader, GetPresentationAttribute,
                          (DWORD)MF_SOURCE_READER_MEDIASOURCE, &MF_PD_DURATION, &dur)) &&
        dur.vt == VT_I8) {
        g_duration = dur.hVal.QuadPart;
    }
    PropVariantClear(&dur);
    if (g_vw == 0 || g_vh == 0) { DpLog(L"size failed", E_FAIL); D3DShutdown(); return 0; }
    g_upIsNv12 = (IsEqualGUID(&sub, &MFVideoFormat_NV12) != 0);
    if (num > 0 && den > 0) {
        UINT ms = (UINT)((ULONGLONG)1000 * den / num);
        if (ms < 10) ms = 10;
        if (ms > 100) ms = 100;
        g_frameMs = ms;
    }

    // 5. 上传纹理（NV12 或 RGB32）
    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = g_vw;
    td.Height = g_vh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = g_upIsNv12 ? DXGI_FORMAT_NV12 : DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = 0;
    td.CPUAccessFlags = 0;
    hr = COMCALL(g_dev, CreateTexture2D, &td, NULL, &g_upTex);
    if (FAILED(hr) || !g_upTex) { DpLog(L"upload tex failed", hr); D3DShutdown(); return 0; }

    // 6. 交换链 + VideoProcessor
    if (!BuildDrawChain()) { D3DShutdown(); return 0; }

    wchar_t info[128] = {0};
    _snwprintf(info, 128, L"init ok %ux%u %ums %s %s", g_vw, g_vh, g_frameMs,
               g_upIsNv12 ? L"NV12" : L"RGB32", g_hwDecode ? L"DXVA" : L"soft");
    DpLog(info, S_OK);

    g_active = 1;
    g_startTick = GetTickCount64();
    return 1;
}

// ===================== VP 合成一帧到后备缓冲；present 时同步上屏 =====================
static int BltVp(ID3D11VideoProcessorInputView* view) {
    D3D11_VIDEO_PROCESSOR_STREAM vs = {0};
    vs.Enable = TRUE;
    vs.pInputSurface = view;
    HRESULT hr = COMCALL(g_vc, VideoProcessorBlt, g_vp, g_outView, 0, 1, &vs);
    if (FAILED(hr)) {
        // 限频：本函数每帧都被调用，而 DpLog 每次 fopen/fclose。
        // 持续失败（设备移除/驱动重置）时若不限频会每帧写盘 → 日志无界增长
        // 且 UI 线程持续做文件 I/O。
        static UINT n = 0;
        if (n == 0 || (n % 500) == 0) DpLog(L"vpblt failed", hr);
        n++;
        return 0;
    }
    return 1;
}

static int PresentNow(void) {
    HRESULT hr = COMCALL(g_swap, Present, 1, 0);   // 垂直同步：帧率精确、无撕裂
    static int logged = 0;
    if (!logged) { DpLog(L"first present", hr); logged = 1; }
    if (FAILED(hr)) {
        static UINT n = 0;               // 限频理由同上：每帧调用，不能每帧写日志
        if (n == 0 || (n % 500) == 0) DpLog(L"present failed", hr);
        n++;
    }
    return SUCCEEDED(hr);
}

static int DrawSample(IMFSample* sample, int present) {
    if (!sample || !g_outView) return 0;

    IMFMediaBuffer* buf = NULL;
    HRESULT hr = COMCALL(sample, ConvertToContiguousBuffer, &buf);
    if (FAILED(hr) || !buf) return 0;

    // ---- 路径 1：DXVA 零拷贝（buffer 直接封装 GPU 纹理）----
    IMFDXGIBuffer* dxb = NULL;
    if (SUCCEEDED(COMCALL(buf, QueryInterface, &IID_IMFDXGIBuffer, (void**)&dxb)) && dxb) {
        ID3D11Texture2D* tex = NULL;
        UINT sub = 0;
        if (SUCCEEDED(COMCALL(dxb, GetResource, &IID_ID3D11Texture2D, (void**)&tex)) && tex &&
            SUCCEEDED(COMCALL(dxb, GetSubresourceIndex, &sub))) {
            D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {0};
            ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
            ivd.Texture2D.MipSlice = 0;
            ivd.Texture2D.ArraySlice = sub;
            // 解码器输出纹理必须显式声明 FourCC，否则视图采样全黑（实测复现）
            ivd.FourCC = g_upIsNv12 ? MAKEFOURCC('N','V','1','2') : 0;
            ID3D11VideoProcessorInputView* view = NULL;
            if (SUCCEEDED(COMCALL(g_vd, CreateVideoProcessorInputView, tex, g_vpe, &ivd, &view)) && view) {
                int ok = BltVp(view);
                static int logged = 0;
                if (!logged) { DpLog(L"frame: zerocopy path", S_OK); logged = 1; }
                COMCALL(view, Release);
                COMCALL(tex, Release);
                COMCALL(dxb, Release);
                COMCALL(buf, Release);
                if (ok && present) return PresentNow();
                return ok;
            }
            if (tex) COMCALL(tex, Release);
        }
        COMCALL(dxb, Release);
        // 纹理路径失败 → 继续走系统内存上传路径
    }

    // ---- 路径 2：系统内存上传（软解 / 零拷贝不可用时）----
    if (!g_upTex || !g_inView) { COMCALL(buf, Release); return 0; }
    IMF2DBuffer* b2d = NULL;
    BYTE* p = NULL;
    LONG pitch = 0;
    int locked2d = SUCCEEDED(COMCALL(buf, QueryInterface, &IID_IMF2DBuffer, (void**)&b2d)) && b2d &&
                   SUCCEEDED(COMCALL(b2d, Lock2D, &p, &pitch));
    if (locked2d && pitch < 0) {   // 负 stride = bottom-up，翻行序
        p += (size_t)(-pitch) * (g_vh - 1);
        pitch = -pitch;
    }
    if (!locked2d) {
        // 退路：普通 Lock + 用宽度推 stride（MF 连续 buffer 对齐 4 字节）
        DWORD len = 0;
        if (FAILED(COMCALL(buf, Lock, &p, NULL, &len)) || !p) { COMCALL(buf, Release); return 0; }
        pitch = g_upIsNv12 ? (LONG)g_vw : (LONG)g_vw * 4;
    }

    if (g_upIsNv12) {
        // Y 平面 → subresource 0；UV 平面 → subresource 1
        COMCALL(g_ctx, UpdateSubresource, g_upTex, 0, NULL, p, pitch, 0);
        COMCALL(g_ctx, UpdateSubresource, g_upTex, 1, NULL, p + (size_t)pitch * g_vh, pitch, 0);
    } else {
        COMCALL(g_ctx, UpdateSubresource, g_upTex, 0, NULL, p, pitch, 0);
    }

    if (locked2d) COMCALL(b2d, Unlock2D);
    else COMCALL(buf, Unlock);
    if (b2d) COMCALL(b2d, Release);
    COMCALL(buf, Release);

    // GPU 转换 NV12→RGB 并缩放到屏幕
    if (!BltVp(g_inView)) return 0;
    if (present) return PresentNow();
    return 1;
}

// ===================== 泵帧：按墙上时钟追帧 + 无缝循环 =====================
// 标准播放器做法：高频 tick，按"应播到的时间点"解码呈现对应帧，
// 呈现节奏对齐显示器刷新（vsync），WM_TIMER 的低精度被追帧逻辑吸收。
UINT D3DPumpFrame(void) {
    if (!g_active || !g_reader) return 33;

    // 延迟 trim（播放稳定后归还备用页，任务管理器占用下降）
    if (!g_trimmed && g_startTick && GetTickCount64() - g_startTick > 15000) {
        g_trimmed = 1;
        SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
    }

    // 窗口尺寸变了（重嵌入/分辨率切换）→ 重建交换链自适应
    if (g_hwnd && IsWindow(g_hwnd)) {
        RECT rc = {0};
        GetClientRect(g_hwnd, &rc);
        if (rc.right > 0 && rc.bottom > 0 &&
            ((UINT)rc.right != g_scW || (UINT)rc.bottom != g_scH)) {
            BuildDrawChain();
        }
    }

    LONGLONG now = (LONGLONG)GetTickCount64();
    if (!g_startWall) { g_startWall = now; g_lastTs = -1; }
    // 目标时间点（100ns）：视频时间轴上"现在应该播到的位置"
    LONGLONG target = g_startTs + (now - g_startWall) * 10000;

    int drawn = 0;
    while (g_lastTs < target && drawn < 4 && g_reader) {
        DWORD flags = 0;
        LONGLONG ts = 0;
        IMFSample* s = NULL;
        HRESULT hr = COMCALL(g_reader, ReadSample, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                             NULL, &flags, &ts, &s);
        if (FAILED(hr)) { DpLog(L"readsample failed", hr); g_active = 0; return 16; }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            if (s) { COMCALL(s, Release); s = NULL; }
            // ★ 无缝循环：seek 回开头，渲染管线不中断、交换链保留画面。
            // 分级回退：seek(0) → seek(1) 强制真 seek（部分源对 0 优化跳过）→ 重建 reader
            LONGLONG pos = (g_loopRetry == 0) ? 0 : 1;
            PROPVARIANT pv;
            PropVariantInit(&pv);
            pv.vt = VT_I8;
            pv.hVal.QuadPart = pos;
            hr = COMCALL(g_reader, SetCurrentPosition, &c_GUIDNull, &pv);
            PropVariantClear(&pv);
            int loopProbs = FAILED(hr) || g_loopRetry >= 2;
            if (loopProbs) {
                IMFSourceReader* nr = CreateReader(g_pathW, 1);
                if (!nr) nr = CreateReader(g_pathW, 0);
                if (nr) {
                    if (g_reader) COMCALL(g_reader, Release);
                    g_reader = nr;
                    DpLog(L"loop: reader rebuilt", S_OK);
                } else {
                    DpLog(L"loop rebuild failed", E_FAIL);
                    g_active = 0;
                    return 500;
                }
            } else {
                g_loopRetry++;
            }
            g_loopCount++;
            // 循环日志限频：旧版每次循环都写一行（10 秒素材 = 8640 行/天），
            // 曾占 debug.log 全部内容的 99.5%。现在只在异常路径（seek 失败 /
            // 需重建 reader）、首轮、或每 500 轮记一次（10 秒素材约 1.4 小时一行）。
            // 注意不要用 g_loopRetry 判定：它在下面那步就 +1 了，健康路径恒为 1。
            if (loopProbs || g_loopCount == 1 || (g_loopCount % 500) == 0) {
                wchar_t m[112] = {0};
                _snwprintf(m, 112, L"eos ts=%.2f loop=%u%s",
                           g_lastTs / 10000000.0, g_loopCount,
                           loopProbs ? L" (seek/reader problems)" : L"");
                DpLog(m, S_OK);
            }
            // 重置播放时钟：从新的一轮第 0ms 起算
            g_startWall = now;
            g_startTs = 0;
            g_lastTs = -1;
            target = 0;
            // ★ 必须 break，不能 continue：target 已置 0、g_lastTs=-1 会让
            // while 条件 (-1 < 0) 恒真，且 drawn 在 EOS 路径不自增 → 源在 seek
            // 后仍持续返回 EOS 时退化为无界自旋（每轮重建 reader + 写日志），
            // 消息循环被独占，看门狗与 wallpaper.quit 握手全部失效。
            // break 后本 tick 直接呈现保留帧，下个 tick 从新一轮正常读帧。
            break;   // seek 生效于下个 tick（画面保留不闪）
        }
        if (!s) break;   // STREAMTICK 空帧：等下个 tick
        int ok = DrawSample(s, 0);   // 只合成到后备缓冲
        if (ok) { g_lastTs = ts; g_loopRetry = 0; drawn++; }
        COMCALL(s, Release);
        if (!ok) break;
    }

    // 本 tick 无论是否更新内容都 vsync 呈现（重复帧无开销，节奏对齐刷新率）
    if (g_swap) PresentNow();
    return 8;   // 高频 tick：追帧逻辑吸收定时器误差
}

// ===================== 重绑窗口（看门狗重建/重嵌入后） =====================
void D3DSetWindow(HWND hwnd) {
    if (!hwnd || hwnd == g_hwnd) return;
    g_hwnd = hwnd;
    if (g_dev) BuildDrawChain();   // 换窗口 = 交换链必须重建
}

// ===================== 关闭 =====================
void D3DShutdown(void) {
    g_active = 0;
    g_trimmed = 0;
    g_startTick = 0;
    g_loopCount = 0;
    g_lastTs = 0;
    g_startWall = 0;
    g_startTs = 0;
    g_loopRetry = 0;
    ReleaseDrawChain();
    if (g_upTex)   { COMCALL(g_upTex, Release);   g_upTex = NULL; }
    if (g_reader)  { COMCALL(g_reader, Release);  g_reader = NULL; }
    if (g_dxm)     { COMCALL(g_dxm, Release);     g_dxm = NULL; }
    if (g_vc)      { COMCALL(g_vc, Release);      g_vc = NULL; }
    if (g_vd)      { COMCALL(g_vd, Release);      g_vd = NULL; }
    if (g_ctx)     { COMCALL(g_ctx, Release);     g_ctx = NULL; }
    if (g_dev)     { COMCALL(g_dev, Release);     g_dev = NULL; }
    g_hwnd = NULL;
    g_scW = g_scH = 0;
    g_vw = g_vh = 0;
    g_hwDecode = 0;
}

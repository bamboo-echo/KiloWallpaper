// d3dplayer.cpp - SourceReader(DXVA 硬解) + D3D11 VideoProcessor 视频壁纸播放器
//
// 闪屏根治原理：
//   EVR 方案的循环必须"会话结束→重启"，重启瞬间渲染器清屏→透出系统壁纸（闪）。
//   本方案循环 = ReadSample 到 EOS 后 SetCurrentPosition(0) 回开头继续解码，
//   D3D 交换链全程保留上一帧直到新帧 Present —— 渲染管线从不中断，物理上无闪屏。
//   （mpv / Wallpaper Engine 的无缝循环同一原理，此处用纯系统 API 自己实现。）
//
// 渲染管线：DXVA 硬解 NV12 → UpdateSubresource 上传 → VideoProcessor GPU
//   NV12→RGB 转换 + 缩放到屏幕 → swapchain Present(垂直同步)。
//   CPU 每帧只做一次内存拷贝（~3MB），占用极低。
// SDK 版本宏先行：MF_READWRITE_D3D_MANAGER 等属性 GUID 受版本宏保护
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <initguid.h>   // 在 MF 头之前，实例化 MF 属性 GUID
#include "d3dplayer.h"

#include <string>

#include <d3d11.h>
#include <d3d10.h>   // ID3D10Multithread：MF 解码工作线程共用 device 必须开多线程保护
#include <dxgi1_2.h>
#include <dcomp.h>   // DirectComposition：跨进程子窗口上 D3D11 内容的唯一可靠呈现方式
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")

#include <cstdio>

// ---------- 状态 ----------
static ID3D11Device* g_dev = nullptr;
static ID3D11DeviceContext* g_ctx = nullptr;
static IDXGISwapChain1* g_swap = nullptr;       // Composition 交换链（FLIP 模型）
static IDCompositionDevice* g_dcomp = nullptr;
static IDCompositionTarget* g_target = nullptr;
static IDCompositionVisual* g_visual = nullptr;
static ID3D11VideoDevice* g_vd = nullptr;
static ID3D11VideoContext* g_vc = nullptr;
static ID3D11VideoProcessorEnumerator* g_vpe = nullptr;
static ID3D11VideoProcessor* g_vp = nullptr;
static ID3D11VideoProcessorInputView* g_inView = nullptr;
static ID3D11VideoProcessorOutputView* g_outView = nullptr;
static IMFDXGIDeviceManager* g_dxm = nullptr;   // DXVA 解码共享
static IMFSourceReader* g_reader = nullptr;
static ID3D11Texture2D* g_upTex = nullptr;      // NV12 / RGB32 上传纹理
static bool g_upIsNv12 = true;
static UINT g_vw = 0, g_vh = 0;                 // 视频尺寸
static UINT g_frameMs = 33;                     // 帧间隔
static UINT g_scW = 0, g_scH = 0;               // 交换链尺寸
static HWND g_hwnd = nullptr;
static bool g_active = false;
static bool g_hwDecode = false;                 // 是否 DXVA 硬解
static ULONGLONG g_startTick = 0;
static bool g_trimmed = false;
static UINT g_loopCount = 0;
static LONGLONG g_lastTs = 0;     // 最近一帧时间戳（100ns）
static LONGLONG g_duration = 0;   // 演示时长（100ns）
static int g_loopRetry = 0;       // seek 后仍 EOS 的重试次数
static std::wstring g_pathW;      // 重建 reader 用
static LONGLONG g_startWall = 0;  // 本轮播放起始墙上时钟（ms）
static LONGLONG g_startTs = 0;    // 本轮播放起始视频时间戳（100ns）

static void DpLog(const wchar_t* msg, HRESULT hr) {
    wchar_t exe[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring dir = exe;
    size_t pos = dir.find_last_of(L'\\');
    if (pos != std::wstring::npos) dir = dir.substr(0, pos + 1);
    FILE* f = nullptr;
    if (_wfopen_s(&f, (dir + L"debug.log").c_str(), L"a") != 0 || !f) return;
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    fwprintf(f, L"%04u-%02u-%02u %02u:%02u:%02u [d3d] %s hr=0x%08X\n",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
             msg, (unsigned)hr);
    fclose(f);
}

// ---------- 解码器：优先 DXVA 硬解（配 D3D manager），失败逐级回退 ----------
static IMFSourceReader* CreateReader(const wchar_t* path, bool useDxva, bool preferNv12) {
    IMFAttributes* attr = nullptr;
    if (FAILED(MFCreateAttributes(&attr, 4))) return nullptr;

    if (useDxva && g_dxm) {
        attr->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, g_dxm);
        attr->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
        // 注意：不开 ADVANCED_VIDEO_PROCESSING —— 该模式在部分源上
        // 会引发"第一帧即 EOS / 时长解析为 0"的异常（实测复现）
    }

    // 用字节流方式打开（MFCreateSourceReaderFromURL 对含中文的路径解析
    // 异常：duration=0 / 首帧即 EOS / NO_MORE_TYPES，实测复现）
    IMFByteStream* stream = nullptr;
    HRESULT hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                              MF_FILEFLAGS_NONE, path, &stream);
    if (FAILED(hr) || !stream) { attr->Release(); return nullptr; }

    IMFSourceReader* reader = nullptr;
    hr = MFCreateSourceReaderFromByteStream(stream, attr, &reader);
    stream->Release();
    attr->Release();
    if (FAILED(hr) || !reader) { if (reader) reader->Release(); return nullptr; }

    reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);

    // 输出类型协商：优先 NV12 —— 每帧 CPU 上传拷贝 5.5MB，只有 RGB32 的约 2/5。
    // 注意 DXVA 模式曾默认优先 RGB32，因为部分源在 NV12 输出上首帧即 EOS；
    // 但"协商成功"不等于"能出数据"，所以调用方（OpenVerifiedReader）会真读
    // 一帧验证，出不了就整体回退 RGB32 —— 只为降 CPU，不牺牲功能。
    const GUID& first = preferNv12 ? MFVideoFormat_NV12 : MFVideoFormat_RGB32;
    const GUID& second = preferNv12 ? MFVideoFormat_RGB32 : MFVideoFormat_NV12;
    IMFMediaType* mt = nullptr;
    if (FAILED(MFCreateMediaType(&mt)) || !mt) { reader->Release(); return nullptr; }
    mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    mt->SetGUID(MF_MT_SUBTYPE, first);
    hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, mt);
    mt->Release();
    mt = nullptr;   // 置空：下面那次 MFCreateMediaType 失败时不会留下悬垂指针
    if (SUCCEEDED(hr)) return reader;

    if (FAILED(MFCreateMediaType(&mt)) || !mt) { reader->Release(); return nullptr; }
    mt->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    mt->SetGUID(MF_MT_SUBTYPE, second);
    hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, mt);
    mt->Release();
    if (SUCCEEDED(hr)) return reader;

    reader->Release();
    return nullptr;
}

// 真读到一帧才算"这个输出格式可用"。部分源在 NV12 输出上协商成功但首帧即 EOS，
// 只看 SetCurrentMediaType 的返回值判断会误以为可用，结果视频链路空转。
static bool ProbeFirstSample(IMFSourceReader* reader) {
    if (!reader) return false;
    // 最多读 3 次：MF 首帧可能先给一个 STREAMTICK 空帧再给真正的样本。
    for (int i = 0; i < 3; i++) {
        DWORD flags = 0;
        LONGLONG ts = 0;
        IMFSample* s = nullptr;
        HRESULT hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                                        nullptr, &flags, &ts, &s);
        bool eos = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
        bool got = SUCCEEDED(hr) && s && !eos;
        if (s) s->Release();
        if (got) {
            // 回到片头。不支持 seek 的源也无妨：探测读到的那一帧被丢弃，
            // 播放从第二帧继续，之后的 EOS 循环仍会走正常的 seek 逻辑。
            PROPVARIANT pv;
            PropVariantInit(&pv);
            pv.vt = VT_I8;
            pv.hVal.QuadPart = 0;
            reader->SetCurrentPosition(GUID_NULL, pv);
            PropVariantClear(&pv);
            return true;
        }
        if (FAILED(hr) || eos) return false;
    }
    return false;
}

// 按"优先格式 → 另一种格式"依次尝试，每个都先探测一帧。全都不可用才返回 nullptr。
static IMFSourceReader* OpenVerifiedReader(const wchar_t* path, bool useDxva, bool preferNv12) {
    IMFSourceReader* r = CreateReader(path, useDxva, preferNv12);
    if (r && ProbeFirstSample(r)) return r;
    if (r) { r->Release(); r = nullptr; }
    r = CreateReader(path, useDxva, !preferNv12);
    if (r && ProbeFirstSample(r)) return r;
    if (r) { r->Release(); r = nullptr; }
    return nullptr;
}

// ---------- 交换链 / VideoProcessor ----------
static void ReleaseDrawChain() {
    if (g_inView) { g_inView->Release(); g_inView = nullptr; }
    if (g_outView) { g_outView->Release(); g_outView = nullptr; }
    if (g_vp) { g_vp->Release(); g_vp = nullptr; }
    if (g_vpe) { g_vpe->Release(); g_vpe = nullptr; }
    if (g_visual) { g_visual->Release(); g_visual = nullptr; }
    if (g_target) { g_target->Release(); g_target = nullptr; }
    if (g_dcomp) { g_dcomp->Release(); g_dcomp = nullptr; }
    if (g_swap) { g_swap->Release(); g_swap = nullptr; }
}

static bool BuildDrawChain() {
    ReleaseDrawChain();
    if (!g_dev || !g_vd || !g_hwnd || !g_vw) return false;

    RECT rc = {};
    GetClientRect(g_hwnd, &rc);
    UINT w = rc.right > 0 ? rc.right : GetSystemMetrics(SM_CXSCREEN);
    UINT h = rc.bottom > 0 ? rc.bottom : GetSystemMetrics(SM_CYSCREEN);
    if (w == 0 || h == 0) return false;
    // 注意：g_scW/g_scH 在函数**成功返回前**才赋值（见函数末尾）。
    // 若在此处提前提交尺寸，一旦后续 DComp/DXGI/VP 创建失败（return false），
    // D3DPumpFrame 的"尺寸变了就重建"守卫会因为尺寸已更新而永不重试 → 永久停帧。

    // Composition 交换链（FLIP 模型）+ DComp visual。
    // 24H2+ 壁纸窗口是 Progman 的 LAYERED 子窗口：DXGI blt present 写的
    // 重定向表面对 layered 窗口不生效（实测黑屏，Lumin 用 OpenGL/GDI 才
    // 可见也印证此点）。DComp 直接向 DWM 提交纹理，不经过窗口重定向表面，
    // 是 layered 子窗口上唯一可靠的 D3D11 呈现路径。
    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = w;
    sd.Height = h;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    IDXGIFactory2* factory2 = nullptr;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory2));
    if (SUCCEEDED(hr)) {
        hr = factory2->CreateSwapChainForComposition(g_dev, &sd, nullptr, &g_swap);
        factory2->Release();
    }
    if (FAILED(hr) || !g_swap) { DpLog(L"comp swapchain failed", hr); return false; }

    // DComp：设备 → 目标(绑壁纸窗口) → visual(内容=交换链) → 提交
    IDXGIDevice* dxgiDev = nullptr;
    hr = g_dev->QueryInterface(IID_PPV_ARGS(&dxgiDev));
    if (FAILED(hr)) { DpLog(L"dcomp: qi dxgidevice", hr); ReleaseDrawChain(); return false; }
    hr = DCompositionCreateDevice(dxgiDev, IID_PPV_ARGS(&g_dcomp));
    dxgiDev->Release();
    if (FAILED(hr)) { DpLog(L"dcomp: create device", hr); ReleaseDrawChain(); return false; }
    hr = g_dcomp->CreateTargetForHwnd(g_hwnd, TRUE, &g_target);
    if (FAILED(hr)) { DpLog(L"dcomp: create target", hr); ReleaseDrawChain(); return false; }
    hr = g_dcomp->CreateVisual(&g_visual);
    if (FAILED(hr)) { DpLog(L"dcomp: create visual", hr); ReleaseDrawChain(); return false; }
    hr = g_visual->SetContent(g_swap);   // Composition 交换链直接作为 visual 内容
    if (FAILED(hr)) { DpLog(L"dcomp: set content", hr); ReleaseDrawChain(); return false; }
    hr = g_target->SetRoot(g_visual);
    if (SUCCEEDED(hr)) hr = g_dcomp->Commit();
    if (FAILED(hr)) { DpLog(L"dcomp: commit", hr); ReleaseDrawChain(); return false; }
    DpLog(L"swapchain: dcomp-model", S_OK);

    // VideoProcessor：视频尺寸 → 屏幕尺寸（拉伸铺满 = 原方案的 ARMode_None）
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd = {};
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = g_vw;
    cd.InputHeight = g_vh;
    cd.OutputWidth = w;
    cd.OutputHeight = h;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    hr = g_vd->CreateVideoProcessorEnumerator(&cd, &g_vpe);
    if (SUCCEEDED(hr)) hr = g_vd->CreateVideoProcessor(g_vpe, 0, &g_vp);
    if (FAILED(hr) || !g_vp) { DpLog(L"vp failed", hr); ReleaseDrawChain(); return false; }

    // 输入视图：绑定上传纹理
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ivd.Texture2D.MipSlice = 0;
    ivd.Texture2D.ArraySlice = 0;
    hr = g_vd->CreateVideoProcessorInputView(g_upTex, g_vpe, &ivd, &g_inView);

    // 输出视图：交换链后备缓冲
    ID3D11Texture2D* bb = nullptr;
    if (SUCCEEDED(hr)) hr = g_swap->GetBuffer(0, IID_PPV_ARGS(&bb));
    if (SUCCEEDED(hr)) {
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {};
        ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        hr = g_vd->CreateVideoProcessorOutputView(bb, g_vpe, &ovd, &g_outView);
        bb->Release();
    }
    if (FAILED(hr) || !g_inView || !g_outView) {
        DpLog(L"view failed", hr);
        ReleaseDrawChain();
        return false;
    }

    // 源矩形铺满目标（全屏拉伸）+ 色彩空间（BT.709 视频 → 全量程 RGB）
    RECT src = { 0, 0, (LONG)g_vw, (LONG)g_vh };
    RECT dst = { 0, 0, (LONG)w, (LONG)h };
    g_vc->VideoProcessorSetStreamSourceRect(g_vp, 0, TRUE, &src);
    g_vc->VideoProcessorSetStreamDestRect(g_vp, 0, TRUE, &dst);
    g_vc->VideoProcessorSetStreamFrameFormat(g_vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE cs = {};
    cs.Usage = 0;            // 播放
    cs.RGB_Range = 0;        // 0-255
    cs.YCbCr_Matrix = 1;     // BT.709
    cs.YCbCr_xvYCC = 0;
    cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    g_vc->VideoProcessorSetStreamColorSpace(g_vp, 0, &cs);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE ocs = {};
    ocs.Usage = 0;
    ocs.RGB_Range = 0;       // 输出全量程
    g_vc->VideoProcessorSetOutputColorSpace(g_vp, &ocs);

    // 全部成功后才提交交换链尺寸：失败路径保持旧值（或 0），
    // 让 D3DPumpFrame 的尺寸守卫能在下个 tick 重试重建。
    g_scW = w;
    g_scH = h;
    return true;
}

// ---------- 初始化 ----------
bool D3DInit(HWND hwnd, const wchar_t* videoPath) {
    D3DShutdown();
    g_hwnd = hwnd;
    g_pathW = videoPath;

    // 1. D3D11 设备（需要 VIDEO_SUPPORT 供 DXVA / VideoProcessor）
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                   nullptr, 0, D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
    if (FAILED(hr) || !g_dev) {
        // 首个调用可能"失败但仍写出非空对象" → 重试前先释放，避免设备/上下文泄漏
        if (g_dev) { g_dev->Release(); g_dev = nullptr; }
        if (g_ctx) { g_ctx->Release(); g_ctx = nullptr; }
        flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;   // 老驱动退级重试
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                               nullptr, 0, D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
        if (FAILED(hr) || !g_dev) { DpLog(L"device failed", hr); D3DShutdown(); return false; }
    }
    // 关键：MF 的 DXVA 解码器在工作线程使用本 device，必须开多线程保护，
    // 否则并发访问 device 导致数据流断（实测：首帧即 EOS）
    {
        ID3D10Multithread* mt = nullptr;
        if (SUCCEEDED(g_dev->QueryInterface(IID_PPV_ARGS(&mt))) && mt) {
            mt->SetMultithreadProtected(TRUE);
            mt->Release();
        }
    }
    if (FAILED(g_dev->QueryInterface(IID_PPV_ARGS(&g_vd))) ||
        FAILED(g_ctx->QueryInterface(IID_PPV_ARGS(&g_vc)))) {
        DpLog(L"video ifaces failed", E_NOINTERFACE);
        D3DShutdown();
        return false;
    }

    // 2. DXVA 共享管理器（解码器 GPU 硬解）
    UINT resetToken = 0;
    if (SUCCEEDED(MFCreateDXGIDeviceManager(&resetToken, &g_dxm))) {
        if (FAILED(g_dxm->ResetDevice(g_dev, resetToken))) {
            g_dxm->Release(); g_dxm = nullptr;
        }
    }

    // 3. 解码器：优先 DXVA 硬解，失败退软解。每种模式都"NV12 优先 → RGB32 回退"，
    //    并且必须真读到一帧才算可用（OpenVerifiedReader 内部探测），避免 NV12
    //    协商成功但数据流断时整个视频链路空转 → 功能不受影响，只是格式择优。
    g_hwDecode = true;
    g_reader = OpenVerifiedReader(videoPath, true, true);
    if (!g_reader) {
        g_hwDecode = false;
        g_reader = OpenVerifiedReader(videoPath, false, true);
        if (!g_reader) { DpLog(L"reader failed", E_FAIL); D3DShutdown(); return false; }
    }

    // 4. 读输出格式信息：尺寸/帧率/子类型/时长
    IMFMediaType* cur = nullptr;
    hr = g_reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur);
    if (FAILED(hr) || !cur) { DpLog(L"cur type failed", hr); D3DShutdown(); return false; }
    UINT32 num = 0, den = 1;
    MFGetAttributeSize(cur, MF_MT_FRAME_SIZE, &g_vw, &g_vh);
    MFGetAttributeRatio(cur, MF_MT_FRAME_RATE, &num, &den);
    GUID sub = GUID_NULL;
    cur->GetGUID(MF_MT_SUBTYPE, &sub);
    cur->Release();
    PROPVARIANT dur;
    PropVariantInit(&dur);
    if (SUCCEEDED(g_reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE,
                                                     MF_PD_DURATION, &dur)) &&
        dur.vt == VT_I8) {
        g_duration = dur.hVal.QuadPart;
    }
    PropVariantClear(&dur);
    if (g_vw == 0 || g_vh == 0) { DpLog(L"size failed", E_FAIL); D3DShutdown(); return false; }
    g_upIsNv12 = (sub == MFVideoFormat_NV12);
    if (num > 0 && den > 0) {
        UINT ms = (UINT)((ULONGLONG)1000 * den / num);
        if (ms < 10) ms = 10;
        if (ms > 100) ms = 100;
        g_frameMs = ms;
    }

    // 5. 上传纹理（NV12 或 RGB32）
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = g_vw;
    td.Height = g_vh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = g_upIsNv12 ? DXGI_FORMAT_NV12 : DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = 0;
    td.CPUAccessFlags = 0;
    hr = g_dev->CreateTexture2D(&td, nullptr, &g_upTex);
    if (FAILED(hr) || !g_upTex) { DpLog(L"upload tex failed", hr); D3DShutdown(); return false; }

    // 6. 交换链 + VideoProcessor
    if (!BuildDrawChain()) { D3DShutdown(); return false; }

    wchar_t info[128] = {};
    swprintf_s(info, L"init ok %ux%u %ums %s %s", g_vw, g_vh, g_frameMs,
               g_upIsNv12 ? L"NV12" : L"RGB32", g_hwDecode ? L"DXVA" : L"soft");
    DpLog(info, S_OK);

    g_active = true;
    g_startTick = GetTickCount64();
    return true;
}

// ---------- VP 合成一帧到后备缓冲；present 时同步上屏 ----------
static bool BltVp(ID3D11VideoProcessorInputView* view) {
    D3D11_VIDEO_PROCESSOR_STREAM vs = {};
    vs.Enable = TRUE;
    vs.pInputSurface = view;
    HRESULT hr = g_vc->VideoProcessorBlt(g_vp, g_outView, 0, 1, &vs);
    if (FAILED(hr)) {
        // 限频：本函数每帧都被调用，而 DpLog 每次 fopen/fclose。
        // 持续失败（设备移除/驱动重置）时若不限频会每帧写盘 → 日志无界增长
        // 且 UI 线程持续做文件 I/O。
        static UINT n = 0;
        if (n == 0 || (n % 500) == 0) DpLog(L"vpblt failed", hr);
        n++;
        return false;
    }
    return true;
}

static bool PresentNow() {
    HRESULT hr = g_swap->Present(1, 0);   // 垂直同步：帧率精确、无撕裂
    static bool logged = false;
    if (!logged) { DpLog(L"first present", hr); logged = true; }
    if (FAILED(hr)) {
        static UINT n = 0;               // 限频理由同上：每帧调用，不能每帧写日志
        if (n == 0 || (n % 500) == 0) DpLog(L"present failed", hr);
        n++;
    }
    return SUCCEEDED(hr);
}

static bool DrawSample(IMFSample* sample, bool present) {
    if (!sample || !g_outView) return false;

    IMFMediaBuffer* buf = nullptr;
    HRESULT hr = sample->ConvertToContiguousBuffer(&buf);
    if (FAILED(hr) || !buf) return false;

    // ---- 路径 1：DXVA 零拷贝（buffer 直接封装 GPU 纹理）----
    IMFDXGIBuffer* dxb = nullptr;
    if (SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(&dxb))) && dxb) {
        ID3D11Texture2D* tex = nullptr;
        UINT sub = 0;
        if (SUCCEEDED(dxb->GetResource(IID_PPV_ARGS(&tex))) && tex &&
            SUCCEEDED(dxb->GetSubresourceIndex(&sub))) {
            D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
            ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
            ivd.Texture2D.MipSlice = 0;
            ivd.Texture2D.ArraySlice = sub;
            // 解码器输出纹理必须显式声明 FourCC，否则视图采样全黑（实测复现）
            ivd.FourCC = g_upIsNv12 ? MAKEFOURCC('N', 'V', '1', '2') : 0;
            ID3D11VideoProcessorInputView* view = nullptr;
            if (SUCCEEDED(g_vd->CreateVideoProcessorInputView(tex, g_vpe, &ivd, &view)) && view) {
                bool ok = BltVp(view);
                static bool logged = false;
                if (!logged) { DpLog(L"frame: zerocopy path", S_OK); logged = true; }
                view->Release();
                tex->Release();
                dxb->Release();
                buf->Release();
                if (ok && present) return PresentNow();
                return ok;
            }
            if (tex) tex->Release();
        }
        dxb->Release();
        // 纹理路径失败 → 继续走系统内存上传路径
    }

    // ---- 路径 2：系统内存上传（软解 / 零拷贝不可用时）----
    if (!g_upTex || !g_inView) { buf->Release(); return false; }
    IMF2DBuffer* b2d = nullptr;
    BYTE* p = nullptr;
    LONG pitch = 0;
    bool locked2d = SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(&b2d))) && b2d &&
                    SUCCEEDED(b2d->Lock2D(&p, &pitch));
    if (locked2d && pitch < 0) {   // 负 stride = bottom-up，翻行序
        p += (size_t)(-pitch) * (g_vh - 1);
        pitch = -pitch;
    }
    if (!locked2d) {
        // 退路：普通 Lock + 用宽度推 stride（MF 连续 buffer 对齐 4 字节）
        DWORD len = 0;
        if (FAILED(buf->Lock(&p, nullptr, &len)) || !p) { buf->Release(); return false; }
        pitch = g_upIsNv12 ? (LONG)g_vw : (LONG)g_vw * 4;
    }

    if (g_upIsNv12) {
        // Y 平面 → subresource 0；UV 平面 → subresource 1
        g_ctx->UpdateSubresource(g_upTex, 0, nullptr, p, pitch, 0);
        g_ctx->UpdateSubresource(g_upTex, 1, nullptr, p + (size_t)pitch * g_vh, pitch, 0);
    } else {
        g_ctx->UpdateSubresource(g_upTex, 0, nullptr, p, pitch, 0);
    }

    if (locked2d) b2d->Unlock2D();
    else buf->Unlock();
    if (b2d) b2d->Release();
    buf->Release();

    // GPU 转换 NV12→RGB 并缩放到屏幕
    if (!BltVp(g_inView)) return false;
    if (present) return PresentNow();
    return true;
}

// ---------- 泵帧：按墙上时钟追帧 + 无缝循环 ----------
// 标准播放器做法：高频 tick，按"应播到的时间点"解码呈现对应帧，
// 呈现节奏对齐显示器刷新（vsync），WM_TIMER 的低精度被追帧逻辑吸收。
UINT D3DPumpFrame() {
    if (!g_active || !g_reader) return 33;

    // 延迟 trim（播放稳定后归还备用页，任务管理器占用下降）。
    // 5 秒足以覆盖"出首帧 + 解码器面池分配"的高峰；更早归还的代价只是少量缺页。
    if (!g_trimmed && g_startTick && GetTickCount64() - g_startTick > 5000) {
        g_trimmed = true;
        SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
    }

    // 窗口尺寸变了（重嵌入/分辨率切换）→ 重建交换链自适应
    if (g_hwnd && IsWindow(g_hwnd)) {
        RECT rc = {};
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
        IMFSample* s = nullptr;
        HRESULT hr = g_reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                                          nullptr, &flags, &ts, &s);
        if (FAILED(hr)) { DpLog(L"readsample failed", hr); g_active = false; return 16; }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            if (s) { s->Release(); s = nullptr; }
            // ★ 无缝循环：seek 回开头，渲染管线不中断、交换链保留画面。
            // 分级回退：seek(0) → seek(1) 强制真 seek（部分源对 0 优化跳过）→ 重建 reader
            LONGLONG pos = (g_loopRetry == 0) ? 0 : 1;
            PROPVARIANT pv;
            PropVariantInit(&pv);
            pv.vt = VT_I8;
            pv.hVal.QuadPart = pos;
            hr = g_reader->SetCurrentPosition(GUID_NULL, pv);
            PropVariantClear(&pv);
            bool loopProbs = FAILED(hr) || g_loopRetry >= 2;
            if (loopProbs) {
                // 优先沿用当前上传纹理的像素格式重建：OpenVerifiedReader 会先试
                // g_upIsNv12 对应的格式，通常保持一致，避免 g_upTex 平面布局不匹配；
                // 只有原格式彻底不可用时才会回退到另一种，属既有边界。
                IMFSourceReader* nr = OpenVerifiedReader(g_pathW.c_str(), true, g_upIsNv12);
                if (!nr) nr = OpenVerifiedReader(g_pathW.c_str(), false, g_upIsNv12);
                if (nr) {
                    if (g_reader) g_reader->Release();
                    g_reader = nr;
                    DpLog(L"loop: reader rebuilt", S_OK);
                } else {
                    DpLog(L"loop rebuild failed", E_FAIL);
                    g_active = false;
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
                wchar_t m[112] = {};
                swprintf_s(m, L"eos ts=%.2fs loop=%u%s", g_lastTs / 10000000.0, g_loopCount,
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
        bool ok = DrawSample(s, false);   // 只合成到后备缓冲
        if (ok) { g_lastTs = ts; g_loopRetry = 0; drawn++; }
        s->Release();
        if (!ok) break;
    }

    // 只在真的解出新帧时呈现：交换链全程保留上一帧，重复 Present 不改变画面，
    // 只是驱动/合成器的无谓开销（WM_TIMER 下限约 15.6ms，24fps 下约四成 tick 无新帧）。
    if (drawn > 0 && g_swap) PresentNow();
    return 8;   // 高频 tick：追帧逻辑吸收定时器误差
}

// ---------- 重绑窗口（看门狗重建/重嵌入后） ----------
void D3DSetWindow(HWND hwnd) {
    // nullptr = 解绑（壁纸窗口已销毁，main.cpp 的 WM_DESTROY 调用）。
    // 只比较句柄值是不够的：DestroyWindow 后系统会立即复用同一 HWND 数值，
    // 新窗口若拿到旧值，单靠 hwnd == g_hwnd + IsWindow 无法区分新旧窗口，
    // 会跳过交换链重建 → 交换链绑在已销毁的窗口上 → 黑屏。
    if (!hwnd) { g_hwnd = nullptr; return; }
    if (hwnd == g_hwnd && IsWindow(g_hwnd)) return;
    g_hwnd = hwnd;
    if (g_dev) BuildDrawChain();   // 换窗口 = 交换链必须重建
}

// ---------- 关闭 ----------
void D3DShutdown() {
    g_active = false;
    g_trimmed = false;
    g_startTick = 0;
    g_loopCount = 0;
    g_lastTs = 0;
    g_startWall = 0;
    g_startTs = 0;
    g_loopRetry = 0;
    ReleaseDrawChain();
    if (g_upTex) { g_upTex->Release(); g_upTex = nullptr; }
    if (g_reader) { g_reader->Release(); g_reader = nullptr; }
    if (g_dxm) { g_dxm->Release(); g_dxm = nullptr; }
    if (g_vc) { g_vc->Release(); g_vc = nullptr; }
    if (g_vd) { g_vd->Release(); g_vd = nullptr; }
    if (g_ctx) { g_ctx->Release(); g_ctx = nullptr; }
    if (g_dev) { g_dev->Release(); g_dev = nullptr; }
    g_hwnd = nullptr;
    g_scW = g_scH = 0;
    g_vw = g_vh = 0;
    g_hwDecode = false;
}

// main.c - DynamicWallpaper (C 版) 入口 / 窗口 / 看门狗 / 渲染调度
// GIF: GDI+（media.c 解码 / render.c 绘制）
// 视频: D3D11 播放器（d3dplayer.c，DXVA 硬解 + 无缝循环）
// 嵌入 WorkerW（Win10/Win11 桌面层），图标显示在壁纸之上（desktop.c）
// 编译：build.bat（纯 C，cl /O2）
#include "wallpaper.h"
#include "d3dplayer.h"
#include <stdlib.h>   // _wtoi / malloc / free
#include <wchar.h>    // wcsrchr / wcscmp / wcsstr / wcsncpy / _wcsicmp / _wcsnicmp
#include <string.h>   // memmove / memcpy / wcslen

const UINT TIMER_FRAME = 1;
const UINT TIMER_WATCHDOG = 2;
const UINT WATCHDOG_MS = 3000;

HINSTANCE g_hInst = NULL;
HWND g_hwnd = NULL;
HWND g_host = NULL;
int  g_winW = 0, g_winH = 0;
UINT g_taskbarCreated = 0;
int  g_isVideo = 0;

static void GetExeDir(wchar_t* out) {
    wchar_t exe[MAX_PATH] = {0};
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    wchar_t* slash = wcsrchr(exe, L'\\');
    if (slash) *slash = L'\0';
    wcscpy(out, exe);
}

static void LogFail(const wchar_t* msg, const wchar_t* path, HRESULT hr) {
    wchar_t dir[MAX_PATH]; GetExeDir(dir);
    wchar_t logPath[MAX_PATH + 16];
    int n = _snwprintf(logPath, MAX_PATH + 16, L"%s\\debug.log", dir);
    if (n < 0) logPath[MAX_PATH + 15] = L'\0';
    FILE* f = _wfopen(logPath, L"a");
    if (!f) return;
    SYSTEMTIME st = {0};
    GetLocalTime(&st);
    fwprintf(f, L"%04u-%02u-%02u %02u:%02u:%02u %s path=%s hr=0x%08X\n",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
             msg ? msg : L"fail", path ? path : L"", (unsigned)hr);
    fclose(f);
}

static void AdvanceFrame(void) {
    if (!IsWindow(g_hwnd)) return;
    if (g_isVideo) {
        // D3D 播放器泵帧：解码→GPU 转换→呈现；循环在内部 seek 回 0 无缝完成。
        // 交换链全程保留画面，无任何空窗 → 不可能闪出系统壁纸。
        UINT next = D3DPumpFrame();
        if (next < 10) next = 10;
        SetTimer(g_host, TIMER_FRAME, next, NULL);
    } else if (g_frameCount > 0) {
        if (g_frameCount == 1) {
            // 静态图：画一次就停掉帧定时器。
            // 旧实现按 100ms 默认延时无限重绘整屏 HighQualityBicubic —— 用一张
            // 静态图作壁纸也常年 ~10fps 全屏重绘，与"极小占用"的定位不符。
            InvalidateRect(g_hwnd, NULL, FALSE);
            return;
        }
        g_curFrame = (g_curFrame + 1) % g_frameCount;
        UINT delay = g_delays[g_curFrame];
        if (delay < 10) delay = 10;
        SetTimer(g_host, TIMER_FRAME, delay, NULL);
        InvalidateRect(g_hwnd, NULL, FALSE);
    }
}

static HWND CreateWallpaperWindow(void);

// ★ 优雅关闭标志：桌面「关闭壁纸.bat」改为写本文件（而非 taskkill /f）。
// 看门狗检测到 → 正常退出（退出码 0 不触发重启管理器恢复）→ 壁纸关闭。
// 用 taskkill /f 强杀则会被重启管理器拉起 → 壁纸只可能被"关闭"不可能被"杀"。
static int ConsumeQuitSignal(void) {
    wchar_t dir[MAX_PATH]; GetExeDir(dir);
    wchar_t p[MAX_PATH + 16];
    _snwprintf(p, MAX_PATH + 16, L"%s\\wallpaper.quit", dir);
    HANDLE f = CreateFileW(p, GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    CloseHandle(f);
    DeleteFileW(p);
    return 1;
}

// ---- 守护互保：主进程被外部强杀后，由同名目录下的 DynamicWallpaperGuard.exe
// ----（独立进程名）在 1 秒内自动拉起。守护进程名不同，优化软件按名批量
// ---- 清理时只会命中本进程，守护存活即可复活。
// 配套文件（exe 目录）：
//   wallpaper.main.pid / wallpaper.guard.pid  记录对方进程号（进程存活探测）
//   wallpaper.ok         主进程初始化成功后的标记（守护据此判断是否该保活）
//   wallpaper.graceful   优雅关闭标记（守护见之即退出，不再复活）
// "关闭壁纸.bat" 写 wallpaper.quit → 主进程写 graceful 再退出 → 守护随之退出。

static void WritePidFile(const wchar_t* name) {
    // 先写临时文件再原子替换。直接 "w" 会先截断再写入，并发读侧可能读到空文件
    // → _wtoi("") = 0 → 被误判为"对方已退出"，进而走删标记 / 重复拉起的破坏性分支。
    wchar_t dir[MAX_PATH]; GetExeDir(dir);
    wchar_t tmp[MAX_PATH + 16];
    _snwprintf(tmp, MAX_PATH + 16, L"%s\\%s.tmp", dir, name);
    {
        FILE* f = _wfopen(tmp, L"w");
        if (!f) return;
        fwprintf(f, L"%u", (unsigned)GetCurrentProcessId());
        fclose(f);
    }
    wchar_t dst[MAX_PATH + 16];
    _snwprintf(dst, MAX_PATH + 16, L"%s\\%s", dir, name);
    MoveFileExW(tmp, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

static DWORD ReadPidFile(const wchar_t* name) {
    wchar_t dir[MAX_PATH]; GetExeDir(dir);
    wchar_t p[MAX_PATH + 16];
    _snwprintf(p, MAX_PATH + 16, L"%s\\%s", dir, name);
    FILE* f = _wfopen(p, L"r");
    if (!f) return 0;
    wchar_t buf[32] = {0};
    fgetws(buf, 32, f);
    fclose(f);
    return (DWORD)_wtoi(buf);
}

static void WriteFileMarker(const wchar_t* name) {
    wchar_t dir[MAX_PATH]; GetExeDir(dir);
    wchar_t p[MAX_PATH + 16];
    _snwprintf(p, MAX_PATH + 16, L"%s\\%s", dir, name);
    FILE* f = _wfopen(p, L"w");
    if (f) fclose(f);
}

// pid 进程的可执行文件是否位于本 exe 目录且名为 exeName（守护/主进程互认）
static int IsOurProcess(DWORD pid, const wchar_t* exeName) {
    if (!pid) return 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    wchar_t path[MAX_PATH] = {0};
    DWORD cch = MAX_PATH;
    BOOL got = QueryFullProcessImageNameW(h, 0, path, &cch);
    CloseHandle(h);
    if (!got) return 1;   // 能 Open 到即视为存活（取证失败按活处理）
    wchar_t self[MAX_PATH] = {0};
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t* s1 = wcsrchr(path, L'\\');
    wchar_t* s2 = wcsrchr(self, L'\\');
    if (!s1 || !s2) return 0;
    if (_wcsnicmp(path, self, (size_t)(s1 - path)) != 0) return 0;
    return (_wcsicmp(s1 + 1, exeName) == 0);
}

// 拉起同名目录下的守护进程 DynamicWallpaperGuard.exe
static void LaunchGuard(void) {
    wchar_t dir[MAX_PATH]; GetExeDir(dir);
    wchar_t exe[MAX_PATH];
    _snwprintf(exe, MAX_PATH, L"%s\\DynamicWallpaperGuard.exe", dir);
    if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES) return;
    if (wcslen(exe) >= MAX_PATH) return;   // 与 ResolveMediaPath 相同的超长保护
    wchar_t cmd[MAX_PATH];
    wcscpy(cmd, exe);
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {0};
    if (CreateProcessW(exe, cmd, NULL, NULL, FALSE, DETACHED_PROCESS,
                       NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

// 主进程侧：确保守护进程在线（守护死了就拉起）
static void EnsureGuardAlive(void) {
    if (IsOurProcess(ReadPidFile(L"wallpaper.guard.pid"), L"DynamicWallpaperGuard.exe")) return;
    LaunchGuard();
}

static void WatchdogTick(void) {
    if (ConsumeQuitSignal()) {   // 被"关闭壁纸.bat"优雅关闭
        WriteFileMarker(L"wallpaper.graceful");   // 通知守护：优雅关闭，勿复活
        PostQuitMessage(0);
        return;
    }
    if (!IsWindow(g_hwnd)) {
        if (!CreateWallpaperWindow()) return;
        EmbedOrFallback(g_hwnd);
        D3DSetWindow(g_hwnd);   // 窗口重建后重新绑定播放器
        return;
    }
    HWND p = GetParent(g_hwnd);
    if (!p || !IsWindow(p) || (g_parent && !IsWindow(g_parent))) {
        EmbedOrFallback(g_hwnd);
        D3DSetWindow(g_hwnd);   // 重新嵌入后确保仍绑定当前窗口
    } else {
        FitToParentOrMonitor(g_hwnd);
        // z 序校准：25H2 方案下保持插在 DefView(图标层)之后、
        // 系统壁纸 WorkerW 之上（EnsureWallpaperZOrder 内部按父窗口类型处理）。
        EnsureWallpaperZOrder(g_hwnd);
    }
    EnsureGuardAlive();   // 守护进程死了就拉起（主进程保持自愈闭环）
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    // 说明：这里不需要"把鼠标消息转发回图标列表"。壁纸窗口在 z 序上排在
    // SHELLDLL_DefView(图标层) 之后，点击命中的是图标层本身，永远落不到壁纸
    // 窗口上；旧的转发分支依赖已删除的品红色键/打穿方案，是死代码。
    case WM_CREATE: {
        RECT rc; GetClientRect(hwnd, &rc);
        g_winW = rc.right - rc.left;
        g_winH = rc.bottom - rc.top;
        return 0;
    }
    case WM_SIZE:
        g_winW = LOWORD(lp);
        g_winH = HIWORD(lp);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
        FitToParentOrMonitor(hwnd);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_PAINT: {
        HWND p = GetParent(hwnd);
        if (p && IsWindow(p)) {
            RECT pr; GetClientRect(p, &pr);
            RECT cr; GetClientRect(hwnd, &cr);
            int pw = pr.right - pr.left, ph = pr.bottom - pr.top;
            int cw = cr.right - cr.left, ch = cr.bottom - cr.top;
            if (pw > 0 && ph > 0 && (cw != pw || ch != ph)) {
                SetWindowPos(hwnd, NULL, 0, 0, pw, ph, SWP_NOZORDER | SWP_NOACTIVATE);
                g_winW = pw;
                g_winH = ph;
            }
        }
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT rc; GetClientRect(hwnd, &rc);
        int w = rc.right - rc.left, h = rc.bottom - rc.top;
        if (w <= 0 || h <= 0) { EndPaint(hwnd, &ps); return 0; }
        if (g_isVideo) {
            // D3D 交换链常驻呈现整个客户区，GDI 不参与；
            // 循环 seek 期间画面保留在交换链上，无空窗、无闪屏
            EndPaint(hwnd, &ps);
            return 0;
        }
        EnsureBackbuffer(dc, w, h);
        HBRUSH br = CreateSolidBrush(RGB(0, 0, 0));
        FillRect(g_memDC, &rc, br);
        DeleteObject(br);
        DrawGifFrame(g_memDC, w, h);
        BitBlt(dc, 0, 0, w, h, g_memDC, 0, 0, SRCCOPY);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_DESTROY:
        if (hwnd == g_hwnd) {
            g_hwnd = NULL;
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK HostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (g_taskbarCreated && msg == g_taskbarCreated) {
        WatchdogTick();
        return 0;
    }
    switch (msg) {
    case WM_TIMER:
        if (wp == TIMER_WATCHDOG) { WatchdogTick(); return 0; }
        if (wp == TIMER_FRAME) { AdvanceFrame(); return 0; }
        return 0;
    case WM_DISPLAYCHANGE:
        if (IsWindow(g_hwnd)) {
            FitToParentOrMonitor(g_hwnd);
            InvalidateRect(g_hwnd, NULL, FALSE);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static HWND CreateWallpaperWindow(void) {
    RECT work = GetPrimaryMonitorRect();
    int wW = work.right - work.left, wH = work.bottom - work.top;
    HWND hwnd = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                L"DynamicWallpaper", L"DynamicWallpaper",
                                WS_POPUP, work.left, work.top, wW, wH,
                                NULL, NULL, g_hInst, NULL);
    if (!hwnd) return NULL;
    g_hwnd = hwnd;
    g_winW = wW;
    g_winH = wH;
    return hwnd;
}

// 去除首尾的空白/引号，并截断到首个换行（只取第一行）
static void TrimPath(const wchar_t* in, wchar_t* out, size_t outCap) {
    wcsncpy(out, in, outCap - 1);
    out[outCap - 1] = L'\0';
    wchar_t* s = out;
    while (*s && (*s == L' ' || *s == L'"' || *s == L'\t')) s++;
    if (s != out) {
        size_t len = wcslen(s) + 1;
        memmove(out, s, len * sizeof(wchar_t));
    }
    wchar_t* nl = wcschr(out, L'\r');
    if (nl) *nl = L'\0';
    nl = wcschr(out, L'\n');
    if (nl) *nl = L'\0';
    size_t len = wcslen(out);
    while (len > 0 && (out[len - 1] == L' ' || out[len - 1] == L'"' ||
                       out[len - 1] == L'\t' || out[len - 1] == L'\r' ||
                       out[len - 1] == L'\n'))
        out[--len] = L'\0';
}

static wchar_t* ResolveMediaPath(LPWSTR cmdLine) {
    static wchar_t result[MAX_PATH];
    result[0] = L'\0';
    wchar_t s[MAX_PATH] = {0};

    if (cmdLine && cmdLine[0] != L'\0') TrimPath(cmdLine, s, MAX_PATH);

    if (s[0] == L'\0') {
        wchar_t dir[MAX_PATH]; GetExeDir(dir);
        wchar_t cfg[MAX_PATH];
        _snwprintf(cfg, MAX_PATH, L"%s\\wallpaper.txt", dir);
        HANDLE f = CreateFileW(cfg, GENERIC_READ, FILE_SHARE_READ, NULL,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f == INVALID_HANDLE_VALUE) { return result; }
        char raw[1024] = {0};
        DWORD read = 0;
        ReadFile(f, raw, sizeof(raw) - 1, &read, NULL);
        CloseHandle(f);
        if (read == 0) { return result; }
        raw[read] = '\0';
        // 容忍 UTF-8 BOM
        if (read >= 3 && (BYTE)raw[0] == 0xEF && (BYTE)raw[1] == 0xBB && (BYTE)raw[2] == 0xBF) {
            memmove(raw, raw + 3, read - 3);
            read -= 3;
            raw[read] = '\0';
        }
        // 严格 UTF-8：配置文件应存为 UTF-8。若用 ANSI/GBK 保存（旧记事本默认），
        // flags=0 会把非法字节静默替换成 U+FFFD → 得到一条必然打不开的路径，
        // 用户只会看到"启动失败"且毫无提示。MB_ERR_INVALID_CHARS 让它失败，
        // 下面走明确的"配置无效"返回。
        int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, raw, -1, NULL, 0);
        if (n <= 0) return result;   // 非 UTF-8：不猜编码，按"配置无效"处理
        wchar_t* wp = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
        if (!wp) return result;
        MultiByteToWideChar(CP_UTF8, 0, raw, -1, wp, n);
        TrimPath(wp, s, MAX_PATH);
        free(wp);
    }

    if (s[0] == L'\0') return result;
    if (PathIsRelativeW(s)) {
        wchar_t dir[MAX_PATH]; GetExeDir(dir);
        wchar_t tmp[MAX_PATH];
        _snwprintf(tmp, MAX_PATH, L"%s\\%s", dir, s);
        wcsncpy(s, tmp, MAX_PATH - 1);
        s[MAX_PATH - 1] = L'\0';
    }

    wchar_t full[MAX_PATH] = {0};
    DWORD n = GetFullPathNameW(s, MAX_PATH, full, NULL);
    // 注意：缓冲区不足时 GetFullPathNameW 返回"所需长度"（>0）而不是 0，
    // 此时 full 内容未定义。若把它当成功用，可能把 s 清空或截断成错误路径
    // → 静默失效（只有 exit 1 + 一行日志）。因此只接受 n>0 且 n<MAX_PATH。
    if (n > 0 && n < MAX_PATH) wcsncpy(s, full, MAX_PATH - 1);
    else if (n == 0) return result;
    // n >= MAX_PATH：超长路径，先按截断路径试一次，失败则报错返回
    else if (GetFileAttributesW(s) == INVALID_FILE_ATTRIBUTES) return result;

    if (GetFileAttributesW(s) == INVALID_FILE_ATTRIBUTES) return result;

    wcsncpy(result, s, MAX_PATH - 1);
    result[MAX_PATH - 1] = L'\0';
    return result;
}

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE hPrev, LPWSTR cmdLine, int nCmdShow) {
    (void)hPrev; (void)nCmdShow;
    g_hInst = hInst;
    HANDLE mutex = CreateMutexW(NULL, TRUE, L"DynamicWallpaper_SingleInstance");
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    // 清理上次"关闭壁纸.bat"可能残留的退出标志（如壁纸已退出后才双击）
    ConsumeQuitSignal();
    WritePidFile(L"wallpaper.main.pid");   // 记录本进程 pid，供守护进程保活

    // ★ 崩溃自动恢复：注册 Windows 重启管理器。进程被外部强杀（TerminateProcess，
    // 如优化软件/任务管理器"结束任务"）时，系统会自动拉起本进程 → 壁纸"杀不死"。
    // 正常退出（退出码 0，如"关闭壁纸.bat"优雅关闭）不会触发重启。
    {
        typedef HRESULT(WINAPI* PFN_RegisterApplicationRestart)(PCWSTR, DWORD);
        PFN_RegisterApplicationRestart fnRAR = (PFN_RegisterApplicationRestart)GetProcAddress(
            GetModuleHandleW(L"kernel32.dll"), "RegisterApplicationRestart");
        if (fnRAR) fnRAR(L"", 0);
    }

    // 必须在创建窗口前声明：壁纸窗口要 SetParent 进 Explorer(Per-Monitor V2)。
    // DPI-unaware 进程跨 DPI 上下文嵌入会导致 DWM 拒绝合成窗口内容（黑屏，实测复现）
    {
        typedef BOOL(WINAPI* PFN_SetDpiCtx)(DPI_AWARENESS_CONTEXT);
        PFN_SetDpiCtx setCtx = (PFN_SetDpiCtx)GetProcAddress(
            GetModuleHandleW(L"user32.dll"), "SetProcessDpiAwarenessContext");
        if (setCtx) setCtx(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, 0);

    GdiplusStartupInput gsi;
    gsi.GdiplusVersion = 1;
    gsi.DebugEventCallback = NULL;
    gsi.SuppressBackgroundThread = FALSE;
    gsi.SuppressExternalCodecs = FALSE;
    ULONG_PTR gdiToken = 0;
    GdiplusStartup(&gdiToken, &gsi, NULL);

    wchar_t* media = ResolveMediaPath(cmdLine);
    // 根据扩展名判定是视频还是 GIF/图片
    g_isVideo = IsVideoFile(media) ? 1 : 0;

    if (!g_isVideo && !LoadGif(media)) {
        LogFail(L"load", media, g_lastHr ? g_lastHr : HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND));
        if (g_img) { GdipDisposeImage(g_img); g_img = NULL; }
        GdiplusShutdown(gdiToken);
        MFShutdown();
        CoUninitialize();
        return 1;
    }
    // 视频不在这里加载：等窗口创建后交给 d3dplayer（D3D 交换链需要窗口句柄）

    WNDCLASSW hostWc = {0};
    hostWc.lpfnWndProc = HostProc;
    hostWc.hInstance = hInst;
    hostWc.lpszClassName = L"DynamicWallpaperHost";
    RegisterClassW(&hostWc);

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = L"DynamicWallpaper";
    RegisterClassW(&wc);

    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    g_host = CreateWindowExW(0, L"DynamicWallpaperHost", L"", 0,
                             0, 0, 0, 0, HWND_MESSAGE, NULL, hInst, NULL);
    if (!g_host || !CreateWallpaperWindow()) {
        LogFail(L"window", media, HRESULT_FROM_WIN32(GetLastError()));
        ReleaseBackbuffer();
        if (g_img) { GdipDisposeImage(g_img); g_img = NULL; }
        GdiplusShutdown(gdiToken);
        MFShutdown();
        CoUninitialize();
        return 1;
    }

    EmbedOrFallback(g_hwnd);

    // 视频：窗口就绪后用 D3D11 播放器硬解播放（DXVA + 无缝循环）
    if (g_isVideo) {
        if (!D3DInit(g_hwnd, media)) {
            LogFail(L"d3d", media, E_FAIL);
            D3DShutdown();
            GdiplusShutdown(gdiToken);
            MFShutdown();
            CoUninitialize();
            return 1;
        }
    }

    // 初始化完成 → 启用守护保活：此后被外部强杀，守护进程 1 秒内自动拉起
    WriteFileMarker(L"wallpaper.ok");
    EnsureGuardAlive();

    UINT firstDelay = 33;
    if (g_isVideo) firstDelay = 16;  // 首帧尽快出
    else if (g_frameCount > 0) firstDelay = g_delays[0] ? g_delays[0] : 100;
    SetTimer(g_host, TIMER_FRAME, firstDelay, NULL);
    SetTimer(g_host, TIMER_WATCHDOG, WATCHDOG_MS, NULL);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    KillTimer(g_host, TIMER_FRAME);
    KillTimer(g_host, TIMER_WATCHDOG);
    if (IsWindow(g_hwnd)) DestroyWindow(g_hwnd);
    // 注：历史版本的 RestoreFolderView() 已被移除 —— 桌面图标层从未被本程序
    // 修改（见 desktop.c 顶部注释），退出时无需（也无权）恢复它的属性。
    D3DShutdown();
    ReleaseBackbuffer();
    if (g_img) { GdipDisposeImage(g_img); g_img = NULL; }
    if (g_delays) { free(g_delays); g_delays = NULL; }
    GdiplusShutdown(gdiToken);
    MFShutdown();
    CoUninitialize();
    return 0;
}

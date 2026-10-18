// main.cpp - DynamicWallpaper 入口 / 窗口 / 看门狗 / 渲染调度
// GIF: GDI+（media.cpp 解码 / render.cpp 绘制）
// 视频: D3D11 播放器（d3dplayer.cpp，DXVA 硬解 + 无缝循环）
// 嵌入 WorkerW（Win10/Win11 桌面层），图标显示在壁纸之上（desktop.cpp）
// 编译：build.bat
#include "wallpaper.h"
#include "d3dplayer.h"
#include <stdlib.h>   // _wtoi
#include <wchar.h>    // wcsrchr / wcscmp / wcsstr
#include <psapi.h>    // GetProcessMemoryInfo（资源快照日志）

const UINT TIMER_FRAME = 1;
const UINT TIMER_WATCHDOG = 2;
const UINT WATCHDOG_MS = 3000;

HINSTANCE g_hInst = nullptr;
HWND g_hwnd = nullptr;
HWND g_host = nullptr;
int g_winW = 0, g_winH = 0;
UINT g_taskbarCreated = 0;
bool g_isVideo = false;

// ---- 热重载状态（改 wallpaper.txt 即时换壁纸，不必重启）----
// g_curMedia  : 当前实际加载的素材全路径，用于判断配置是否变了
// g_lockedMedia: 非空 = 启动时用命令行指定了素材 → 命令行优先，不响应配置变更
static std::wstring g_curMedia;
static std::wstring g_lockedMedia;
// 失败退避：某次重载失败后记住它，配置内容没再变就不再重试（否则看门狗每 3 秒
// 重试一次同一个坏文件，debug.log 被刷满、CPU 空转）。配置一旦改动（路径或文本
// 变化）就重新尝试。
static std::wstring g_failedMedia;

static std::wstring GetExeDir() {
    wchar_t exe[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring dir = exe;
    size_t pos = dir.find_last_of(L'\\');
    if (pos != std::wstring::npos) dir = dir.substr(0, pos + 1);
    else dir.clear();
    return dir;
}

static void LogFail(const wchar_t* msg, const std::wstring& path, HRESULT hr) {
    std::wstring logPath = GetExeDir() + L"debug.log";
    FILE* f = nullptr;
    if (_wfopen_s(&f, logPath.c_str(), L"a") != 0 || !f) return;
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    fwprintf(f, L"%04u-%02u-%02u %02u:%02u:%02u %s path=%s hr=0x%08X\n",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
             msg ? msg : L"fail", path.c_str(), (unsigned)hr);
    fclose(f);
}

// ---------- 资源快照（排查内存/句柄泄漏） ----------
// 每 60s 往 debug.log 写一行：工作集/私有提交/峰值/句柄/GDI/USER 对象数。
// 读法：commit 持续上涨=堆泄漏；handles/gdi/user 持续上涨=内核对象泄漏
// （典型如 COM 未 Release）。间隔可用环境变量 KW_RES_LOG_MS 调整，0=关闭。
static void LogResourceSnapshot() {
    static DWORD s_last = 0;
    static int s_init = 0;
    static DWORD s_start = 0;
    static DWORD s_interval = 60000;
    if (!s_init) {
        s_init = 1;
        s_start = GetTickCount();   // 进程内起点，用于算运行秒数
        wchar_t buf[16] = {0};
        if (GetEnvironmentVariableW(L"KW_RES_LOG_MS", buf, 16) > 0) {
            int v = _wtoi(buf);
            s_interval = (v >= 0) ? (DWORD)v : 0;
        }
    }
    if (s_interval == 0) return;
    DWORD now = GetTickCount();
    if (s_last && now - s_last < s_interval) return;
    s_last = now;

    PROCESS_MEMORY_COUNTERS_EX pmc;
    pmc.cb = sizeof(pmc);
    DWORD handles = 0;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc))) return;
    GetProcessHandleCount(GetCurrentProcess(), &handles);
    DWORD gdi = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    DWORD user = GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS);

    wchar_t line[256];
    _snwprintf(line, 256,
        L"[res] uptime=%lus ws=%uMB commit=%uMB peakws=%uMB handles=%lu gdi=%lu user=%lu",
        (unsigned long)((now - s_start) / 1000),
        (unsigned)(pmc.WorkingSetSize >> 20),
        (unsigned)(pmc.PrivateUsage >> 20),
        (unsigned)(pmc.PeakWorkingSetSize >> 20),
        (unsigned long)handles, (unsigned long)gdi, (unsigned long)user);
    LogFail(line, L"", S_OK);
}

static void AdvanceFrame() {
    if (!IsWindow(g_hwnd)) return;
    if (g_isVideo) {
        // D3D 播放器泵帧：解码→GPU 转换→呈现；循环在内部 seek 回 0 无缝完成。
        // 交换链全程保留画面，无任何空窗 → 不可能闪出系统壁纸。
        UINT next = D3DPumpFrame();
        if (next < 10) next = 10;
        SetTimer(g_host, TIMER_FRAME, next, nullptr);
    } else if (g_frameCount > 0) {
        if (g_frameCount == 1) {
            // 静态图：画一次就停掉帧定时器。
            // 旧实现按 100ms 默认延时无限重绘整屏 HighQualityBicubic —— 用一张
            // 静态图作壁纸也常年 ~10fps 全屏重绘，与"极小占用"的定位不符。
            InvalidateRect(g_hwnd, nullptr, FALSE);
            return;
        }
        g_curFrame = (g_curFrame + 1) % g_frameCount;
        UINT delay = g_delays[g_curFrame];
        if (delay < 10) delay = 10;
        SetTimer(g_host, TIMER_FRAME, delay, nullptr);
        InvalidateRect(g_hwnd, nullptr, FALSE);
        // GIF 帧推进日志（节流：首帧 + 每 60 帧），与 c 版同款——
        // GIF 路径此前零业务日志，动画是否在走只能靠任务管理器猜。
        static DWORD s_tick = 0;
        s_tick++;
        if (s_tick == 1 || (s_tick % 60) == 0) {
            wchar_t line[96];
            _snwprintf(line, 96, L"[main] gif frame=%lu/%lu delay=%ums",
                       (unsigned long)s_tick, (unsigned long)g_frameCount, (unsigned)delay);
            LogFail(line, L"", S_OK);
        }
    }
}

// 按当前媒体类型重启帧定时器（启动首帧与热重载共用同一套规则）
static void StartFrameTimer() {
    KillTimer(g_host, TIMER_FRAME);
    UINT delay = 33;
    if (g_isVideo) delay = 16;                       // 视频：首帧尽快出
    else if (g_frameCount > 0) delay = g_delays[0] ? g_delays[0] : 100;
    SetTimer(g_host, TIMER_FRAME, delay, nullptr);
}

static HWND CreateWallpaperWindow();
static void CheckMediaReload();

// ★ 优雅关闭标志：桌面「关闭壁纸.bat」改为写本文件（而非 taskkill /f）。
// 看门狗检测到 → 正常退出（退出码 0 不触发重启管理器恢复）→ 壁纸关闭。
// 用 taskkill /f 强杀则会被重启管理器拉起 → 壁纸只可能被"关闭"不可能被"杀"。
static bool ConsumeQuitSignal() {
    std::wstring dir = GetExeDir();
    HANDLE f = CreateFileW((dir + L"wallpaper.quit").c_str(), GENERIC_READ, 0,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    CloseHandle(f);
    DeleteFileW((dir + L"wallpaper.quit").c_str());
    return true;
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
    // 先写临时文件再原子替换。直接 L"w" 会先截断再写入，并发读侧可能读到空文件
    // → _wtoi("") = 0 → 被误判为"对方已退出"，进而走删标记 / 重复拉起的破坏性分支。
    std::wstring dir = GetExeDir();
    std::wstring tmp = dir + name + L".tmp";
    FILE* f = nullptr;
    if (_wfopen_s(&f, tmp.c_str(), L"w") != 0 || !f) return;
    fwprintf(f, L"%u", (unsigned)GetCurrentProcessId());
    fclose(f);
    MoveFileExW(tmp.c_str(), (dir + name).c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

static DWORD ReadPidFile(const wchar_t* name) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, (GetExeDir() + name).c_str(), L"r") != 0 || !f) return 0;
    wchar_t buf[32] = {};
    fgetws(buf, 32, f);
    fclose(f);
    return (DWORD)_wtoi(buf);
}

static void WriteFileMarker(const wchar_t* name) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, (GetExeDir() + name).c_str(), L"w") == 0 && f) fclose(f);
}

// pid 进程的可执行文件是否位于本 exe 目录且名为 exeName（守护/主进程互认）
static bool IsOurProcess(DWORD pid, const wchar_t* exeName) {
    if (!pid) return false;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return false;
    wchar_t path[MAX_PATH] = {};
    DWORD cch = MAX_PATH;
    BOOL got = QueryFullProcessImageNameW(h, 0, path, &cch);
    CloseHandle(h);
    if (!got) return true;   // 能 Open 到即视为存活（取证失败按活处理）
    wchar_t self[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    wchar_t* s1 = wcsrchr(path, L'\\');
    wchar_t* s2 = wcsrchr(self, L'\\');
    if (!s1 || !s2) return false;
    if (_wcsnicmp(path, self, (size_t)(s1 - path)) != 0) return false;
    return _wcsicmp(s1 + 1, exeName) == 0;
}

// 拉起同名目录下的守护进程 DynamicWallpaperGuard.exe
static void LaunchGuard() {
    std::wstring exe = GetExeDir() + L"DynamicWallpaperGuard.exe";
    if (GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) return;
    if (exe.size() >= MAX_PATH) return;   // 与 ResolveMediaPath 相同的超长保护
    wchar_t cmd[MAX_PATH] = {};
    wcscpy_s(cmd, exe.c_str());           // 上面已检查长度，安全
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};
    if (CreateProcessW(exe.c_str(), cmd, nullptr, nullptr, FALSE, DETACHED_PROCESS,
                       nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

// 主进程侧：确保守护进程在线（守护死了就拉起）
static void EnsureGuardAlive() {
    if (IsOurProcess(ReadPidFile(L"wallpaper.guard.pid"), L"DynamicWallpaperGuard.exe")) return;
    LaunchGuard();
}

static void WatchdogTick() {
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
    CheckMediaReload();     // wallpaper.txt 改动 → 免重启换素材
    LogResourceSnapshot();  // 每 60s 一条资源快照（排查泄漏）
    EnsureGuardAlive();   // 守护进程死了就拉起（主进程保持自愈闭环）
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
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
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
        FitToParentOrMonitor(hwnd);
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    case WM_PAINT: {
        HWND p = GetParent(hwnd);
        if (p && IsWindow(p)) {
            RECT pr; GetClientRect(p, &pr);
            RECT cr; GetClientRect(hwnd, &cr);
            int pw = pr.right - pr.left, ph = pr.bottom - pr.top;
            int cw = cr.right - cr.left, ch = cr.bottom - cr.top;
            if (pw > 0 && ph > 0 && (cw != pw || ch != ph)) {
                SetWindowPos(hwnd, nullptr, 0, 0, pw, ph, SWP_NOZORDER | SWP_NOACTIVATE);
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
            g_hwnd = nullptr;
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK HostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
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
            InvalidateRect(g_hwnd, nullptr, FALSE);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static HWND CreateWallpaperWindow() {
    RECT work = GetPrimaryMonitorRect();
    int wW = work.right - work.left, wH = work.bottom - work.top;
    HWND hwnd = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                                L"DynamicWallpaper", L"DynamicWallpaper",
                                WS_POPUP, work.left, work.top, wW, wH,
                                nullptr, nullptr, g_hInst, nullptr);
    if (!hwnd) return nullptr;
    g_hwnd = hwnd;
    g_winW = wW;
    g_winH = wH;
    return hwnd;
}

static std::wstring TrimPath(std::wstring s) {
    while (!s.empty() && (s.front() == L' ' || s.front() == L'"' || s.front() == L'\t'))
        s.erase(0, 1);
    while (!s.empty() && (s.back() == L' ' || s.back() == L'"' || s.back() == L'\t' ||
                          s.back() == L'\r' || s.back() == L'\n'))
        s.pop_back();
    size_t nl = s.find_first_of(L"\r\n");
    if (nl != std::wstring::npos) s = s.substr(0, nl);
    while (!s.empty() && (s.back() == L' ' || s.back() == L'"' || s.back() == L'\t'))
        s.pop_back();
    return s;
}

static std::wstring ResolveMediaPath(LPWSTR cmdLine) {
    std::wstring s;
    if (cmdLine && cmdLine[0] != L'\0') s = TrimPath(cmdLine);

    if (s.empty()) {
        std::wstring cfg = GetExeDir() + L"wallpaper.txt";
        HANDLE f = CreateFileW(cfg.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) return L"";
        char buf[1024] = {};
        DWORD read = 0;
        ReadFile(f, buf, sizeof(buf) - 1, &read, nullptr);
        CloseHandle(f);
        if (read == 0) return L"";
        buf[read] = '\0';
        if (read >= 3 && (BYTE)buf[0] == 0xEF && (BYTE)buf[1] == 0xBB && (BYTE)buf[2] == 0xBF) {
            memmove(buf, buf + 3, read - 3);
            read -= 3;
            buf[read] = '\0';
        }
        // 严格 UTF-8：配置文件应存为 UTF-8。若用 ANSI/GBK 保存（旧记事本默认），
        // flags=0 会把非法字节静默替换成 U+FFFD → 得到一条必然打不开的路径，
        // 用户只会看到"启动失败"且毫无提示。MB_ERR_INVALID_CHARS 让它失败，
        // 下面走明确的"配置无效"返回。
        int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, buf, -1, nullptr, 0);
        if (n <= 0) return L"";   // 非 UTF-8：不猜编码，按"配置无效"处理
        s.assign(n - 1, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, buf, -1, &s[0], n);
        s = TrimPath(s);
    }

    if (s.empty()) return L"";
    if (PathIsRelativeW(s.c_str())) s = GetExeDir() + s;

    wchar_t full[MAX_PATH] = {};
    DWORD n = GetFullPathNameW(s.c_str(), MAX_PATH, full, nullptr);
    // 注意：缓冲区不足时 GetFullPathNameW 返回"所需长度"（>0）而不是 0，
    // 此时 full 内容未定义。若把它当成功用，可能把 s 清空或截断成错误路径
    // → 静默失效（只有 exit 1 + 一行日志）。因此只接受 n>0 且 n<MAX_PATH。
    if (n > 0 && n < MAX_PATH) s = full;
    else if (n == 0) return L"";
    // n >= MAX_PATH：超长路径，先按截断路径试一次，失败则报错返回
    else if (GetFileAttributesW(s.c_str()) == INVALID_FILE_ATTRIBUTES) return L"";

    if (GetFileAttributesW(s.c_str()) == INVALID_FILE_ATTRIBUTES) return L"";
    return s;
}

// ---- 热重载：改 wallpaper.txt 即时换素材，不必关闭壁纸再重启 ----
// 三个关键设计：
//  1) 比较「解析后的完整路径」而不是文件时间戳：只关心用哪个素材，时间戳会被
//     复制文件、同秒多次写、编辑器保存方式搅乱，产生大量假变更。
//  2) ResolveMediaPath 对「文件不存在 / 非 UTF-8 / 空文件」一律返回空串，
//     所以记事本"先清空再写"这种编辑中间态读到空串会被忽略，下一拍（3 秒内）重试。
//  3) 新素材加载失败 → 自动回滚到旧素材，绝不停在黑屏上。
static bool LoadMediaInto(const std::wstring& path) {
    bool isVid = IsVideoFile(path);
    if (isVid != g_isVideo) {
        // 类型变了（视频↔GIF/图片）：先彻底拆掉另一条链路，
        // 否则两条链路会同时持有同一个窗口 / D3D 设备。
        if (g_isVideo) D3DShutdown();
        else ReleaseBackbuffer();
    }
    if (isVid) return D3DInit(g_hwnd, path.c_str());   // D3DInit 内部先 D3DShutdown
    return LoadGif(path);                                // LoadGif 内部先释放旧 Image
}

static void CheckMediaReload() {
    if (!g_lockedMedia.empty()) return;   // 命令行指定过素材 → 命令行优先，忽略配置变更
    if (!IsWindow(g_hwnd)) return;
    std::wstring want = ResolveMediaPath(nullptr);
    if (want.empty() || want == g_curMedia) return;   // 空=编辑中/无效；相同=没变
    if (want == g_failedMedia) return;                 // 这个路径刚失败过 → 退避等待

    const std::wstring old = g_curMedia;
    if (LoadMediaInto(want)) {
        g_curMedia = want;
        g_failedMedia.clear();
        g_isVideo = IsVideoFile(want);
        LogFail(L"reload-ok", want, S_OK);
        StartFrameTimer();
        FitToParentOrMonitor(g_hwnd);
        InvalidateRect(g_hwnd, nullptr, FALSE);
        EnsureWallpaperZOrder(g_hwnd);
        return;
    }

    // 加载失败：写日志并回滚到旧素材（g_isVideo 保持调用前的值，回滚方向正确）
    LogFail(L"reload-failed", want, g_lastHr ? g_lastHr : E_FAIL);
    g_failedMedia = want;                    // 退避：同一坏路径不再反复重试
    if (!old.empty()) LoadMediaInto(old);
    StartFrameTimer();
}

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR cmdLine, int) {
    g_hInst = hInst;
    HANDLE mutex = CreateMutexW(nullptr, TRUE, L"DynamicWallpaper_SingleInstance");
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

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    GdiplusStartupInput gsi;
    ULONG_PTR gdiToken = 0;
    GdiplusStartup(&gdiToken, &gsi, nullptr);

    std::wstring media = ResolveMediaPath(cmdLine);
    // 根据扩展名判定是视频还是 GIF/图片
    g_isVideo = IsVideoFile(media);
    g_curMedia = media;
    // 命令行指定了素材时锁死：README 的「命令行优先」语义，热重载只认配置文件。
    // 也就是说 `DynamicWallpaper.exe "D:\x.mp4"` 之后改 wallpaper.txt 不生效。
    if (cmdLine) {
        if (!TrimPath(cmdLine).empty()) g_lockedMedia = media;
    }

    if (!g_isVideo && !LoadGif(media)) {
        LogFail(L"load", media, g_lastHr ? g_lastHr : HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND));
        delete g_img; g_img = nullptr;
        GdiplusShutdown(gdiToken);
        MFShutdown();
        CoUninitialize();
        return 1;
    }
    // 视频不在这里加载：等窗口创建后交给 d3dplayer（D3D 交换链需要窗口句柄）

    WNDCLASSW hostWc = {};
    hostWc.lpfnWndProc = HostProc;
    hostWc.hInstance = hInst;
    hostWc.lpszClassName = L"DynamicWallpaperHost";
    RegisterClassW(&hostWc);

    WNDCLASSW wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = L"DynamicWallpaper";
    RegisterClassW(&wc);

    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    g_host = CreateWindowExW(0, L"DynamicWallpaperHost", L"", 0,
                             0, 0, 0, 0, HWND_MESSAGE, nullptr, hInst, nullptr);
    if (!g_host || !CreateWallpaperWindow()) {
        LogFail(L"window", media, HRESULT_FROM_WIN32(GetLastError()));
        ReleaseBackbuffer();
        delete g_img; g_img = nullptr;
        GdiplusShutdown(gdiToken);
        MFShutdown();
        CoUninitialize();
        return 1;
    }

    EmbedOrFallback(g_hwnd);

    // 视频：窗口就绪后用 D3D11 播放器硬解播放（DXVA + 无缝循环）
    if (g_isVideo) {
        if (!D3DInit(g_hwnd, media.c_str())) {
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
    SetTimer(g_host, TIMER_FRAME, firstDelay, nullptr);
    SetTimer(g_host, TIMER_WATCHDOG, WATCHDOG_MS, nullptr);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    KillTimer(g_host, TIMER_FRAME);
    KillTimer(g_host, TIMER_WATCHDOG);
    if (IsWindow(g_hwnd)) DestroyWindow(g_hwnd);
    // 注：历史版本的 RestoreFolderView() 已被移除 —— 桌面图标层从未被本程序
    // 修改（见 desktop.cpp 顶部注释），退出时无需（也无权）恢复它的属性。
    D3DShutdown();
    ReleaseBackbuffer();
    delete g_img; g_img = nullptr;
    GdiplusShutdown(gdiToken);
    MFShutdown();
    CoUninitialize();
    return 0;
}
// desktop.c - DynamicWallpaper (C 版) 桌面嵌入层
// Win11 24H2+/25H2 "raised desktop" 结构（本机 25H2 26200 实测 + Lively PR#2050）：
//   Progman(WS_EX_NOREDIRECTIONBITMAP)
//     ├─ SHELLDLL_DefView(WS_EX_LAYERED, 图标层) ─ SysListView32
//     └─ WorkerW(全屏, 系统壁纸层, z 在 DefView 之下)
// 方案A：壁纸窗口 SetParent 进 WorkerW 当普通子窗口（Lively 同款）：
//   图标层(DefView)永远在壁纸之上 → 右键/图标/文字完全系统原状。
// 方案B：Progman 的 LAYERED 子窗口插 DefView 之后（微软文档方案，备选）。
// 方案C：顶层 HWND_BOTTOM 兜底。
// 绝不修改图标层（SysListView32）任何属性——色键穿透曾导致右键弹图标
// 菜单 + 黑色图标残缺。
#include "wallpaper.h"
#include <stdio.h>      // _wfopen / fwprintf（EmbedLog 写 debug.log）

extern HWND g_hwnd;

// 当前嵌入的父窗口（main.c 看门狗使用）
HWND g_parent = NULL;

// Win11 24H2+/25H2 "raised desktop" 方案的 z 序锚点：
// Progman 子级 z(高→低) = [SHELLDLL_DefView(图标层, LAYERED), WorkerW(系统壁纸)]
// 我们的壁纸窗口插到 DefView 之后，且必须把系统 WorkerW 压到我们之下
//（Lumin 实测：缺第二步会被黑壁纸 WorkerW 盖住 → 壁纸不可见）。
static HWND g_wpDefView = NULL;
static HWND g_wpWorkerW = NULL;

// ---- 关于「图标层打穿」：这里**故意什么都不做** ----
// 历史版本曾尝试修改图标层（SysListView32）背景：先是品红色键 + 鼠标穿透转发，
// 后是只把背景色设成 CLR_NONE。两者都已删除，原因：
//   1) 品红色键方案实测产生"黑色图标残缺 + 右键弹出图标菜单"；
//   2) 桌面图标列表本来就不绘制自己的背景（否则系统壁纸永远看不见），
//      实测 LVM_GETBKCOLOR 就是 CLR_NONE —— 所谓"打穿"从来不是必需的，
//      那段代码也没有任何调用点，属于死代码。
// 因此本文件对图标层**零修改**：图标、文字、右键菜单、扩展样式全为系统原状。
// 壁纸能显示，靠的是 z 序（壁纸窗口排在 SHELLDLL_DefView 之后见
// EnsureWallpaperZOrder）而不是改图标层属性。

static void EmbedLog(const wchar_t* msg, HWND w) {
    wchar_t exe[MAX_PATH] = {0};
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    wchar_t* slash = wcsrchr(exe, L'\\');
    if (slash) *slash = L'\0';
    wchar_t logPath[MAX_PATH + 16];
    int n = _snwprintf(logPath, MAX_PATH + 16, L"%s\\debug.log", exe);
    if (n < 0) logPath[MAX_PATH + 15] = L'\0';
    FILE* f = _wfopen(logPath, L"a");
    if (!f) return;
    SYSTEMTIME st = {0};
    GetLocalTime(&st);
    wchar_t cls[64] = {0};
    wchar_t info[256] = {0};
    if (w) {
        GetClassNameW(w, cls, 64);
        RECT r = {0};
        GetWindowRect(w, &r);
        _snwprintf(info, 256, L"%s h=0x%p cls=%s rect=(%ld,%ld,%ld,%ld)", msg,
                   (void*)w, cls, r.left, r.top, r.right, r.bottom);
    } else {
        _snwprintf(info, 256, L"%s (null)", msg);
    }
    fwprintf(f, L"%04u-%02u-%02u %02u:%02u:%02u [embed] %s\n",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, info);
    fclose(f);
}

void EnsureWallpaperZOrder(HWND hwnd);

// FindWindow(L"Progman") 在部分 25H2 上返回 0（EnumWindows 却能枚举到），
// 用 EnumWindows 遍历兜底：Progman 类名唯一，找到即返回。
static BOOL CALLBACK EnumFindProgman(HWND h, LPARAM lp) {
    wchar_t cls[64] = {0};
    if (GetClassNameW(h, cls, 64) > 0 && wcscmp(cls, L"Progman") == 0) {
        *(HWND*)lp = h;
        return FALSE;
    }
    return TRUE;
}

static HWND FindProgman(void) {
    HWND viaFind = FindWindowW(L"Progman", NULL);
    if (viaFind) return viaFind;
    HWND res = NULL;
    EnumWindows(EnumFindProgman, (LPARAM)&res);
    return res;
}

RECT GetPrimaryMonitorRect(void) {
    RECT work = { 0, 0, 0, 0 };
    HMONITOR pm = MonitorFromPoint((POINT){ 0, 0 }, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi = { sizeof(mi) };
    if (GetMonitorInfoW(pm, &mi)) return mi.rcMonitor;
    work.left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    work.top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    work.right = work.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    work.bottom = work.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
    return work;
}

void FitToParentOrMonitor(HWND hwnd) {
    if (!hwnd || !IsWindow(hwnd)) return;
    int x = 0, y = 0, w = 0, h = 0;
    HWND p = GetParent(hwnd);
    if (p && IsWindow(p)) {
        RECT pr; GetClientRect(p, &pr);
        w = pr.right - pr.left;
        h = pr.bottom - pr.top;
    } else {
        RECT r = GetPrimaryMonitorRect();
        x = r.left; y = r.top;
        w = r.right - r.left;
        h = r.bottom - r.top;
    }
    if (w <= 0 || h <= 0) return;
    RECT cr; GetClientRect(hwnd, &cr);
    int cw = cr.right - cr.left, ch = cr.bottom - cr.top;
    if (cw == w && ch == h && g_winW == w && g_winH == h) return;
    SetWindowPos(hwnd, NULL, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    g_winW = w;
    g_winH = h;
}

// 找"包含 SHELLDLL_DefView 的 WorkerW"（图标层所在）
static BOOL CALLBACK EnumFindIconWorkerW(HWND hwnd, LPARAM lp) {
    wchar_t cls[64] = {0};
    if (GetClassNameW(hwnd, cls, 64) <= 0) return TRUE;
    if (wcscmp(cls, L"WorkerW") != 0) return TRUE;
    if (FindWindowExW(hwnd, NULL, L"SHELLDLL_DefView", NULL)) {
        *(HWND*)lp = hwnd;
        return FALSE;
    }
    return TRUE;
}

// 策略1：图标层 WorkerW 后面的第一个空 WorkerW（Win10 经典结构的产物）
static HWND FindWorkerAfterIconWorker(void) {
    HWND iconWorker = NULL;
    EnumWindows(EnumFindIconWorkerW, (LPARAM)&iconWorker);
    if (!iconWorker) return NULL;
    HWND next = FindWindowExW(NULL, iconWorker, L"WorkerW", NULL);
    return next;
}

// 方案A 用：Progman 的全屏 WorkerW 子窗口（24H2+/25H2 的系统壁纸层，
// Lively PR#2050 的目标窗口）。只认覆盖主屏 ≥90% 的，排除 135x37 占位 WorkerW。
static HWND FindWallpaperWorkerW(HWND progman) {
    if (!progman || !IsWindow(progman)) return NULL;
    RECT m = GetPrimaryMonitorRect();
    HWND w = FindWindowExW(progman, NULL, L"WorkerW", NULL);
    while (w) {
        RECT r = {0};
        if (GetWindowRect(w, &r) &&
            (r.right - r.left) >= (m.right - m.left) * 9 / 10 &&
            (r.bottom - r.top) >= (m.bottom - m.top) * 9 / 10) {
            return w;
        }
        w = FindWindowExW(progman, w, L"WorkerW", NULL);
    }
    return NULL;
}

// 壁纸窗口转成 child 并挂到 parent；锚定图标层(DefView)正后方 =
// 图标之下、系统壁纸绘制层之上。绝不用 HWND_BOTTOM——Win11 25H2 的
// 系统壁纸画在 Progman 的子窗口里，压到最底会被它盖住（实测复现）。
static int AttachTo(HWND hwnd, HWND parent) {
    if (!hwnd || !parent || !IsWindow(parent)) return 0;
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU);
    style |= WS_CHILD | WS_VISIBLE;
    SetWindowLongPtrW(hwnd, GWL_STYLE, style);
    // 不要 WS_EX_TRANSPARENT：它会让窗口在兄弟窗口之后绘制，正好盖住图标。
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, WS_EX_NOACTIVATE);
    if (!SetParent(hwnd, parent)) return 0;
    RECT pr; GetClientRect(parent, &pr);
    int w = pr.right - pr.left, h = pr.bottom - pr.top;
    if (w <= 0 || h <= 0) {
        RECT mr = GetPrimaryMonitorRect();
        w = mr.right - mr.left;
        h = mr.bottom - mr.top;
    }
    g_parent = parent;
    g_winW = w;
    g_winH = h;
    EnsureWallpaperZOrder(hwnd);
    return IsWindowVisible(hwnd);
}

// 把壁纸窗口插到图标列表(SysListView32)正后方（z 序更低半级）：
// 图标列表在上、壁纸窗口在中、DefView 的系统壁纸背景在下。
// 绝不修改列表的任何属性（色键/样式）——那是右键/图标异常的根源。
void EnsureWallpaperZOrder(HWND hwnd) {
    if (!hwnd || !IsWindow(hwnd)) return;
    HWND parent = GetParent(hwnd);
    if (!parent || !IsWindow(parent)) {
        // 顶层模式：直接压到 z 序最底（DWM 壁纸之上、图标层之下）
        SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        EmbedLog(L"zorder: toplevel bottom", NULL);
        return;
    }

    // 锚点判定：
    //  parent 是 Progman（24H2+/25H2）→ 双向 z 锚定（Lumin 方案）：
    //    1) 壁纸窗口插到 DefView(图标层) 之后 = 图标之下
    //    2) 系统 WorkerW(壁纸层) 压到壁纸窗口之后 = 壁纸之下
    //    缺第 2 步会被黑壁纸 WorkerW 盖住（实测复现）。
    //  parent 是 DefView / WorkerW（旧结构）→ 插到图标列表之后/压底
    // z 序操作幂等无开销，但日志只在锚定失败时记录（看门狗 3 秒一次，
    // 常规成功不写日志，避免 debug.log 无限增长）。
    wchar_t pcls[64] = {0};
    GetClassNameW(parent, pcls, 64);
    if (wcscmp(pcls, L"Progman") == 0) {
        HWND defView = (g_wpDefView && IsWindow(g_wpDefView) &&
                        GetParent(g_wpDefView) == parent)
                       ? g_wpDefView
                       : FindWindowExW(parent, NULL, L"SHELLDLL_DefView", NULL);
        int ok = 1;
        if (defView) {
            ok = !!SetWindowPos(hwnd, defView, 0, 0, 0, 0,
                                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        } else ok = 0;
        HWND workerW = (g_wpWorkerW && IsWindow(g_wpWorkerW) &&
                        GetParent(g_wpWorkerW) == parent)
                       ? g_wpWorkerW
                       : FindWindowExW(parent, NULL, L"WorkerW", NULL);
        HWND parentProgman = GetParent(hwnd);
        if (workerW && workerW != hwnd) {
            if (!SetWindowPos(workerW, hwnd, 0, 0, 0, 0,
                              SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) ok = 0;
        } else if (!workerW && parentProgman) {
            // ★ 结构退化自愈：Progman 下的系统 WorkerW（壁纸层）消失了
            // （explorer 刷新/未 raised 状态）。重发 0x052C 让系统重建
            // WorkerW，下一轮看门狗即可恢复双向锚定。不刷日志防刷屏。
            static DWORD s_lastRaise = 0;
            DWORD now = GetTickCount();
            if (now - s_lastRaise > 5000) {
                SendMessageTimeoutW(parentProgman, 0x052C, 0, 0, SMTO_NORMAL, 1000, NULL);
                s_lastRaise = now;
            }
            ok = 0;
        }
        if (!ok) EmbedLog(L"zorder: anchor FAILED (will retry)", NULL);
    } else if (wcscmp(pcls, L"SHELLDLL_DefView") == 0) {
        HWND anchor = FindWindowExW(parent, NULL, L"SysListView32", NULL);
        if (!anchor) anchor = FindWindowExW(parent, NULL, L"DirectUIHWND", NULL);
        if (anchor) {
            SetWindowPos(hwnd, anchor, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            EmbedLog(L"zorder: after icon-list", anchor);
        } else {
            SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            EmbedLog(L"zorder: defview bottom", NULL);
        }
    } else {
        SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        EmbedLog(L"zorder: workerw bottom", NULL);
    }
}

static void ApplyFallbackTopLevel(HWND hwnd) {
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    style &= ~WS_CHILD;
    style |= WS_POPUP | WS_VISIBLE;
    SetWindowLongPtrW(hwnd, GWL_STYLE, style);
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    SetParent(hwnd, NULL);
    RECT r = GetPrimaryMonitorRect();
    int w = r.right - r.left, h = r.bottom - r.top;
    SetWindowPos(hwnd, HWND_BOTTOM, r.left, r.top, w, h,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    g_parent = NULL;
    g_winW = w;
    g_winH = h;
}

int EmbedOrFallback(HWND hwnd) {
    HWND progman = FindProgman();

    // ★ 固定唤醒 "raised desktop"：0x052C 让系统把壁纸画进 Progman 下的
    // 全屏 WorkerW（并清空 DefView 列表背景）。2026-09-17 实测复现：
    //   开机/explorer 刷新后桌面可能回到未 raised 状态（Progman 下只有
    //   DefView，无 WorkerW），此时系统壁纸由 DWM 直绘在最底层，会盖住
    //   我们的窗口 → 壁纸"消失"（只剩系统默认壁纸）。每次嵌入前都发
    //   0x052C 强制恢复三层结构：DefView(图标) / 我们的窗口 / WorkerW(壁纸)。
    if (progman) SendMessageTimeoutW(progman, 0x052C, 0, 0, SMTO_NORMAL, 1000, NULL);
    Sleep(120);

    // ---- 主方案（Lumin 实测方案，Win11 24H2+/25H2）：Progman 的 LAYERED 子窗口
    // + 双向 z 锚定（DefView 在上、系统 WorkerW 在下）。挂 Progman 而非 WorkerW：
    // 24H2+ 的 WorkerW 子树不合成第三方子窗口（实测 GDI/D3D 均不可见）。
    HWND defView = progman ? FindWindowExW(progman, NULL, L"SHELLDLL_DefView", NULL)
                           : NULL;
    if (!defView) {   // 罕见兜底：0x052C 后仍没有 DefView，再等一次
        Sleep(150);
        defView = progman ? FindWindowExW(progman, NULL, L"SHELLDLL_DefView", NULL)
                          : NULL;
    }
    if (progman && defView && IsWindow(defView)) {
        // 子窗口化 + LAYERED（微软建议 bAlpha=0xFF 做 DX 呈现）
        LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU);
        style |= WS_CHILD | WS_VISIBLE;
        SetWindowLongPtrW(hwnd, GWL_STYLE, style);
        LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        ex |= WS_EX_LAYERED | WS_EX_NOACTIVATE;
        ex &= ~WS_EX_TOPMOST;
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
        SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
        if (SetParent(hwnd, progman)) {
            g_parent = progman;
            g_wpDefView = defView;
            g_wpWorkerW = FindWallpaperWorkerW(progman);
            RECT pr; GetClientRect(progman, &pr);
            int w = pr.right - pr.left, h = pr.bottom - pr.top;
            if (w <= 0 || h <= 0) {
                RECT mr = GetPrimaryMonitorRect();
                w = mr.right - mr.left; h = mr.bottom - mr.top;
            }
            g_winW = w; g_winH = h;
            SetWindowPos(hwnd, NULL, 0, 0, w, h,
                         SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            // ★ 双向 z 锚定（EnsureWallpaperZOrder 内部完成）
            EnsureWallpaperZOrder(hwnd);
            RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW);
            EmbedLog(L"embed: progman-layered anchor", defView);
            return 1;
        }
        EmbedLog(L"embed: setparent failed", progman);
    }

    // ---- 备选（pre-24H2 / Win10）：挂进图标层后面的空 WorkerW
    HWND workerW = FindWorkerAfterIconWorker();
    if (!workerW && progman) {   // 老结构未生成：0x052C 唤醒后重找
        SendMessageTimeoutW(progman, 0x052C, 0, 0, SMTO_NORMAL, 1000, NULL);
        Sleep(150);
        workerW = FindWorkerAfterIconWorker();
    }
    if (workerW && IsWindow(workerW)) {
        if (AttachTo(hwnd, workerW)) {
            g_wpDefView = NULL;
            g_wpWorkerW = NULL;
            EmbedLog(L"embed: classic workerw-child", workerW);
            return 1;
        }
    }

    // ---- 兜底：顶层窗口压底（已知会盖图标，仅保底不黑屏）
    EmbedLog(L"embed: toplevel fallback", progman);
    ApplyFallbackTopLevel(hwnd);
    return 1;
}

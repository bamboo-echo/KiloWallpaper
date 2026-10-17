// guard.c - DynamicWallpaper (C 版) 独立守护进程
// 独立进程名（DynamicWallpaperGuard.exe）：优化软件按进程名批量清理时，
// 只会命中 DynamicWallpaper.exe，守护存活即可在 1 秒内拉起主进程（改名隔离）。
// 协议文件（与主进程同目录）：
//   wallpaper.main.pid   主进程进程号
//   wallpaper.guard.pid  本守护进程号
//   wallpaper.ok         主进程初始化成功标记（守护据此决定是否保活）
//   wallpaper.graceful   主进程优雅退出标记（守护见之即退，不复活）
//   wallpaper.quit       关闭壁纸.bat 的关闭请求（由主进程消费）
// 编译：build.bat（输出 DynamicWallpaperGuard.exe，纯 Win32，无第三方依赖）

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static void GetSelfDir(wchar_t* out) {
    wchar_t exe[MAX_PATH] = {0};
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    wchar_t* slash = wcsrchr(exe, L'\\');
    if (slash) *slash = L'\0';
    wcscpy(out, exe);
}

static void WritePidFile(void) {
    // 先写临时文件再原子替换：直接 "w" 会先截断再写入，主进程可能在读到
    // 空文件的瞬间把守护误判为"已退出"而重复拉起（被单实例互斥挡回，无害但
    // 会丢 wallpaper.ok 语义）。MOVEFILE_WRITE_THROUGH 确保落盘。
    wchar_t dir[MAX_PATH]; GetSelfDir(dir);
    wchar_t tmp[MAX_PATH + 16];
    _snwprintf(tmp, MAX_PATH + 16, L"%s\\wallpaper.guard.pid.tmp", dir);
    {
        FILE* f = _wfopen(tmp, L"w");
        if (!f) return;
        fwprintf(f, L"%u", (unsigned)GetCurrentProcessId());
        fclose(f);
    }
    wchar_t dst[MAX_PATH + 16];
    _snwprintf(dst, MAX_PATH + 16, L"%s\\wallpaper.guard.pid", dir);
    MoveFileExW(tmp, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

static DWORD ReadPidFile(const wchar_t* name) {
    wchar_t dir[MAX_PATH]; GetSelfDir(dir);
    wchar_t p[MAX_PATH + 16];
    _snwprintf(p, MAX_PATH + 16, L"%s\\%s", dir, name);
    FILE* f = _wfopen(p, L"r");
    if (!f) return 0;
    wchar_t buf[32] = {0};
    fgetws(buf, 32, f);
    fclose(f);
    return (DWORD)_wtoi(buf);
}

static void DeleteFileIf(const wchar_t* name) {
    wchar_t dir[MAX_PATH]; GetSelfDir(dir);
    wchar_t p[MAX_PATH + 16];
    _snwprintf(p, MAX_PATH + 16, L"%s\\%s", dir, name);
    DeleteFileW(p);
}

static int FileExists(const wchar_t* name) {
    wchar_t dir[MAX_PATH]; GetSelfDir(dir);
    wchar_t p[MAX_PATH + 16];
    _snwprintf(p, MAX_PATH + 16, L"%s\\%s", dir, name);
    return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES;
}

// pid 进程的可执行文件是否位于本目录且名为 exeName
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

static void LaunchMain(void) {
    wchar_t dir[MAX_PATH]; GetSelfDir(dir);
    wchar_t exe[MAX_PATH];
    _snwprintf(exe, MAX_PATH, L"%s\\DynamicWallpaper.exe", dir);
    if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES) return;
    if (wcslen(exe) >= MAX_PATH) return;   // 与主进程侧同款超长保护
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

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE hPrev, LPWSTR cmdLine, int nCmdShow) {
    (void)hInst; (void)hPrev; (void)cmdLine; (void)nCmdShow;
    // 单实例：已有守护则退出（先启动者为主）
    HANDLE gm = CreateMutexW(NULL, TRUE, L"DynamicWallpaper_Guard");
    if (!gm || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
    WritePidFile();
    // 自身也注册重启管理器，防系统重启/连带终止后由系统恢复
    {
        typedef HRESULT(WINAPI* PFN_RegisterApplicationRestart)(PCWSTR, DWORD);
        PFN_RegisterApplicationRestart fnRAR = (PFN_RegisterApplicationRestart)GetProcAddress(
            GetModuleHandleW(L"kernel32.dll"), "RegisterApplicationRestart");
        if (fnRAR) fnRAR(L"", 0);
    }
    int justLaunched = 0;
    for (;;) {
        Sleep(1000);
        if (FileExists(L"wallpaper.graceful")) {   // 主进程已优雅退出 → 守护同退
            // 先确认主进程确实已退出再消费 graceful：否则"主进程存活但旧版
            // 留下的 graceful 文件还在"时，这里会把新主进程刚写的 wallpaper.ok
            // 一并删掉，导致该会话失去崩溃自愈（见 README 协议说明）。
            if (!IsOurProcess(ReadPidFile(L"wallpaper.main.pid"), L"DynamicWallpaper.exe")) {
                DeleteFileIf(L"wallpaper.graceful");
                DeleteFileIf(L"wallpaper.ok");
                return 0;
            }
            // 主进程仍活着：graceful 是残留，删掉继续保活
            DeleteFileIf(L"wallpaper.graceful");
            continue;
        }
        if (IsOurProcess(ReadPidFile(L"wallpaper.main.pid"), L"DynamicWallpaper.exe")) {
            justLaunched = 0;
            continue;                              // 主进程存活
        }
        // 主进程不在：从未成功初始化则不保活；刚拉起过一次又不见则停（防重启风暴）
        if (!FileExists(L"wallpaper.ok") || justLaunched) return 0;
        // ★ 不要在这里删 wallpaper.quit：它是"关闭壁纸.bat"写给主进程的关闭
        // 请求（主进程 ConsumeQuitSignal 消费）。守护代删会把用户的关闭请求吞掉，
        // 造成"关了又自己开"（壁纸被拉起、quit 已消失）。留下它，等主进程起来
        // 后正常消费即可。
        justLaunched = 1;
        DeleteFileIf(L"wallpaper.ok");
        LaunchMain();                              // 拉起主进程
    }
    return 0;
}

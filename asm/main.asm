; ============================================================
;  main.asm - KiloWallpaper (ASM 版) 静态图片壁纸
;
;  定位：五套实现里的「最小呈现路径」——纯 MASM x64 汇编，
;  零 CRT（不链 msvcrt/ucrt），只用 Win32 API + GDI+ flat API。
;
;  范围（与其他四套的差异，README 有完整说明）：
;    [x] 完整嵌入链路：0x052C 唤醒 -> Progman/DefView 主路径（双向 z 锚定）
;       -> WorkerW 备选 -> 顶层兜底；wallpaper.embed 策略标记
;    [x] DPI PER_MONITOR_AWARE_V2 建窗前设置
;    [x] wallpaper.txt 配置（exe 旁、UTF-8 容忍 BOM、只读首行、
;       相对路径按 exe 目录解析）+ 运行中改配置热切换图片
;    [x] wallpaper.quit -> wallpaper.graceful 优雅关闭握手
;    [x] debug.log（时间戳日志）+ [res] 周期资源快照（排查泄漏）
;    [-] 视频/GIF 动画（MF/D3D 在汇编里无意义，静态图 CPU 精确为 0）
;    [-] 独立守护进程（单进程自包含，看门狗内嵌）
;
;  编译：build.bat（ml64 + link，VS2017+ 即可）
;
;  * 实现注记：ML64 不支持 invoke 指令（实测 ml64 14.44 报
;    A2008 syntax error : invoke）。本文件全部调用手写 x64 调用约定：
;      - <=4 参数：CALLV 宏（mov rcx/rdx/r8/r9 + call）
;      - >4 参数：专用 helper（全局参数槽 + 手写栈布局，不碰 local）
; ============================================================

option casemap:none

; ---------------- 外部函数 ----------------
extern ExitProcess:proc
extern GetModuleHandleW:proc
extern GetCurrentProcess:proc
extern SetProcessDpiAwarenessContext:proc
extern GetEnvironmentVariableW:proc
extern GetTickCount:proc
extern GetLocalTime:proc
extern Sleep:proc
extern lstrcmpW:proc
extern lstrcpyW:proc
extern DeleteFileW:proc
extern GetFileAttributesW:proc
extern GetModuleFileNameW:proc
extern MultiByteToWideChar:proc
extern GetProcessMemoryInfo:proc
extern GetProcessHandleCount:proc
extern GetGuiResources:proc
extern GetStockObject:proc
extern LoadCursorW:proc
extern DefWindowProcW:proc
extern GetMessageW:proc
extern TranslateMessage:proc
extern DispatchMessageW:proc
extern PostQuitMessage:proc
extern IsWindow:proc
extern GetParent:proc
extern GetAncestor:proc
extern GetClassNameW:proc
extern GetClientRect:proc
extern GetWindowRect:proc
extern GetSystemMetrics:proc
extern BeginPaint:proc
extern EndPaint:proc
extern InvalidateRect:proc
extern RedrawWindow:proc
extern KillTimer:proc
extern SetTimer:proc
extern FindWindowW:proc
extern FindWindowExW:proc
extern EnumWindows:proc
extern GetWindowLongPtrW:proc
extern SetWindowLongPtrW:proc
extern SetLayeredWindowAttributes:proc
extern SetParent:proc
extern SetFilePointer:proc
extern CloseHandle:proc
extern CreateFileW:proc
extern ReadFile:proc
extern WriteFile:proc
extern wsprintfW:proc
extern RegisterClassExW:proc
extern CreateWindowExW:proc
extern SendMessageTimeoutW:proc
extern SetWindowPos:proc
extern GdiplusStartup:proc
extern GdiplusShutdown:proc
extern GdipLoadImageFromFile:proc
extern GdipDisposeImage:proc
extern GdipCreateFromHDC:proc
extern GdipDeleteGraphics:proc
extern GdipDrawImageRectI:proc

; ---------------- 常量 ----------------
WS_CHILD            equ 040000000h
WS_VISIBLE          equ 010000000h
WS_POPUP            equ 080000000h
WS_CAPTION          equ 0C000000h
WS_THICKFRAME       equ 000040000h
WS_SYSMENU          equ 000080000h
WS_EX_LAYERED       equ 000080000h
WS_EX_NOACTIVATE    equ 008000000h
WS_EX_TOPMOST       equ 000000008h
WS_EX_TOOLWINDOW    equ 000000080h
GWL_STYLE           equ -16
GWL_EXSTYLE         equ -20
LWA_ALPHA           equ 2
SWP_NOSIZE          equ 1
SWP_NOMOVE          equ 2
SWP_NOZORDER        equ 4
SWP_NOACTIVATE      equ 16
SWP_SHOWWINDOW      equ 40
SWP_FRAMECHANGED    equ 20
SMTO_NORMAL         equ 0
RDW_INVALIDATE      equ 1
RDW_UPDATENOW       equ 100
WM_DESTROY          equ 2
WM_PAINT            equ 0Fh
WM_TIMER            equ 113h
WM_DISPLAYCHANGE    equ 7Eh
HWND_BOTTOM         equ 1
TIMER_WATCHDOG      equ 1
WATCHDOG_MS         equ 3000
SM_CXSCREEN         equ 0
SM_CYSCREEN         equ 1
IDC_ARROW           equ 32512
BLACK_BRUSH         equ 4
CP_UTF8             equ 65001
INVALID_HANDLE_VALUE equ -1
INVALID_FILE_ATTRIBUTES equ -1
GENERIC_READ        equ 080000000h
GENERIC_WRITE       equ 040000000h
FILE_SHARE_READ     equ 1
FILE_SHARE_WRITE    equ 2
OPEN_EXISTING       equ 3
CREATE_ALWAYS       equ 2
FILE_ATTRIBUTE_NORMAL equ 80
FILE_END            equ 2
GR_GDIOBJECTS       equ 0
GR_USEROBJECTS      equ 1
PER_MONITOR_V2      equ -4
GA_ROOT             equ 2

; ---------------- 数据 ----------------
.data
g_hInst         qword 0
g_hSelf         qword 0
g_hwnd          qword 0
g_host          qword 0
g_parent        qword 0
g_defView       qword 0
g_workerW       qword 0
g_img           qword 0
g_backupImg     qword 0
g_token         qword 0
g_winW          dword 0
g_winH          dword 0
g_locked        dword 0
g_lastRaise     dword 0
g_resStart      dword 0
g_resLast       dword 0
g_resInterval   dword 60000
g_resInit       dword 0
g_resSec        dword 0          ; [res] uptime 秒（div 商中转，避免被 rax 复用覆盖）
g_enumFound     qword 0
g_enumProgman   qword 0
g_cbHwnd        qword 0          ; EnumWindows 回调入口保存的 rcx（hwnd），防 API 调用后易失寄存器失效
g_cbLParam      qword 0          ; EnumWindows 回调入口保存的 rdx（lParam）
g_threshW       dword 0          ; FindWallpaperWorkerW 尺寸阈值：主屏宽×9
g_threshH       dword 0          ; FindWallpaperWorkerW 尺寸阈值：主屏高×9
g_fwwPrev       qword 0          ; FindWindowExW 子窗口遍历游标
g_fwwCur        qword 0          ; FindWallpaperWorkerW 当前候选
g_fwwRect       byte 32 dup (0)  ; FindWallpaperWorkerW 的 GetWindowRect 缓冲
g_msg           byte 64 dup (0)
g_wndcls        byte 88 dup (0)
g_scratchW      word 32 dup (0)
g_curMedia      word 260 dup (0)
g_failed        word 260 dup (0)

; helper 全局参数槽（>4 参数 API 用）
g_a1 qword 0
g_a2 qword 0
g_a3 qword 0
g_a4 qword 0
g_a5 qword 0
g_a6 qword 0
g_a7 qword 0
g_a8 qword 0
g_a9 qword 0
g_a10 qword 0
g_a11 qword 0
g_a12 qword 0

; ---- 原局部变量（单线程，全局化，彻底避开 ML64 帧问题）----
g_cfg word 520 dup (0)
g_gdi dword 0
g_h dword 0
g_handles dword 0
g_lGfx qword 0
g_lParent qword 0
g_lRoot qword 0
g_lStrategy qword 0
g_lWorker qword 0
g_ldefView qword 0
g_line word 320 dup (0)
g_resBuf word 320 dup (0)      ; [res] 快照专用：wsprintfW 目的地，勿与 g_line 混用
                                 ; （曾因同用 g_line，LogLine 自引用复制出时间戳无限重复）
g_lmsg qword 0
g_now dword 0
g_nread dword 0
g_readOk dword 0
g_path word 520 dup (0)
g_pathPtr qword 0
g_pcls word 80 dup (0)
g_pmc byte 96 dup (0)
g_pr byte 32 dup (0)
g_progman qword 0
g_ps byte 128 dup (0)
g_raw byte 1024 dup (0)
g_rc byte 32 dup (0)
g_rmbuf qword 0
g_shadow byte 32 dup (0)
g_stt byte 16 dup (0)
g_tag qword 0
g_usr dword 0
g_w dword 0
g_want word 520 dup (0)
g_wmbuf word 64 dup (0)
g_written dword 0
g_exedir word 520 dup (0)          ; exe 目录（含结尾 '\'），start 时算一次
g_pathbuf word 520 dup (0)         ; 拼接缓冲：g_exedir + 裸文件名（JoinExeDir 输出）

wcName          dw 'D','y','n','a','m','i','c','W','a','l','l','p','a','p','e','r'
                 dw 0
clsProgman      dw 'P','r','o','g','m','a','n'
                 dw 0
clsDefView      dw 'S','H','E','L','L','D','L','L','_','D','e','f','V','i','e','w'
                 dw 0
clsWorkerW      dw 'W','o','r','k','e','r','W'
                 dw 0
clsListView     dw 'S','y','s','L','i','s','t','V','i','e','w','3','2'
                 dw 0
clsDirectUI     dw 'D','i','r','e','c','t','U','I','H','W','N','D'
                 dw 0

szCfgName       dw 'w','a','l','l','p','a','p','e','r','.','t','x','t'
                 dw 0
szLogName       dw 'd','e','b','u','g','.','l','o','g'
                 dw 0
szQuitName      dw 'w','a','l','l','p','a','p','e','r','.','q','u','i','t'
                 dw 0
szGracefulName  dw 'w','a','l','l','p','a','p','e','r','.','g','r','a','c','e','f'
                 dw 'u','l'
                 dw 0
szEmbedName     dw 'w','a','l','l','p','a','p','e','r','.','e','m','b','e','d'
                 dw 0
szEnvRes        dw 'K','W','_','R','E','S','_','L','O','G','_','M','S'
                 dw 0

szTagEmbed      dw '[','e','m','b','e','d',']'
                 dw 0
szTagRes        dw '[','r','e','s',']'
                 dw 0

szEmbedProgman  dw 'e','m','b','e','d',':',' ','p','r','o','g','m','a','n','-','l'
                 dw 'a','y','e','r','e','d',' ','a','n','c','h','o','r'
                 dw 0
szEmbedWorker   dw 'e','m','b','e','d',':',' ','c','l','a','s','s','i','c',' ','w'
                 dw 'o','r','k','e','r','w','-','c','h','i','l','d'
                 dw 0
szEmbedTop      dw 'e','m','b','e','d',':',' ','t','o','p','l','e','v','e','l',' '
                 dw 'f','a','l','l','b','a','c','k'
                 dw 0
szZorderFailed  dw 'z','o','r','d','e','r',':',' ','a','n','c','h','o','r',' ','F'
                 dw 'A','I','L','E','D'
                 dw 0
szReloadOk      dw 'r','e','l','o','a','d','-','o','k'
                 dw 0
szNoImage       dw 'n','o',' ','i','m','a','g','e',' ','l','o','a','d','e','d'
                 dw 0

szTailFmt       dw ' ','h','r','=','0','x','0','0','0','0','0','0','0','0'
                 dw 0Ah, 0
szResFmt        dw 'u','p','t','i','m','e','=','%','l','u','s',' ','w','s','=','%'
                 dw 'u','M','B',' ','c','o','m','m','i','t','=','%','u','M','B',' '
                 dw 'p','e','a','k','w','s','=','%','u','M','B',' ','h','a','n','d'
                 dw 'l','e','s','=','%','l','u',' ','g','d','i','=','%','l','u',' '
                 dw 'u','s','e','r','=','%','l','u'
                 dw 0

gdipInput       dword 1
                dword 0
                qword 0
                dword 0
                dword 0

; ---------------- 调用宏 ----------------
; CALLV fn, a1..a4 —— <=4 参数：寄存器直传 + call。
; 调用方需保证 rsp 16 字节对齐（函数入口已 sub rsp,28h）。
; 参数须为 64 位兼容表达式（offset/addr/全局 qword/64 位寄存器/立即数）。
CALLV MACRO fn:REQ, a1, a2, a3, a4
    IFNB <a1>
        mov rcx, a1
    ENDIF
    IFNB <a2>
        mov rdx, a2
    ENDIF
    IFNB <a3>
        mov r8, a3
    ENDIF
    IFNB <a4>
        mov r9, a4
    ENDIF
    call fn
ENDM

; WCHR2 - 写一个宽字符并推进 rdi
WCHR2 MACRO c:REQ
    mov word ptr [rdi], c
    add rdi, 2
ENDM

; ---------------- 代码 ----------------
.code

; ============================================================
; helper：多参数 API（ML64 无 invoke，手写栈布局）
;   模式：sub rsp, 20h+N*8（16 对齐）-> 寄存器 4 参 + [rsp+20h] 起栈参
;   -> call -> add rsp 恢复 -> ret。全部用全局参数槽，无 local。
; ============================================================

HRegisterClassEx PROC
    sub rsp, 28h
    mov rcx, g_a1
    call RegisterClassExW
    add rsp, 28h
    ret
HRegisterClassEx ENDP

HCreateWindowEx PROC                  ; 12 参
    sub rsp, 68h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    mov rax, g_a7
    mov [rsp+30h], rax
    mov rax, g_a8
    mov [rsp+38h], rax
    mov rax, g_a9
    mov [rsp+40h], rax
    mov rax, g_a10
    mov [rsp+48h], rax
    mov rax, g_a11
    mov [rsp+50h], rax
    mov rax, g_a12
    mov [rsp+58h], rax
    call CreateWindowExW
    add rsp, 68h
    ret
HCreateWindowEx ENDP

HSendMessageTimeout PROC              ; 7 参
    sub rsp, 48h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    mov rax, g_a7
    mov [rsp+30h], rax
    call SendMessageTimeoutW
    add rsp, 48h
    ret
HSendMessageTimeout ENDP

HSetWindowPos PROC                    ; 7 参
    sub rsp, 48h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    mov rax, g_a7
    mov [rsp+30h], rax
    call SetWindowPos
    add rsp, 48h
    ret
HSetWindowPos ENDP

HCreateFile PROC                       ; 7 参
    sub rsp, 48h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    mov rax, g_a7
    mov [rsp+30h], rax
    call CreateFileW
    add rsp, 48h
    ret
HCreateFile ENDP

; ------------------------------------------------------------
; JoinExeDir - 裸文件名 → exe 目录下的完整路径
; 输入：rcx = 裸文件名宽串指针
; 输出：rax = g_pathbuf（g_exedir + 文件名；g_exedir 含结尾 '\'）
; 说明：debug.log / wallpaper.embed / wallpaper.quit / wallpaper.graceful
;       共用。启动时已算好 g_exedir，整个目录随便搬到哪都不会失联，
;       不再依赖当前工作目录（项目约定，与 ResolveMediaPath 一致）。
; ------------------------------------------------------------
JoinExeDir PROC
    push rsi
    push rdi
    lea rsi, g_exedir
    lea rdi, g_pathbuf
jed_dir:
    movzx eax, word ptr [rsi]
    mov [rdi], ax
    test eax, eax
    jz jed_name
    add rsi, 2
    add rdi, 2
    jmp jed_dir
jed_name:
    mov rsi, rcx
jed_n2:
    movzx eax, word ptr [rsi]
    mov [rdi], ax
    test eax, eax
    jz jed_done
    add rsi, 2
    add rdi, 2
    jmp jed_n2
jed_done:
    lea rax, g_pathbuf
    pop rdi
    pop rsi
    ret
JoinExeDir ENDP

HReadFile PROC                         ; 5 参
    sub rsp, 28h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    call ReadFile
    add rsp, 28h
    ret
HReadFile ENDP

HWriteFile PROC                        ; 5 参
    sub rsp, 28h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    call WriteFile
    add rsp, 28h
    ret
HWriteFile ENDP

HMultiByteToWideChar PROC              ; 6 参
    sub rsp, 38h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    call MultiByteToWideChar
    add rsp, 38h
    ret
HMultiByteToWideChar ENDP

HGdipDrawImageRect PROC                ; 6 参
    sub rsp, 38h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    call GdipDrawImageRectI
    add rsp, 38h
    ret
HGdipDrawImageRect ENDP

HWsprintfRes PROC                      ; 9 参（dest, fmt, uptime, ws, commit, peak, handles, gdi, user）
    sub rsp, 48h                ; 20h 影子 + 5×8 栈参 = 48h；48 ≡ 8 → call 点 rsp ≡ 0 ✓（原 50h 会 misalign）
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    mov rax, g_a6
    mov [rsp+28h], rax
    mov rax, g_a7
    mov [rsp+30h], rax
    mov rax, g_a8
    mov [rsp+38h], rax
    mov rax, g_a9
    mov [rsp+40h], rax
    call wsprintfW
    add rsp, 48h
    ret
HWsprintfRes ENDP

; ============================================================
; start - 入口
; ============================================================
start PROC
    sub rsp, 28h

    ; 1) DPI 必须在建窗前设 PER_MONITOR_AWARE_V2
    mov rcx, PER_MONITOR_V2
    call SetProcessDpiAwarenessContext
    CALLV GetModuleHandleW, 0
    mov g_hInst, rax
    CALLV GetCurrentProcess
    mov g_hSelf, rax

    ; 1b) exe 目录（含结尾 '\'）算一次：debug.log / wallpaper.embed /
    ;     quit 握手全部基于它，不再依赖当前工作目录——目录随便搬到哪
    ;     都不会失联（项目约定，与 ResolveMediaPath 同一套路）
    lea rax, g_exedir
    CALLV GetModuleFileNameW, 0, rax, 520
    lea rdi, g_exedir
    lea rsi, g_exedir
    mov ecx, 260
ed_find:
    movzx eax, word ptr [rdi]
    test eax, eax
    jz ed_found
    cmp eax, '\'
    jne ed_next
    mov rsi, rdi
ed_next:
    add rdi, 2
    loop ed_find
ed_found:
    add rsi, 2
    mov word ptr [rsi], 0          ; 截到最后一个 '\'（保留），后面拼文件名

    ; 2) KW_RES_LOG_MS 环境变量（0=关闭）
    lea rax, szEnvRes
    lea r10, g_scratchW
    CALLV GetEnvironmentVariableW, rax, r10, 32
    test eax, eax
    jz skip_env
    lea r11, g_scratchW
    xor r10d, r10d
env_loop:
    movzx eax, word ptr [r11]
    cmp eax, '0'
    jb env_done
    cmp eax, '9'
    ja env_done
    imul r10d, r10d, 10
    sub eax, '0'
    add r10d, eax
    add r11, 2
    jmp env_loop
env_done:
    mov g_resInterval, r10d
skip_env:

    ; 3) GDI+ 启动
    lea rax, g_token
    lea r10, gdipInput
    CALLV GdiplusStartup, rax, r10, 0
    test eax, eax
    jnz fail_exit

    ; 4) 读配置加载素材
    call LoadConfiguredImage
    test eax, eax
    jz log_noimage

    ; 5) 注册类 + 建窗 + 嵌入
    call RegisterWallpaperClass     ; 先填 g_wndcls（早期漏了这步，cbSize=0 必失败）
    lea rax, g_wndcls
    mov g_a1, rax
    call HRegisterClassEx
    test ax, ax                  ; ATOM 是 16 位；test eax 可能被高位垃圾误判
    jz fail_exit
    call CreateWallpaperWindow
    test eax, eax
    jz fail_exit
    mov rax, g_hwnd              ; g_host 必须指向真实窗口：SetTimer 的 owner 决定
    mov g_host, rax              ; WM_TIMER 去向（原 g_host 恒 0 = 线程定时器，消息到不了 WndProc）
    CALLV EmbedOrFallback, g_hwnd

    ; 6) 看门狗
    CALLV SetTimer, g_host, TIMER_WATCHDOG, WATCHDOG_MS, 0

    ; 7) 首帧 + 消息循环
    CALLV InvalidateRect, g_hwnd, 0, 0
msg_loop:
    lea rax, g_msg
    CALLV GetMessageW, rax, 0, 0, 0
    test eax, eax
    jz msg_end
    lea rax, g_msg
    CALLV TranslateMessage, rax
    lea rax, g_msg
    CALLV DispatchMessageW, rax
    jmp msg_loop
msg_end:

    ; 8) 清理
    CALLV KillTimer, g_host, TIMER_WATCHDOG
    CALLV GdiplusShutdown, g_token
    CALLV ExitProcess, 0

log_noimage:
    lea rax, szNoImage
    mov g_a1, rax
    call EmbedLog
    CALLV GdiplusShutdown, g_token
    CALLV ExitProcess, 1

fail_exit:
    CALLV ExitProcess, 2
start ENDP

; ============================================================
; RegisterWallpaperClass
; ============================================================
RegisterWallpaperClass PROC
    sub rsp, 28h
    mov byte ptr g_wndcls[0], 80
    mov byte ptr g_wndcls[4], 3
    lea rax, WndProc
    mov qword ptr g_wndcls[8], rax
    mov byte ptr g_wndcls[16], 0
    mov byte ptr g_wndcls[20], 0
    mov rax, g_hInst
    mov qword ptr g_wndcls[24], rax
    mov g_wndcls[32], 0
    CALLV LoadCursorW, 0, IDC_ARROW
    mov qword ptr g_wndcls[40], rax
    CALLV GetStockObject, BLACK_BRUSH
    mov qword ptr g_wndcls[48], rax
    mov g_wndcls[56], 0
    lea rax, wcName
    mov qword ptr g_wndcls[64], rax
    mov g_wndcls[72], 0
    mov eax, 1
    add rsp, 28h
    ret
RegisterWallpaperClass ENDP

; ============================================================
; CreateWallpaperWindow
; ============================================================
CreateWallpaperWindow PROC
    sub rsp, 28h
    CALLV GetSystemMetrics, SM_CXSCREEN
    mov r11d, eax
    CALLV GetSystemMetrics, SM_CYSCREEN
    mov r10d, eax
    mov rax, WS_EX_TOOLWINDOW
    mov g_a1, rax
    lea rax, wcName
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov eax, WS_POPUP            ; 对齐 C++：创建时不可见，嵌入时经 SWP_SHOWWINDOW 显示，
    mov g_a4, rax                ; 避免启动瞬间全屏黑窗闪一下
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov rax, r11
    mov g_a7, rax
    mov rax, r10
    mov g_a8, rax
    mov rax, 0
    mov g_a9, rax
    mov rax, 0
    mov g_a10, rax
    mov rax, g_hInst
    mov g_a11, rax
    mov rax, 0
    mov g_a12, rax
    call HCreateWindowEx
    test rax, rax
    jz cw_done
    mov g_hwnd, rax
    mov eax, 1
cw_done:
    add rsp, 28h
    ret
CreateWallpaperWindow ENDP

; ============================================================
; WndProc
; ============================================================
WndProc PROC
    sub rsp, 28h
    mov r10, rcx
    mov r11, rdx
    cmp r11, WM_PAINT
    je wp_paint
    cmp r11, WM_TIMER
    je wp_timer
    cmp r11, WM_DESTROY
    je wp_destroy
    cmp r11, WM_DISPLAYCHANGE
    je wp_display
    CALLV DefWindowProcW, rcx, rdx, r8, r9
    jmp wp_done
wp_paint:
    call PaintImage
    xor eax, eax
    jmp wp_done
wp_timer:
    call WatchdogTick
    xor eax, eax
    jmp wp_done
wp_display:
    CALLV FitToParentOrMonitor, g_hwnd
    CALLV InvalidateRect, g_hwnd, 0, 0
    xor eax, eax
    jmp wp_done
wp_destroy:
    CALLV PostQuitMessage, 0
    xor eax, eax
wp_done:
    add rsp, 28h
    ret
WndProc ENDP

; ============================================================
; PaintImage - WM_PAINT
; ============================================================
PaintImage PROC
    push rbx                    ; rbx 非易失，本函数借用存 HDC 需保存
    sub rsp, 30h                ; 1 push(8) + 48 = 56 ≡ 8 (mod 16)，call 点对齐 ✓




    cmp g_img, 0
    je pi_nopaint
    lea rax, g_rc
    CALLV GetClientRect, g_hwnd, rax
    lea rax, g_ps
    CALLV BeginPaint, g_hwnd, rax
    test rax, rax
    jz pi_done
    mov rbx, rax
    lea rax, g_lGfx
    CALLV GdipCreateFromHDC, rbx, rax
    test eax, eax
    jnz pi_end
    cmp g_lGfx, 0
    je pi_end
    mov eax, dword ptr g_rc[8]
    sub eax, dword ptr g_rc[0]
    mov r11d, eax
    mov eax, dword ptr g_rc[12]                 ; bottom（RECT=16 字节：left@0/top@4/right@8/bottom@12）
    sub eax, dword ptr g_rc[4]                  ; top → 高度（原错读 [24]/[16] 越界，高度恒 0）
    mov r10d, eax
    mov rax, g_lGfx
    mov g_a1, rax
    mov rax, g_img
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, r11
    mov g_a5, rax
    mov rax, r10
    mov g_a6, rax
    call HGdipDrawImageRect
    CALLV GdipDeleteGraphics, g_lGfx
pi_end:
    lea rax, g_ps
    CALLV EndPaint, g_hwnd, rax
    jmp pi_done
pi_nopaint:
    lea rax, g_ps
    CALLV BeginPaint, g_hwnd, rax
    lea rax, g_ps
    CALLV EndPaint, g_hwnd, rax
pi_done:
    add rsp, 30h
    pop rbx
    ret
PaintImage ENDP

; ============================================================
; LoadConfiguredImage
; ============================================================
LoadConfiguredImage PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间


    lea rcx, g_path
    call ResolveMediaPath
    test eax, eax
    jz lci_done0
    lea rcx, g_path
    call LoadImageFile
    test eax, eax
    jz lci_done0
    mov eax, 1
    jmp lci_done
lci_done0:
    xor eax, eax
lci_done:
    add rsp, 28h
    ret
LoadConfiguredImage ENDP

; ============================================================
; LoadImageFile(path)
; ============================================================
LoadImageFile PROC
    push rsi                    ; rsi/rdi 非易失（x64 Windows ABI），本函数借用需保存
    push rdi
    sub rsp, 28h                ; 2 push(16) + 40 = 56 ≡ 8 (mod 16)，call 点对齐 ✓

    mov g_pathPtr, rcx
    cmp g_img, 0
    je lif_load
    CALLV GdipDisposeImage, g_img
    mov g_img, 0
lif_load:
    lea rax, g_img
    CALLV GdipLoadImageFromFile, g_pathPtr, rax
    test eax, eax
    jnz lif_fail
    cmp g_img, 0
    je lif_fail
    mov rsi, g_pathPtr
    lea rdi, g_curMedia
    mov ecx, 259
    rep movsw
    mov word ptr [rdi], 0
    mov eax, 1
    jmp lif_done
lif_fail:
    xor eax, eax
lif_done:
    add rsp, 28h
    pop rdi
    pop rsi
    ret
LoadImageFile ENDP

; ============================================================
; ResolveMediaPath(buf)
; ============================================================
ResolveMediaPath PROC
    push rsi                    ; rsi/rdi/rbx 均非易失，本函数借用需保存
    push rdi
    push rbx
    sub rsp, 30h                ; 3 push(24) + 48 = 72 ≡ 8 → 内部 call 点 rsp ≡ 0 ✓





    mov g_rmbuf, rcx
    ; ---- exe 目录 + wallpaper.txt ----
    lea rax, g_cfg
    CALLV GetModuleFileNameW, 0, rax, 520
    lea rdi, g_cfg
    lea rsi, g_cfg
    mov ecx, 260
rms_find:
    movzx eax, word ptr [rdi]
    test eax, eax
    jz rms_found
    cmp eax, '\'
    jne rms_next
    mov rsi, rdi
rms_next:
    add rdi, 2
    loop rms_find
rms_found:
    add rsi, 2
    lea rdi, szCfgName
    mov ecx, 13
rms_copy:
    movzx eax, word ptr [rdi]
    mov [rsi], ax
    add rsi, 2
    add rdi, 2
    loop rms_copy
    mov word ptr [rsi], 0
    ; ---- 打开读取 ----
    lea rax, g_cfg
    mov g_a1, rax
    mov eax, GENERIC_READ
    mov g_a2, rax
    mov rax, FILE_SHARE_READ or FILE_SHARE_WRITE
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, OPEN_EXISTING
    mov g_a5, rax
    mov rax, FILE_ATTRIBUTE_NORMAL
    mov g_a6, rax
    mov rax, 0
    mov g_a7, rax
    call HCreateFile
    cmp rax, INVALID_HANDLE_VALUE
    je rms_empty
    mov rbx, rax
    mov rax, rbx
    mov g_a1, rax
    lea rax, g_raw
    mov g_a2, rax
    mov rax, 1023
    mov g_a3, rax
    lea rax, g_nread
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    call HReadFile
    mov g_readOk, eax          ; 保存返回值（push/pop 会破坏 rsp 16 对齐）
    CALLV CloseHandle, rbx
    mov eax, g_readOk
    test eax, eax
    jz rms_empty
    mov ecx, g_nread
    test ecx, ecx
    jz rms_empty
    lea rsi, g_raw
    mov byte ptr [rsi+rcx], 0
    ; ---- 跳过 UTF-8 BOM ----
    lea rsi, g_raw
    cmp byte ptr [rsi], 0EFh
    jne rms_convert
    cmp byte ptr [rsi+1], 0BBh
    jne rms_convert
    cmp byte ptr [rsi+2], 0BFh
    jne rms_convert
    add rsi, 3
rms_convert:
    ; ---- 截到行尾 ----
    mov rdi, rsi
rms_scan:
    movzx eax, byte ptr [rdi]
    test al, al
    jz rms_scandone
    cmp al, 0Dh
    je rms_scandone
    cmp al, 0Ah
    je rms_scandone
    inc rdi
    jmp rms_scan
rms_scandone:
    mov byte ptr [rdi], 0
    ; ---- 去尾部空格 ----
rms_trim:
    cmp rdi, rsi
    jbe rms_conv2
    movzx eax, byte ptr [rdi-1]
    cmp al, ' '
    jne rms_conv2
    dec rdi
    mov byte ptr [rdi], 0
    jmp rms_trim
rms_conv2:
    sub rsp, 40h                ; 2 个栈参数 + 影子（40h 保持 16 对齐）
    mov rcx, CP_UTF8
    mov rdx, 0
    mov r8, rsi
    mov r9, -1
    mov rax, g_rmbuf             ; 指针值加载（= 输出缓冲地址）；勿用 lea——g_rmbuf 是指针变量
    mov [rsp+20h], rax
    mov rax, 520
    mov [rsp+28h], rax
    call MultiByteToWideChar
    mov g_readOk, eax
    add rsp, 40h
    mov eax, g_readOk
    test eax, eax
    jz rms_empty
    ; ---- 内容检查统一经指针读（调用方可能是 g_path 也可能是 g_want）----
    mov r10, g_rmbuf
    movzx eax, word ptr [r10]
    test eax, eax
    jz rms_empty
    ; ---- 相对路径 -> 绝对 ----
    movzx eax, word ptr [r10]
    cmp eax, '\'
    je rms_done
    cmp eax, 'A'
    jb rms_relpath
    cmp eax, 'Z'
    ja rms_relpath
    movzx ecx, word ptr [r10+2]  ; 第二个宽字符：X:/ 形式冒号在索引 1（字节偏移 2）
    cmp ecx, ':'
    je rms_done
rms_relpath:
    ; g_cfg 当前内容 = "exe目录\wallpaper.txt"（开头拼接的结果），
    ; 无需再次 GetModuleFileNameW：把文件名部分直接覆写为相对路径。
    lea rdi, g_cfg
    mov ecx, 260
rms_fs2:
    movzx eax, word ptr [rdi]
    test eax, eax
    jz rms_fs2done
    cmp eax, '\'
    jne rms_fs2next
    mov r8, rdi
rms_fs2next:
    add rdi, 2
    loop rms_fs2
rms_fs2done:
    add r8, 2
    mov r9, g_rmbuf              ; 源 = 指针值
rms_cp2:
    movzx eax, word ptr [r9]
    mov [r8], ax
    add r8, 2
    add r9, 2
    test eax, eax
    jnz rms_cp2
    lea rsi, g_cfg
    mov rdi, g_rmbuf             ; 目的 = 指针值
    mov ecx, 260
    rep movsw
    mov word ptr [rdi], 0
rms_done:
    mov eax, 1
    jmp rms_ret
rms_empty:
    xor eax, eax
rms_ret:
    add rsp, 30h
    pop rbx
    pop rdi
    pop rsi
    ret
ResolveMediaPath ENDP

; ============================================================
; EmbedOrFallback
; ============================================================
EmbedOrFallback PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间






    call FindProgman
    mov g_progman, rax
    test rax, rax
    jz ef_noProgman
    mov g_a1, rax
    mov rax, 052Ch
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, SMTO_NORMAL
    mov g_a5, rax
    mov rax, 1000
    mov g_a6, rax
    mov rax, 0
    mov g_a7, rax
    call HSendMessageTimeout
ef_noProgman:
    CALLV Sleep, 120

    ; ---- 主路径 ----
    cmp g_progman, 0
    je ef_noMain
    lea rax, clsDefView
    CALLV FindWindowExW, g_progman, 0, rax, 0
    mov g_ldefView, rax
    test rax, rax
    jnz ef_haveDV
    CALLV Sleep, 150
    lea rax, clsDefView
    CALLV FindWindowExW, g_progman, 0, rax, 0
    mov g_ldefView, rax
    test rax, rax
    jz ef_noMain
ef_haveDV:
    CALLV IsWindow, g_ldefView
    test eax, eax
    jz ef_noMain
    CALLV GetWindowLongPtrW, g_hwnd, GWL_STYLE
    mov r10, not (WS_POPUP or WS_CAPTION or WS_THICKFRAME or WS_SYSMENU)
    and rax, r10
    or rax, WS_CHILD or WS_VISIBLE
    CALLV SetWindowLongPtrW, g_hwnd, GWL_STYLE, rax
    CALLV GetWindowLongPtrW, g_hwnd, GWL_EXSTYLE
    or rax, WS_EX_LAYERED or WS_EX_NOACTIVATE   ; LAYERED 是 raised desktop 上 Progman
    and rax, not WS_EX_TOPMOST                   ; 子窗口能被 DWM 合成的必要条件（C++ 主路径
    CALLV SetWindowLongPtrW, g_hwnd, GWL_EXSTYLE, rax   ; 同款；曾误删导致壁纸根本不渲染）
    CALLV SetLayeredWindowAttributes, g_hwnd, 0, 255, LWA_ALPHA
    CALLV SetParent, g_hwnd, g_progman
    test eax, eax
    jz ef_noMain
    mov rax, g_progman
    mov g_parent, rax
    mov rax, g_ldefView
    mov g_defView, rax
    mov rcx, g_progman          ; FindWallpaperWorkerW 从 rcx 取参（原来错给 rax）
    call FindWallpaperWorkerW
    mov g_workerW, rax
    lea rax, g_pr
    CALLV GetClientRect, g_progman, rax
    mov eax, dword ptr g_pr[8]
    sub eax, dword ptr g_pr[0]
    mov g_w, eax
    mov eax, dword ptr g_pr[12]                 ; bottom（RECT=16 字节：left@0/top@4/right@8/bottom@12）
    sub eax, dword ptr g_pr[4]                  ; top → 高度（原错读 [24]/[16] 越界，高度恒 0）
    mov g_h, eax
    cmp g_w, 0
    jg ef_sizeOk
    cmp g_h, 0
    jg ef_sizeOk
    CALLV GetSystemMetrics, SM_CXSCREEN
    mov g_w, eax
    CALLV GetSystemMetrics, SM_CYSCREEN
    mov g_h, eax
ef_sizeOk:
    mov eax, g_w
    mov g_winW, eax
    mov eax, g_h
    mov g_winH, eax
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, 0
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov eax, g_w
    mov g_a5, rax
    mov eax, g_h
    mov g_a6, rax
    mov rax, SWP_NOZORDER or SWP_NOACTIVATE or SWP_SHOWWINDOW
    mov g_a7, rax
    call HSetWindowPos
    CALLV EnsureWallpaperZOrder, g_hwnd
    CALLV RedrawWindow, g_hwnd, 0, 0, RDW_INVALIDATE or RDW_UPDATENOW
    lea rax, szEmbedProgman
    mov g_a1, rax
    call EmbedLog
    lea rax, szEmbedProgman
    mov g_a1, rax
    call WriteEmbedMarker
    jmp ef_done
ef_noMain:

    ; ---- 备选：WorkerW ----
    call FindWorkerAfterIconWorker
    test rax, rax
    jnz ef_haveWorker
    cmp g_progman, 0
    je ef_noWorker
    mov rax, g_progman
    mov g_a1, rax
    mov rax, 052Ch
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, SMTO_NORMAL
    mov g_a5, rax
    mov rax, 1000
    mov g_a6, rax
    mov rax, 0
    mov g_a7, rax
    call HSendMessageTimeout
    CALLV Sleep, 150
    call FindWorkerAfterIconWorker
ef_haveWorker:
    test rax, rax
    jz ef_noWorker
    mov r10, rax
    CALLV AttachToWorkerW, g_hwnd, r10
    test eax, eax
    jz ef_noWorker
    mov g_defView, 0
    mov g_workerW, 0
    lea rax, szEmbedWorker
    mov g_a1, rax
    call EmbedLog
    lea rax, szEmbedWorker
    mov g_a1, rax
    call WriteEmbedMarker
    jmp ef_done
ef_noWorker:

    ; ---- 兜底：顶层 ----
    lea rax, szEmbedTop
    mov g_a1, rax
    call EmbedLog
    lea rax, szEmbedTop
    mov g_a1, rax
    call WriteEmbedMarker
    call ApplyFallbackTopLevel
ef_done:
    mov eax, 1
    add rsp, 28h
    ret
EmbedOrFallback ENDP

; ============================================================
; AttachToWorkerW(hwnd, worker)
; ============================================================
AttachToWorkerW PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间





    mov g_lWorker, rdx          ; 调用方 CALLV AttachToWorkerW, g_hwnd, r10 → worker 在 rdx（原错读 r8）
    CALLV GetWindowLongPtrW, g_hwnd, GWL_STYLE
    mov r10, not (WS_POPUP or WS_CAPTION or WS_THICKFRAME)
    and rax, r10
    or rax, WS_CHILD or WS_VISIBLE
    CALLV SetWindowLongPtrW, g_hwnd, GWL_STYLE, rax
    CALLV SetParent, g_hwnd, g_lWorker
    test eax, eax
    jz atw_fail
    mov rax, g_lWorker
    mov g_parent, rax
    lea rax, g_rc
    CALLV GetClientRect, g_lWorker, rax
    mov eax, dword ptr g_rc[8]
    sub eax, dword ptr g_rc[0]
    mov g_w, eax
    mov eax, dword ptr g_rc[12]                 ; bottom（RECT=16 字节：left@0/top@4/right@8/bottom@12）
    sub eax, dword ptr g_rc[4]                  ; top → 高度（原错读 [24]/[16] 越界，高度恒 0）
    mov g_h, eax
    mov eax, g_w
    mov g_winW, eax
    mov eax, g_h
    mov g_winH, eax
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, 0
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov eax, g_w
    mov g_a5, rax
    mov eax, g_h
    mov g_a6, rax
    mov rax, SWP_NOZORDER or SWP_NOACTIVATE or SWP_SHOWWINDOW
    mov g_a7, rax
    call HSetWindowPos
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, HWND_BOTTOM
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov rax, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE
    mov g_a7, rax
    call HSetWindowPos
    mov eax, 1
    jmp atw_done
atw_fail:
    xor eax, eax
atw_done:
    add rsp, 28h
    ret
AttachToWorkerW ENDP

; ============================================================
; ApplyFallbackTopLevel
; ============================================================
ApplyFallbackTopLevel PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间



    CALLV GetWindowLongPtrW, g_hwnd, GWL_STYLE
    and rax, not WS_CHILD
    or rax, WS_POPUP or WS_VISIBLE
    CALLV SetWindowLongPtrW, g_hwnd, GWL_STYLE, rax
    CALLV GetWindowLongPtrW, g_hwnd, GWL_EXSTYLE
    or rax, WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW
    CALLV SetWindowLongPtrW, g_hwnd, GWL_EXSTYLE, rax
    CALLV SetParent, g_hwnd, 0
    mov g_parent, 0
    CALLV GetSystemMetrics, SM_CXSCREEN
    mov g_w, eax
    CALLV GetSystemMetrics, SM_CYSCREEN
    mov g_h, eax
    mov eax, g_w
    mov g_winW, eax
    mov eax, g_h
    mov g_winH, eax
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, HWND_BOTTOM
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov eax, g_w
    mov g_a5, rax
    mov eax, g_h
    mov g_a6, rax
    mov rax, SWP_NOACTIVATE or SWP_SHOWWINDOW or SWP_FRAMECHANGED
    mov g_a7, rax
    call HSetWindowPos
    add rsp, 28h
    ret
ApplyFallbackTopLevel ENDP

; ============================================================
; EnsureWallpaperZOrder
; ============================================================
EnsureWallpaperZOrder PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间





    CALLV IsWindow, g_hwnd
    test eax, eax
    jz ez_done
    CALLV GetParent, g_hwnd
    mov g_lParent, rax
    test rax, rax
    jz ez_toplevel
    CALLV IsWindow, g_lParent
    test eax, eax
    jz ez_toplevel
    lea rax, g_pcls
    CALLV GetClassNameW, g_lParent, rax, 80
    lea rcx, g_pcls             ; 修复：原来两个 lea rax 互相覆盖，lstrcmpW 变成 clsProgman 自比（恒 0）
    lea rdx, clsProgman
    CALLV lstrcmpW, rcx, rdx
    test eax, eax
    jnz ez_notProgman

    ; ---- Progman：双向锚定 ----
    mov rax, g_defView
    test rax, rax
    jz ez_findDV
    CALLV IsWindow, g_defView
    test eax, eax
    jz ez_findDV
    CALLV GetParent, g_defView
    cmp rax, g_lParent
    je ez_haveDV
ez_findDV:
    lea rax, clsDefView
    CALLV FindWindowExW, g_lParent, 0, rax, 0
    test rax, rax
    jz ez_dvMissing
    mov g_defView, rax
ez_haveDV:
    mov g_ldefView, rax
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, g_ldefView
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov rax, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE
    mov g_a7, rax
    call HSetWindowPos
    mov rax, g_workerW
    test rax, rax
    jz ez_findWW
    CALLV IsWindow, g_workerW
    test eax, eax
    jz ez_findWW
    CALLV GetParent, g_workerW
    cmp rax, g_lParent
    je ez_haveWW
ez_findWW:
    lea rax, clsWorkerW
    CALLV FindWindowExW, g_lParent, 0, rax, 0
    test rax, rax
    jz ez_wwMissing
    mov g_workerW, rax
ez_haveWW:
    mov g_lWorker, rax
    mov rax, g_hwnd
    cmp g_lWorker, rax
    je ez_done
    mov rax, g_lWorker
    mov g_a1, rax
    mov rax, g_hwnd
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov rax, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE
    mov g_a7, rax
    call HSetWindowPos
    jmp ez_done
ez_dvMissing:
    lea rax, szZorderFailed
    mov g_a1, rax
    call EmbedLog
    jmp ez_done
ez_wwMissing:
    ; 结构退化自愈：重发 0x052C（5s 节流）
    CALLV GetTickCount
    mov r10d, eax
    mov eax, g_lastRaise
    sub r10d, eax
    cmp r10d, 5000
    jb ez_done
    CALLV GetTickCount
    mov g_lastRaise, eax
    CALLV GetParent, g_hwnd
    mov g_a1, rax
    mov rax, 052Ch
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, SMTO_NORMAL
    mov g_a5, rax
    mov rax, 1000
    mov g_a6, rax
    mov rax, 0
    mov g_a7, rax
    call HSendMessageTimeout
    jmp ez_done

ez_notProgman:
    lea rcx, g_pcls             ; 修复：原来两个 lea rax 互相覆盖，lstrcmpW 变成 clsDefView 自比（恒 0）
    lea rdx, clsDefView
    CALLV lstrcmpW, rcx, rdx
    test eax, eax
    jnz ez_bottom
    lea rax, clsListView
    CALLV FindWindowExW, g_lParent, 0, rax, 0
    test rax, rax
    jnz ez_haveList
    lea rax, clsDirectUI
    CALLV FindWindowExW, g_lParent, 0, rax, 0
ez_haveList:
    test rax, rax
    jz ez_bottom
    mov r10, rax                ; 修复：先存锚点句柄（原来被 mov rax, g_hwnd 覆盖，SetWindowPos 变成自己插自己=空操作）
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, r10
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov r8, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE
    mov g_a7, r8
    call HSetWindowPos
    jmp ez_done
ez_bottom:
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, HWND_BOTTOM
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov rax, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE
    mov g_a7, rax
    call HSetWindowPos
    jmp ez_done

ez_toplevel:
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, HWND_BOTTOM
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    mov rax, 0
    mov g_a6, rax
    mov rax, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE
    mov g_a7, rax
    call HSetWindowPos
ez_done:
    add rsp, 28h
    ret
EnsureWallpaperZOrder ENDP

; ============================================================
; FitToParentOrMonitor
; ============================================================
FitToParentOrMonitor PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间



    CALLV IsWindow, g_hwnd
    test eax, eax
    jz fp_done
    CALLV GetParent, g_hwnd
    mov g_lParent, rax
    test rax, rax
    jz fp_done
    CALLV IsWindow, g_lParent
    test eax, eax
    jz fp_done
    lea rax, g_rc
    CALLV GetClientRect, g_lParent, rax
    mov eax, dword ptr g_rc[8]
    sub eax, dword ptr g_rc[0]
    mov g_winW, eax
    mov eax, dword ptr g_rc[12]                 ; bottom（RECT=16 字节：left@0/top@4/right@8/bottom@12）
    sub eax, dword ptr g_rc[4]                  ; top → 高度（原错读 [24]/[16] 越界，高度恒 0）
    mov g_winH, eax
    mov rax, g_hwnd
    mov g_a1, rax
    mov rax, 0
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov eax, g_winW
    mov g_a5, rax
    mov eax, g_winH
    mov g_a6, rax
    mov rax, SWP_NOZORDER or SWP_NOACTIVATE or SWP_SHOWWINDOW
    mov g_a7, rax
    call HSetWindowPos
fp_done:
    add rsp, 28h
    ret
FitToParentOrMonitor ENDP

; ============================================================
; FindProgman
; ============================================================
FindProgmanEnum PROC
    sub rsp, 28h
    mov g_cbHwnd, rcx           ; 先保存易失寄存器：后续 GetClassNameW/lstrcmpW 不保证保留 rcx/rdx
    mov g_cbLParam, rdx
    lea r10, g_scratchW
    CALLV GetClassNameW, rcx, r10, 80
    lea rax, clsProgman
    CALLV lstrcmpW, r10, rax
    test eax, eax
    jnz fpe_next
    mov rcx, g_cbLParam
    mov rax, g_cbHwnd
    mov [rcx], rax
    xor eax, eax
    jmp fpe_done
fpe_next:
    mov eax, 1
fpe_done:
    add rsp, 28h
    ret
FindProgmanEnum ENDP

FindProgman PROC
    sub rsp, 28h
    lea rax, clsProgman
    CALLV FindWindowW, rax, 0
    test rax, rax
    jnz fp_done
    mov g_enumFound, 0
    lea rax, FindProgmanEnum
    lea r10, g_enumFound
    CALLV EnumWindows, rax, r10
    mov rax, g_enumFound
fp_done:
    add rsp, 28h
    ret
FindProgman ENDP

; ============================================================
; FindWallpaperWorkerW(progman)
; ============================================================
; ============================================================
; FindWallpaperWorkerW(rcx = progman) -> rax = 全屏 WorkerW 子窗口 or 0
; 对齐 C++ 设计（cpp/desktop.cpp FindWallpaperWorkerW）：枚举 Progman 的
; WorkerW 子窗口，只认覆盖主屏 ≥90% 的，排除 135x37 之类的小占位窗口。
; 旧实现用 EnumWindows 枚举顶层窗口再比 GetParent——Progman 的**子** WorkerW
; 永远不在顶层枚举里，函数恒返回 0：0x052C 产出的全屏 WorkerW 没人压到壁纸
; 窗口之下，盖住桌面图标层（2026-10-18 实测复现，memory 有全程记录）。
; ============================================================
FindWallpaperWorkerW PROC
    sub rsp, 28h
    mov g_enumProgman, rcx
    ; 阈值 = 主屏尺寸 × 9（候选用 ×10 比较，避开除法）
    CALLV GetSystemMetrics, SM_CXSCREEN
    imul eax, eax, 9
    mov g_threshW, eax
    CALLV GetSystemMetrics, SM_CYSCREEN
    imul eax, eax, 9
    mov g_threshH, eax
    mov g_fwwPrev, 0                    ; FindWindowExW 游标（0 = 从头开始）
fww_loop:
    mov r10, g_enumProgman
    mov r11, g_fwwPrev
    lea rax, clsWorkerW
    CALLV FindWindowExW, r10, r11, rax, 0
    test rax, rax
    jz fww_none
    mov g_fwwCur, rax
    ; 尺寸过滤：宽×10 ≥ 屏宽×9 且 高×10 ≥ 屏高×9
    lea r10, g_fwwRect
    CALLV GetWindowRect, rax, r10
    mov eax, dword ptr g_fwwRect[8]
    sub eax, dword ptr g_fwwRect[0]
    imul eax, eax, 10
    cmp eax, g_threshW
    jb fww_next
    mov eax, dword ptr g_fwwRect[12]
    sub eax, dword ptr g_fwwRect[4]
    imul eax, eax, 10
    cmp eax, g_threshH
    jb fww_next
    mov rax, g_fwwCur
    jmp fww_done
fww_next:
    mov rax, g_fwwCur
    mov g_fwwPrev, rax
    jmp fww_loop
fww_none:
    xor eax, eax
fww_done:
    add rsp, 28h
    ret
FindWallpaperWorkerW ENDP

; ============================================================
; FindWorkerAfterIconWorker
; ============================================================
FindWorkerAfterIconWorkerEnum PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间
    mov g_cbHwnd, rcx           ; 先保存：后续 API 调用不保证保留 rcx

    lea r10, g_scratchW
    CALLV GetClassNameW, rcx, r10, 80
    lea rax, clsWorkerW
    CALLV lstrcmpW, r10, rax
    test eax, eax
    jnz fwa_next
    CALLV GetAncestor, g_cbHwnd, GA_ROOT
    mov g_lRoot, rax
    lea rax, clsDefView
    CALLV FindWindowExW, g_lRoot, 0, rax, 0
    test rax, rax
    jz fwa_next
    CALLV GetParent, g_cbHwnd
    cmp rax, g_lRoot
    je fwa_next
    mov rax, g_cbHwnd
    mov g_enumFound, rax
    xor eax, eax
    jmp fwa_done
fwa_next:
    mov eax, 1
fwa_done:
    add rsp, 28h
    ret
FindWorkerAfterIconWorkerEnum ENDP

FindWorkerAfterIconWorker PROC
    sub rsp, 28h
    mov g_enumFound, 0
    lea rax, FindWorkerAfterIconWorkerEnum
    CALLV EnumWindows, rax, 0
    mov rax, g_enumFound
    add rsp, 28h
    ret
FindWorkerAfterIconWorker ENDP

; ============================================================
; WatchdogTick
; ============================================================
WatchdogTick PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间


    ; quit 握手（完整路径，不依赖 CWD）
    lea rcx, szQuitName
    call JoinExeDir
    CALLV GetFileAttributesW, rax
    cmp eax, INVALID_FILE_ATTRIBUTES
    jne wt_quit
    ; 窗口丢了 -> 重建
    CALLV IsWindow, g_hwnd
    test eax, eax
    jnz wt_alive
    call CreateWallpaperWindow
    test eax, eax
    jz wt_done
    mov rax, g_hwnd              ; 重建后同步 g_host，否则 WM_TIMER 又找不到窗口
    mov g_host, rax
    CALLV EmbedOrFallback, g_hwnd
    CALLV InvalidateRect, g_hwnd, 0, 0
    jmp wt_done
wt_alive:
    CALLV GetParent, g_hwnd
    test rax, rax
    jz wt_reembed
    CALLV IsWindow, rax
    test eax, eax
    jz wt_reembed
    CALLV IsWindow, g_parent
    test eax, eax
    jz wt_reembed
    jmp wt_zorder
wt_reembed:
    CALLV EmbedOrFallback, g_hwnd
    jmp wt_done
wt_zorder:
    CALLV FitToParentOrMonitor, g_hwnd
    CALLV EnsureWallpaperZOrder, g_hwnd
    ; 热切换
    cmp g_locked, 0
    jne wt_snapshot
    lea rcx, g_want              ; ResolveMediaPath 从 rcx 取目标缓冲（原来错给 rax）
    call ResolveMediaPath
    test eax, eax
    jz wt_snapshot
    movzx eax, word ptr g_want
    test eax, eax
    jz wt_snapshot
    lea rcx, g_want              ; lstrcmpW(want, curMedia)：rcx/rdx 分别给，两个 lea rax 会互相覆盖
    lea rdx, g_curMedia
    CALLV lstrcmpW, rcx, rdx
    test eax, eax
    jz wt_snapshot
    movzx eax, word ptr [g_failed]
    test eax, eax
    jz wt_tryload
    lea rcx, g_want              ; lstrcmpW(want, failed)
    lea rdx, g_failed
    CALLV lstrcmpW, rcx, rdx
    test eax, eax
    jz wt_snapshot
wt_tryload:
    mov rax, g_img
    mov g_backupImg, rax
    mov g_img, 0
    lea rcx, g_want              ; LoadImageFile 从 rcx 取路径（原来错给 rax）
    call LoadImageFile
    test eax, eax
    jnz wt_loaded
    ; 失败回滚 + 坏路径退避
    mov rax, g_backupImg
    mov g_img, rax
    lea rcx, g_failed            ; lstrcpyW(dest=failed, src=want)
    lea rdx, g_want
    CALLV lstrcpyW, rcx, rdx
    jmp wt_snapshot
wt_loaded:
    mov word ptr [g_failed], 0
    CALLV InvalidateRect, g_hwnd, 0, 0
    lea rax, szReloadOk
    mov g_a1, rax
    call EmbedLog
    jmp wt_snapshot
wt_quit:
    lea rcx, szQuitName
    call JoinExeDir
    CALLV DeleteFileW, rax
    lea rcx, szGracefulName
    call JoinExeDir
    mov g_a1, rax
    call WriteMarkerFile
    CALLV PostQuitMessage, 0
    jmp wt_done
wt_snapshot:
    call LogResourceSnapshot
wt_done:
    add rsp, 28h
    ret
WatchdogTick ENDP

; ============================================================
; LogLine(tag, msg)
; ============================================================
; ============================================================
; LogLine - 追加一行到 debug.log（纯手工拼串，不用 wsprintfW 变参）
;   行格式：YYYY-MM-DD HH:MM:SS <tag> <msg> hr=0x00000000\n
; ============================================================
; ============================================================
; LogLine - 追加一行到 debug.log（纯手工拼串，不用 wsprintfW 变参）
;   行格式：YYYY-MM-DD HH:MM:SS <tag> <msg> hr=0x00000000\n
; ============================================================
LogLine PROC
    push rsi                    ; rsi/rdi/rbx 均非易失（x64 Windows ABI），借用需保存
    push rdi
    push rbx
    sub rsp, 30h                ; 3 push(24) + 48 = 72 ≡ 8 → 内部 call 点 rsp ≡ 0 ✓
    mov rax, g_a1
    mov g_tag, rax
    mov rax, g_a2
    mov g_lmsg, rax
    lea rax, g_stt
    CALLV GetLocalTime, rax
    lea rdi, g_line             ; 输出游标（WNum* 与 CopyWide 共享）
    movzx ecx, word ptr g_stt[0]
    call WNum4                  ; 年
    WCHR2 '-'
    movzx ecx, word ptr g_stt[2]
    call WNum2                  ; 月
    WCHR2 '-'
    movzx ecx, word ptr g_stt[6]
    call WNum2                  ; 日
    WCHR2 ' '
    movzx ecx, word ptr g_stt[8]
    call WNum2                  ; 时
    WCHR2 ':'
    movzx ecx, word ptr g_stt[10]
    call WNum2                  ; 分
    WCHR2 ':'
    movzx ecx, word ptr g_stt[12]
    call WNum2                  ; 秒
    WCHR2 ' '
    mov rsi, g_tag
    call CopyWide
    WCHR2 ' '
    mov rsi, g_lmsg
    call CopyWide
    lea rsi, szTailFmt
    call CopyWide
    ; 写文件（打开/创建/定位/写/关，与旧版相同；完整路径不依赖 CWD）
    lea rcx, szLogName
    call JoinExeDir
    mov g_a1, rax
    mov rax, GENERIC_WRITE
    mov g_a2, rax
    mov rax, FILE_SHARE_READ or FILE_SHARE_WRITE
    mov g_a3, rax
    mov g_a4, 0
    mov rax, OPEN_EXISTING
    mov g_a5, rax
    mov rax, FILE_ATTRIBUTE_NORMAL
    mov g_a6, rax
    mov g_a7, 0
    call HCreateFile
    cmp rax, INVALID_HANDLE_VALUE
    jne ll_write
    lea rcx, szLogName
    call JoinExeDir
    mov g_a1, rax
    mov rax, GENERIC_WRITE
    mov g_a2, rax
    mov rax, FILE_SHARE_READ or FILE_SHARE_WRITE
    mov g_a3, rax
    mov g_a4, 0
    mov rax, CREATE_ALWAYS
    mov g_a5, rax
    mov rax, FILE_ATTRIBUTE_NORMAL
    mov g_a6, rax
    mov g_a7, 0
    call HCreateFile
    cmp rax, INVALID_HANDLE_VALUE
    je ll_done
ll_write:
    mov rbx, rax
    CALLV SetFilePointer, rbx, 0, 0, FILE_END
    ; 算字节数（g_line 宽串长度）
    lea rsi, g_line
    xor ecx, ecx
ll_len:
    movzx eax, word ptr [rsi+rcx*2]
    test eax, eax
    jz ll_lendone
    inc ecx
    jmp ll_len
ll_lendone:
    lea edx, [rcx*2]
    mov g_a1, rbx
    lea rax, g_line
    mov g_a2, rax
    mov g_a3, rdx
    lea rax, g_written
    mov g_a4, rax
    mov g_a5, 0
    call HWriteFile
    CALLV CloseHandle, rbx
ll_done:
    add rsp, 30h
    pop rbx
    pop rdi
    pop rsi
    ret
LogLine ENDP

; ------------------------------------------------------------
; CopyWide - 复制 rsi 指向的宽串到 rdi，推进 rdi
; ------------------------------------------------------------
CopyWide PROC
    push rsi                    ; 恢复调用方 rsi（rdi 有意穿透给 LogLine 拼串用）
cw_loop:
    movzx eax, word ptr [rsi]
    test eax, eax
    jz cw_done
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    jmp cw_loop
cw_done:
    mov word ptr [rdi], 0       ; 必须补终止符：否则 LogLine 的长度循环会数进上一行残留，
    pop rsi                     ; 把垃圾当行尾一起写进 debug.log（曾产出 "nchor hr=..." 残行）
    ret
CopyWide ENDP

; ------------------------------------------------------------
; WNum4/WNum2 - 十进制数写宽字符到 rdi（游标穿透，内部无调用）
;   rcx = 值；rdi 前进。配合 CopyWide 手工拼日志行。
; ------------------------------------------------------------
WNum4 PROC
    mov eax, ecx
    mov ecx, 1000
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi], ax
    add rdi, 2
    mov eax, edx
    mov ecx, 100
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi], ax
    add rdi, 2
    mov eax, edx
    mov ecx, 10
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi], ax
    add rdi, 2
    mov eax, edx
    add eax, '0'
    mov [rdi], ax
    add rdi, 2
    ret
WNum4 ENDP

WNum2 PROC
    mov eax, ecx
    mov ecx, 10
    xor edx, edx
    div ecx
    add eax, '0'
    mov [rdi], ax
    add rdi, 2
    mov eax, edx
    add eax, '0'
    mov [rdi], ax
    add rdi, 2
    ret
WNum2 ENDP



; ------------------------------------------------------------


; ============================================================
; EmbedLog(msg)
; ============================================================
EmbedLog PROC
    sub rsp, 28h
    mov rax, g_a1          ; 调用方风格：msg 经 g_a1 传入（勿改成 rcx，6 处调用点都用全局槽）
    mov g_a2, rax
    lea rax, szTagEmbed
    mov g_a1, rax
    call LogLine
    add rsp, 28h
    ret
EmbedLog ENDP

; ============================================================
; WriteEmbedMarker(strategy)
; ============================================================
WriteEmbedMarker PROC
    push rsi                    ; rdi/rsi/rbx 非易失，借用需保存
    push rdi
    push rbx
    sub rsp, 30h                ; 3 push(24) + 48 = 72 ≡ 8 → 内部 call 点 rsp ≡ 0 ✓




    mov rax, g_a1               ; strategy 经 g_a1 槽传入（勿改成 rcx，3 处调用点都用全局槽）
    mov g_lStrategy, rax
    lea rax, g_wmbuf
    CALLV lstrcpyW, rax, g_lStrategy
    lea rdi, g_wmbuf
    mov ecx, 63
wm_len:
    movzx eax, word ptr [rdi]
    test eax, eax
    jz wm_found
    add rdi, 2
    loop wm_len
wm_found:
    mov word ptr [rdi], 0Ah
    mov word ptr [rdi+2], 0
    lea rcx, szEmbedName
    call JoinExeDir
    mov g_a1, rax
    mov rax, GENERIC_WRITE
    mov g_a2, rax
    mov rax, FILE_SHARE_READ or FILE_SHARE_WRITE
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, CREATE_ALWAYS
    mov g_a5, rax
    mov rax, FILE_ATTRIBUTE_NORMAL
    mov g_a6, rax
    mov rax, 0
    mov g_a7, rax
    call HCreateFile
    cmp rax, INVALID_HANDLE_VALUE
    je wm_done
    mov rbx, rax
    lea rsi, g_wmbuf
    xor ecx, ecx
wm_len2:
    movzx eax, word ptr [rsi+rcx*2]
    test eax, eax
    jz wm_lendone
    inc ecx
    jmp wm_len2
wm_lendone:
    lea edx, [rcx*2]
    mov rax, rbx
    mov g_a1, rax
    lea rax, g_wmbuf
    mov g_a2, rax
    mov g_a3, rdx
    lea rax, g_written
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    call HWriteFile
    CALLV CloseHandle, rbx
wm_done:
    add rsp, 30h
    pop rbx
    pop rdi
    pop rsi
    ret
WriteEmbedMarker ENDP

; ============================================================
; WriteMarkerFile(name)
; ============================================================
WriteMarkerFile PROC
    push rbx                    ; rbx 非易失，借用存句柄需保存
    sub rsp, 30h                ; 1 push(8) + 48 = 56 ≡ 8 → 内部 call 点 rsp ≡ 0 ✓


    ; name 经 g_a1 槽传入（勿读 rcx，调用点用全局槽风格）；g_a1 原样交给 HCreateFile
    mov rax, GENERIC_WRITE
    mov g_a2, rax
    mov rax, FILE_SHARE_READ or FILE_SHARE_WRITE
    mov g_a3, rax
    mov rax, 0
    mov g_a4, rax
    mov rax, CREATE_ALWAYS
    mov g_a5, rax
    mov rax, FILE_ATTRIBUTE_NORMAL
    mov g_a6, rax
    mov rax, 0
    mov g_a7, rax
    call HCreateFile
    cmp rax, INVALID_HANDLE_VALUE
    je wf_done
    mov rbx, rax
    mov rax, rbx
    mov g_a1, rax
    mov rax, 0
    mov g_a2, rax
    mov rax, 0
    mov g_a3, rax
    lea rax, g_written
    mov g_a4, rax
    mov rax, 0
    mov g_a5, rax
    call HWriteFile
    CALLV CloseHandle, rbx
wf_done:
    add rsp, 30h
    pop rbx
    ret
WriteMarkerFile ENDP

; ============================================================
; LogResourceSnapshot
; ============================================================
LogResourceSnapshot PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间







    cmp g_resInit, 0
    jne rs_inited
    mov g_resInit, 1
    CALLV GetTickCount
    mov g_resStart, eax
rs_inited:
    cmp g_resInterval, 0
    je rs_done
    CALLV GetTickCount
    mov g_now, eax
    mov eax, g_resLast
    test eax, eax
    jz rs_fire
    mov eax, g_now
    sub eax, g_resLast
    cmp eax, g_resInterval
    jb rs_done
rs_fire:
    mov eax, g_now
    mov g_resLast, eax
    ; ---- 先做完所有 API 调用（CALLV 会摧毁 r9/r10/r11 等易失寄存器）----
    lea rax, g_pmc
    CALLV GetProcessMemoryInfo, g_hSelf, rax, 96
    lea rax, g_handles
    CALLV GetProcessHandleCount, g_hSelf, rax
    CALLV GetGuiResources, g_hSelf, GR_GDIOBJECTS
    mov g_gdi, eax
    CALLV GetGuiResources, g_hSelf, GR_USEROBJECTS
    mov g_usr, eax
    CALLV GetTickCount
    sub eax, g_resStart
    xor edx, edx
    mov ecx, 1000
    div ecx                      ; eax = uptime 秒
    mov g_resSec, eax            ; 商存全局：后面读 g_pmc 要复用 rax
    ; ---- 再取 g_pmc 指标（此后无 API 调用，r11/r10/r9 安全）----
    mov rax, qword ptr g_pmc[16]                 ; WorkingSetSize
    shr rax, 20
    mov r11d, eax
    mov rax, qword ptr g_pmc[72]                 ; PrivateUsage
    shr rax, 20
    mov r10d, eax
    mov rax, qword ptr g_pmc[8]                  ; PeakWorkingSetSize
    shr rax, 20
    mov r9d, eax
    lea r8, g_resBuf             ; 目的地用独立缓冲（不能是 g_line：LogLine 的输出也在 g_line）
    mov g_a1, r8
    lea r8, szResFmt
    mov g_a2, r8
    mov eax, g_resSec            ; a3 = uptime 秒
    mov g_a3, rax
    mov r8d, r11d                ; ws
    mov g_a4, r8
    mov r8d, r10d                ; commit
    mov g_a5, r8
    mov r8d, r9d                 ; peakws
    mov g_a6, r8
    mov eax, g_handles
    mov g_a7, rax
    mov eax, g_gdi
    mov g_a8, rax
    mov eax, g_usr
    mov g_a9, rax
    call HWsprintfRes
    lea rax, szTagRes
    mov g_a1, rax
    lea rax, g_resBuf            ; msg 也指向 g_resBuf（勿用 g_line）
    mov g_a2, rax
    call LogLine
rs_done:
    add rsp, 28h
    ret
LogResourceSnapshot ENDP

END

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

; ---------------- 外部函数（视频链路：MF / D3D11 / DXGI / DComp / COM）----------------
extern CoInitializeEx:proc
extern CoUninitialize:proc
extern MFStartup:proc
extern MFShutdown:proc
extern MFCreateAttributes:proc
extern MFCreateMediaType:proc
extern MFCreateFile:proc
extern MFCreateSourceReaderFromByteStream:proc
extern MFCreateDXGIDeviceManager:proc
extern D3D11CreateDevice:proc
extern CreateDXGIFactory1:proc
extern DCompositionCreateDevice:proc
extern SetProcessWorkingSetSize:proc
extern GetTickCount64:proc

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

; ---------------- 常量（视频链路；数值均由 SDK 头文件探针提取）----------------
TIMER_FRAME         equ 2
MF_VERSION_VAL      equ 20070h          ; MF_VERSION = MF_API_VERSION<<16 | MF_SDK_VERSION
MF_ACCESSMODE_READ  equ 1
MF_SRCREADER_FIRST_VIDEO equ 0FFFFFFFCh
MF_SRCREADER_ALL_STREAMS  equ 0FFFFFFFEh
MF_SRCREADER_MEDIASOURCE  equ 0FFFFFFFFh
MF_SRCREADERF_EOFS        equ 2          ; 注意是 2 不是 1（mfreadwrite.h 实测）
D3D11_CREATE_DEVICE_VIDEO_SUPPORT equ 800h
D3D11_CREATE_DEVICE_BGRA_SUPPORT  equ 20h
D3D11_SDK_VERSION   equ 7
D3D_DRIVER_TYPE_HARDWARE equ 1
D3D11_USAGE_DEFAULT   equ 0
D3D11_CPU_ACCESS_FLAG equ 0
DXGI_FORMAT_NV12    equ 67h
DXGI_FORMAT_B8G8R8A8_UNORM equ 57h
DXGI_USAGE_RENDER_TARGET_OUTPUT equ 20h
DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL equ 3
DXGI_ALPHA_MODE_IGNORE equ 3             ; 注意是 3 不是 0（dxgi.h 实测）
D3D11_VPIV_DIMENSION_TEXTURE2D equ 1
D3D11_VPOV_DIMENSION_TEXTURE2D equ 1
VT_I8               equ 14h
FOURCC_NV12         equ 3231564Eh

; vtable 槽位（SDK C 段扁平 vtbl 提取；C 代码 COMCALL 走的就是这张表。
; IMF2DBuffer/IMFDXGIBuffer 在 MF 头里是扁平表（Lock2D=3/GetResource=3），
; 并非从 IMFMediaBuffer 派生——与 C++ 段 ": public IUnknown" 声明一致）
SLOT_QI                      equ 0
SLOT_Release                 equ 2
SLOT_CreateTexture2D         equ 5
SLOT_UpdateSubresource       equ 48
SLOT_CreateVideoProcessor    equ 4
SLOT_CreateVPInputView       equ 8
SLOT_CreateVPOutputView      equ 9
SLOT_CreateVPEnumerator      equ 10
SLOT_VPSetOutputColorSpace   equ 15
SLOT_VPSetStreamFrameFormat  equ 27
SLOT_VPSetStreamColorSpace   equ 28
SLOT_VPSetStreamSourceRect   equ 30
SLOT_VPSetStreamDestRect     equ 31
SLOT_VPBlt                   equ 53
SLOT_SetMultithreadProtected equ 5
SLOT_CreateSwapChainForComp  equ 24
SLOT_Present                 equ 8
SLOT_GetBuffer               equ 9
SLOT_AttrGetUINT32           equ 7
SLOT_AttrGetUINT64           equ 8
SLOT_AttrGetGUID             equ 10
SLOT_AttrSetUINT32           equ 21
SLOT_AttrSetGUID             equ 24
SLOT_AttrSetUnknown          equ 27
SLOT_SetStreamSelection      equ 4
SLOT_GetCurrentMediaType     equ 6
SLOT_SetCurrentMediaType     equ 7
SLOT_SetCurrentPosition      equ 8
SLOT_ReadSample              equ 9
SLOT_GetPresentationAttribute equ 12
SLOT_ConvertToContiguousBuffer equ 41
SLOT_BufLock                 equ 3
SLOT_BufUnlock               equ 4
SLOT_Lock2D                  equ 3
SLOT_Unlock2D                equ 4
SLOT_GetResource             equ 3
SLOT_GetSubresourceIndex     equ 4
SLOT_ResetDevice             equ 7
; DirectComposition（C 版手写 vtbl 实测槽位，dcomp.h C++ 专用无法直接引用）
SLOT_DCompCommit             equ 3
SLOT_DCompCreateTarget       equ 6
SLOT_DCompCreateVisual       equ 7
SLOT_DCompTargetSetRoot      equ 3
SLOT_DCompVisualSetContent   equ 15

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

; ---- 视频链路状态（c/d3dplayer.c 的汇编对应）----
g_isVideo   dword 0
g_active    dword 0
g_upIsNv12  dword 1
g_vw        dword 0
g_vh        dword 0
g_frameMs   dword 33
g_scW       dword 0
g_scH       dword 0
g_hwDecode  dword 0
g_trimmed   dword 0
g_loopCount dword 0
g_loopRetry dword 0
g_loopProbs dword 0
g_drawn     dword 0
g_present   dword 0
g_locked2d  dword 0
g_presentLogged dword 0
g_presentFailN  dword 0
g_vpbltFailN    dword 0
g_zerocopyLogged dword 0
g_rsub      dword 0
g_len       dword 0
g_pitch     dword 0
g_num       dword 0
g_den       dword 0
g_hrTmp     dword 0
g_resetToken dword 0
g_fl        dword 0                ; D3D11CreateDevice 的 FeatureLevel 出口
g_pvpos     dword 0
g_bw        dword 0                ; BuildDrawChain 目标宽
g_bh        dword 0                ; BuildDrawChain 目标高
g_tsSec     dword 0
g_oldIsVideo dword 0
g_crDxva    dword 0

g_dev       qword 0                ; ID3D11Device
g_ctx       qword 0                ; ID3D11DeviceContext
g_swap      qword 0                ; IDXGISwapChain1（Composition）
g_dcomp     qword 0                ; IDCompositionDevice
g_target    qword 0                ; IDCompositionTarget
g_visual    qword 0                ; IDCompositionVisual
g_vd        qword 0                ; ID3D11VideoDevice
g_vc        qword 0                ; ID3D11VideoContext
g_vpe       qword 0                ; ID3D11VideoProcessorEnumerator
g_vp        qword 0                ; ID3D11VideoProcessor
g_inView    qword 0                ; VP 输入视图（上传纹理）
g_outView   qword 0                ; VP 输出视图（交换链后备）
g_dxm       qword 0                ; IMFDXGIDeviceManager（DXVA）
g_reader    qword 0                ; IMFSourceReader
g_upTex     qword 0                ; NV12/RGB32 上传纹理
g_mt        qword 0                ; ID3D10Multithread
g_dxgiDev   qword 0                ; IDXGIDevice（DComp 创建用）
g_fact2     qword 0                ; IDXGIFactory2
g_bb        qword 0                ; 交换链后备缓冲（建输出视图用）
g_cur       qword 0                ; IMFMediaType（读格式信息）
g_attr      qword 0                ; IMFAttributes（建 reader 用）
g_stream    qword 0                ; IMFByteStream
g_mt2       qword 0                ; IMFMediaType（协商输出类型）
g_crReader  qword 0                ; CreateReader 出口
g_nreader   qword 0                ; 循环重建 reader 中转
g_sample    qword 0                ; IMFSample
g_buf       qword 0                ; IMFMediaBuffer
g_dxb       qword 0                ; IMFDXGIBuffer
g_b2d       qword 0                ; IMF2DBuffer
g_tmpTex    qword 0                ; 零拷贝路径的解码纹理
g_tmpView   qword 0                ; 零拷贝路径的临时输入视图
g_pix       qword 0                ; Lock 出的像素指针
g_uvptr     qword 0                ; NV12 UV 平面指针
g_bltView   qword 0                ; BltVp 入口视图
g_initHwnd  qword 0                ; D3DInit 入口 hwnd 中转
g_initPath  qword 0                ; D3DInit 入口 path 中转
g_crPath    qword 0                ; CreateReader 入口 path 中转
g_firstSub  qword 0                ; 类型协商首选 subtype GUID
g_secondSub qword 0                ; 类型协商备选 subtype GUID
g_flags     dword 0                ; ReadSample flags 出口
g_ts        qword 0                ; ReadSample 时间戳出口
g_lastTs    qword 0                ; 最近一帧时间戳（100ns）
g_duration  qword 0                ; 时长（100ns）
g_startTick qword 0                ; trim 计时（GetTickCount64）
g_startWall qword 0                ; 本轮播放起始墙上时钟（ms）
g_startTs   qword 0                ; 本轮播放起始视频时间戳（100ns）
g_now64     qword 0                ; D3DPumpFrame 当前 tick
g_vTarget   qword 0                ; 应播到的视频时间点（100ns）
g_tsCalc    qword 0                ; eos 日志秒数计算中转
g_tsRem     qword 0                ; eos 日志余数中转
g_packed    qword 0                ; GetUINT64 手动拆包中转
g_vhwnd     qword 0                ; 视频模块绑定的窗口
g_vpath     word 520 dup (0)       ; 视频路径（循环重建 reader 用）
g_lmiPath   word 520 dup (0)       ; LoadMediaInto 路径副本
g_oldPath   word 520 dup (0)       ; 热切换回滚用的旧素材路径
g_dmsg      word 128 dup (0)       ; DpLog 格式化消息缓冲（勿与 g_line 混用）

; ---- 结构体缓冲（偏移经 cl 探针 offsetof 提取）----
g_sd1  byte 48 dup (0)             ; DXGI_SWAP_CHAIN_DESC1
g_td   byte 44 dup (0)             ; D3D11_TEXTURE2D_DESC
g_cd   byte 40 dup (0)             ; D3D11_VIDEO_PROCESSOR_CONTENT_DESC
g_ivd  byte 16 dup (0)             ; D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC（FourCC@0!）
g_ovd  byte 16 dup (0)             ; D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC
g_vs   byte 72 dup (0)             ; D3D11_VIDEO_PROCESSOR_STREAM（pInputSurface@32）
g_cs   dword 0                     ; 输入色彩空间（BT.709/16-235）
g_ocs  dword 0                     ; 输出色彩空间（全量程）
g_srect byte 16 dup (0)            ; 源矩形
g_drect byte 16 dup (0)            ; 目标矩形
g_pv   byte 24 dup (0)             ; PROPVARIANT（vt@0, hVal@8）
g_subtype byte 16 dup (0)          ; GetGUID 出口
g_guidNull byte 16 dup (0)         ; SetCurrentPosition 的 GUID_NULL
g_numtmp word 16 dup (0)           ; WNumDec 倒序缓冲

; ---- GUID（cl 探针 __uuidof/INITGUID 提取，与 C 版注释交叉一致）----
gi_DcompDev  dd 0C37EA93Ah         ; IID_IDCompositionDevice
             dw 0E7AAh
             dw 450Dh
             db 0B1h,6Fh,97h,46h,0CBh,04h,07h,0F3h
gi_DxgiFact2 dd 50C83A1Ch          ; IID_IDXGIFactory2
             dw 0E072h
             dw 4C48h
             db 87h,0B0h,36h,30h,0FAh,36h,0A6h,0D0h
gi_DxgiDev   dd 54EC77FAh          ; IID_IDXGIDevice
             dw 1377h
             dw 44E6h
             db 8Ch,32h,88h,0FDh,5Fh,44h,0C8h,4Ch
gi_Tex2D     dd 6F15AAF2h          ; IID_ID3D11Texture2D
             dw 0D208h
             dw 4E89h
             db 9Ah,0B4h,48h,95h,35h,0D3h,4Fh,9Ch
gi_VideoDev  dd 10EC4D5Bh          ; IID_ID3D11VideoDevice
             dw 975Ah
             dw 4689h
             db 0B9h,0E4h,0D0h,0AAh,0C3h,0Fh,0E3h,33h
gi_VideoCtx  dd 61F21C45h          ; IID_ID3D11VideoContext
             dw 3C0Eh
             dw 4A74h
             db 9Ch,0EAh,67h,10h,0Dh,9Ah,0D5h,0E4h
gi_D3D10MT   dd 9B7E4E00h          ; IID_ID3D10Multithread
             dw 342Ch
             dw 4106h
             db 0A1h,9Fh,4Fh,27h,04h,0F6h,89h,0F0h
gi_MfDxgiBuf dd 0E7174CFAh         ; IID_IMFDXGIBuffer
             dw 1C9Eh
             dw 48B1h
             db 88h,66h,62h,62h,26h,0BFh,0C2h,58h
gi_Mf2DBuf   dd 7DC9D5F9h          ; IID_IMF2DBuffer
             dw 9ED9h
             dw 44ECh
             db 9Bh,0BFh,06h,00h,0BBh,58h,9Fh,0BBh
ga_ReaderD3DMgr dd 0EC822DA2h      ; MF_SOURCE_READER_D3D_MANAGER
             dw 0E1E9h
             dw 4B29h
             db 0A0h,0D8h,56h,3Ch,71h,9Fh,52h,69h
ga_HwXforms  dd 0A634A91Ch         ; MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS
             dw 822Bh
             dw 41B9h
             db 0A4h,94h,4Dh,0E4h,64h,36h,12h,0B0h
ga_MediaTypeVideo dd 73646976h     ; MFMediaType_Video
             dw 0
             dw 0010h
             db 80h,00h,00h,0AAh,00h,38h,9Bh,71h
ga_MajorType dd 48EBA18Eh          ; MF_MT_MAJOR_TYPE
             dw 0F8C9h
             dw 4687h
             db 0BFh,11h,0Ah,74h,0C9h,0F9h,6Ah,8Fh
ga_SubType   dd 0F7E34C9Ah         ; MF_MT_SUBTYPE
             dw 42E8h
             dw 4714h
             db 0B7h,4Bh,0CBh,29h,0D7h,2Ch,35h,0E5h
ga_FrameSize dd 1652C33Dh          ; MF_MT_FRAME_SIZE
             dw 0D6B2h
             dw 4012h
             db 0B8h,34h,72h,03h,08h,49h,0A3h,7Dh
ga_FrameRate dd 0C459A2E8h         ; MF_MT_FRAME_RATE
             dw 3D2Ch
             dw 4E44h
             db 0B1h,32h,0FEh,0E5h,15h,6Ch,7Bh,0B0h
ga_Duration  dd 6C990D33h          ; MF_PD_DURATION
             dw 0BB8Eh
             dw 477Ah
             db 85h,98h,0Dh,5Dh,96h,0FCh,0D8h,8Ah
gv_RGB32     dd 00000016h          ; MFVideoFormat_RGB32
             dw 0
             dw 0010h
             db 80h,00h,00h,0AAh,00h,38h,9Bh,71h
gv_NV12      dd 3231564Eh          ; MFVideoFormat_NV12
             dw 0
             dw 0010h
             db 80h,00h,00h,0AAh,00h,38h,9Bh,71h

; ---- 视频扩展名表（与 c/media.c IsVideoFile 一致）----
szExtMp4     dw '.','m','p','4',0
szExtMov     dw '.','m','o','v',0
szExtAvi     dw '.','a','v','i',0
szExtWmv     dw '.','w','m','v',0
szExtMkv     dw '.','m','k','v',0
szExtWebm    dw '.','w','e','b','m',0
szExtM4v     dw '.','m','4','v',0
extTable     qword szExtMp4
             qword szExtMov
             qword szExtAvi
             qword szExtWmv
             qword szExtMkv
             qword szExtWebm
             qword szExtM4v

; ---- 视频链路日志串 ----
szTagD3d     dw '[','d','3','d',']'
             dw 0
szDevFailed  dw 'd','e','v','i','c','e',' ','f','a','i','l','e','d'
             dw 0
szVideoIfacesFailed dw 'v','i','d','e','o',' ','i','f','a','c','e','s',' ','f','a','i','l','e','d'
             dw 0
szReaderFailed dw 'r','e','a','d','e','r',' ','f','a','i','l','e','d'
             dw 0
szCurTypeFailed dw 'c','u','r',' ','t','y','p','e',' ','f','a','i','l','e','d'
             dw 0
szSizeFailed dw 's','i','z','e',' ','f','a','i','l','e','d'
             dw 0
szUploadTexFailed dw 'u','p','l','o','a','d',' ','t','e','x',' ','f','a','i','l','e','d'
             dw 0
szCompSwapFailed dw 'c','o','m','p',' ','s','w','a','p','c','h','a','i','n',' ','f','a','i','l','e','d'
             dw 0
szDcompQi    dw 'd','c','o','m','p',':',' ','q','i',' ','d','x','g','i','d','e','v','i','c','e'
             dw 0
szDcompCreate dw 'd','c','o','m','p',':',' ','c','r','e','a','t','e',' ','d','e','v','i','c','e'
             dw 0
szDcompTarget dw 'd','c','o','m','p',':',' ','c','r','e','a','t','e',' ','t','a','r','g','e','t'
             dw 0
szDcompVisual dw 'd','c','o','m','p',':',' ','c','r','e','a','t','e',' ','v','i','s','u','a','l'
             dw 0
szDcompContent dw 'd','c','o','m','p',':',' ','s','e','t',' ','c','o','n','t','e','n','t'
             dw 0
szDcompCommit dw 'd','c','o','m','p',':',' ','c','o','m','m','i','t'
             dw 0
szSwapchainDcomp dw 's','w','a','p','c','h','a','i','n',':',' ','d','c','o','m','p','-','m','o','d','e','l'
             dw 0
szVpFailed   dw 'v','p',' ','f','a','i','l','e','d'
             dw 0
szViewFailed dw 'v','i','e','w',' ','f','a','i','l','e','d'
             dw 0
szFirstPresent dw 'f','i','r','s','t',' ','p','r','e','s','e','n','t'
             dw 0
szPresentFailed dw 'p','r','e','s','e','n','t',' ','f','a','i','l','e','d'
             dw 0
szVpbltFailed dw 'v','p','b','l','t',' ','f','a','i','l','e','d'
             dw 0
szReadsampleFailed dw 'r','e','a','d','s','a','m','p','l','e',' ','f','a','i','l','e','d'
             dw 0
szLoopReaderRebuilt dw 'l','o','o','p',':',' ','r','e','a','d','e','r',' ','r','e','b','u','i','l','t'
             dw 0
szLoopRebuildFailed dw 'l','o','o','p',' ','r','e','b','u','i','l','d',' ','f','a','i','l','e','d'
             dw 0
szZerocopyPath dw 'f','r','a','m','e',':',' ','z','e','r','o','c','o','p','y',' ','p','a','t','h'
             dw 0
szD3dFail    dw 'd','3','d'
             dw 0
szInitOk     dw 'i','n','i','t',' ','o','k',' '
             dw 0
szMs         dw 'm','s',' '
             dw 0
szNv12       dw 'N','V','1','2'
             dw 0
szRgb32      dw 'R','G','B','3','2'
             dw 0
szDxva       dw 'D','X','V','A'
             dw 0
szSoft       dw 's','o','f','t'
             dw 0
szEosTs      dw 'e','o','s',' ','t','s','='
             dw 0
szEosLoop    dw ' ','l','o','o','p','='
             dw 0
szEosProbs   dw ' ','(','s','e','e','k','/','r','e','a','d','e','r',' ','p','r','o','b','l','e','m','s',')'
             dw 0
szEosOk      dw 0

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

    ; 3b) COM + Media Foundation 启动（视频链路；静态图路径无开销）
    CALLV CoInitializeEx, 0, 0
    CALLV MFStartup, MF_VERSION_VAL, 0

    ; 4) 读配置加载素材（视频只记路径，等窗口就绪）
    call LoadConfiguredMedia
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

    ; 5b) 视频：窗口就绪后用 D3D11 播放器硬解播放（DXVA + 无缝循环）
    cmp g_isVideo, 0
    je sv_done
    mov rcx, g_hwnd
    lea rdx, g_path
    call D3DInit
    test eax, eax
    jnz sv_done
    lea rax, szD3dFail
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    call D3DShutdown
    CALLV MFShutdown
    CALLV CoUninitialize
    CALLV GdiplusShutdown, g_token
    CALLV ExitProcess, 1
sv_done:

    ; 6) 看门狗 + 帧定时器（视频高频泵帧）
    CALLV SetTimer, g_host, TIMER_WATCHDOG, WATCHDOG_MS, 0
    call StartFrameTimer

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
    CALLV KillTimer, g_host, TIMER_FRAME
    call D3DShutdown
    CALLV MFShutdown
    CALLV CoUninitialize
    CALLV GdiplusShutdown, g_token
    CALLV ExitProcess, 0

log_noimage:
    lea rax, szNoImage
    mov g_a1, rax
    call EmbedLog
    CALLV MFShutdown
    CALLV CoUninitialize
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
    cmp r8, TIMER_FRAME           ; r8 = wParam（timer id）
    je wp_frame
    call WatchdogTick
    xor eax, eax
    jmp wp_done
wp_frame:
    call AdvanceFrame
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

    ; 视频：D3D 交换链常驻呈现整个客户区，GDI 不参与；
    ; 循环 seek 期间画面保留在交换链上，无空窗、无闪屏
    cmp g_isVideo, 0
    je pi_image
    lea rax, g_ps
    CALLV BeginPaint, g_hwnd, rax
    lea rax, g_ps
    CALLV EndPaint, g_hwnd, rax
    jmp pi_done
pi_image:
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
; LoadConfiguredMedia
;   解析 wallpaper.txt → 视频：记路径等窗口就绪后 D3DInit；
;   图片：立即加载（LoadImageFile 内部同步 g_curMedia）
; ============================================================
LoadConfiguredMedia PROC
    sub rsp, 28h                ; x64 调用对齐 + 影子空间
    lea rcx, g_path
    call ResolveMediaPath
    test eax, eax
    jz lcm_done0
    movzx eax, word ptr g_path
    test eax, eax
    jz lcm_done0
    lea rcx, g_path
    call IsVideoFile
    test eax, eax
    jz lcm_image
    ; ---- 视频：记录路径与 g_curMedia，图片留空（D3DInit 在嵌窗后）----
    mov g_isVideo, 1
    lea rdi, g_vpath
    lea rsi, g_path
    mov ecx, 519
    rep movsw
    mov word ptr [rdi], 0
    lea rdi, g_curMedia
    lea rsi, g_path
    mov ecx, 259
    rep movsw
    mov word ptr [rdi], 0
    mov eax, 1
    jmp lcm_done
lcm_image:
    lea rcx, g_path
    call LoadImageFile
    test eax, eax
    jz lcm_done0
    mov eax, 1
    jmp lcm_done
lcm_done0:
    xor eax, eax
lcm_done:
    add rsp, 28h
    ret
LoadConfiguredMedia ENDP

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
    jne ez_findDV
    mov rax, g_defView         ; 修复：rax 刚被 GetParent 覆写为父窗口，换回缓存的 DefView 句柄
    jmp ez_haveDV              ; （曾传 Progman 当 hWndInsertAfter → SetWindowPos 失败 → 壁纸盖住桌面图标）
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
    jne ez_findWW
    mov rax, g_workerW         ; 修复：同上，rax 被 GetParent 覆写，换回缓存的 WorkerW 句柄
    jmp ez_haveWW
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
    cmp g_isVideo, 0
    je wt_norebind
    mov rcx, g_hwnd              ; 新窗口句柄 → 视频绘制链换目标
    call D3DSetWindow
wt_norebind:
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
    cmp g_isVideo, 0
    je wt_done
    mov rcx, g_hwnd              ; 重嵌入后确保视频仍绑定当前窗口（同句柄时空转）
    call D3DSetWindow
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
    ; 备份旧素材（回滚用），按媒体类型分发加载
    lea rcx, g_oldPath
    lea rdx, g_curMedia
    CALLV lstrcpyW, rcx, rdx
    mov eax, g_isVideo
    mov g_oldIsVideo, eax
    lea rcx, g_want              ; LoadMediaInto 从 rcx 取路径
    call LoadMediaInto
    test eax, eax
    jnz wt_loaded
    ; 失败回滚 + 坏路径退避（对齐 C 版：重载旧素材）
    lea rcx, g_failed
    lea rdx, g_want
    CALLV lstrcpyW, rcx, rdx
    movzx eax, word ptr [g_oldPath]
    test eax, eax
    jz wt_snapshot
    lea rcx, g_oldPath
    call LoadMediaInto
    jmp wt_snapshot
wt_loaded:
    mov word ptr [g_failed], 0
    call StartFrameTimer          ; 视频↔图片互切必须重设帧定时器
    CALLV FitToParentOrMonitor, g_hwnd
    CALLV InvalidateRect, g_hwnd, 0, 0
    CALLV EnsureWallpaperZOrder, g_hwnd
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
;   g_a3 = hr 真实值；= -1 时用固定 hr=0x00000000 尾（旧调用方）
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
    ; hr 尾：真实值（g_a3 != -1）或固定 0
    mov rax, g_a3
    cmp rax, -1
    je ll_fixed
    WCHR2 ' '
    WCHR2 'h'
    WCHR2 'r'
    WCHR2 '='
    WCHR2 '0'
    WCHR2 'x'
    mov ecx, dword ptr g_a3
    call WHex8
    WCHR2 0Ah
    mov word ptr [rdi], 0       ; 必须补终止符：否则 ll_len 数进上一行残留（曾产出 "anchor hr=..." 残行）
    jmp ll_hrout
ll_fixed:
    lea rsi, szTailFmt
    call CopyWide
ll_hrout:
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
    mov g_a3, -1           ; 固定 hr 尾（无真实 hr）
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
    mov g_a3, -1                 ; 固定 hr 尾
    call LogLine
rs_done:
    add rsp, 28h
    ret
LogResourceSnapshot ENDP

; ============================================================
; 视频播放链路 —— c/d3dplayer.c（703 行）的纯 MASM 移植
;
;   管线：MF SourceReader（DXVA 硬解优先）→ NV12/RGB32
;         → D3D11 VideoProcessor（NV12→RGB + cover 缩放）
;         → Composition 交换链 + DirectComposition 呈现
;         → EOS 后 SetCurrentPosition(0) 无缝循环（交换链保留帧不闪屏）
;
;   COM 调用：ML64 无 C++ 隐式 this，统一走 CC0..CC6 助手
;   （g_a1=对象, g_a2=槽位, g_a3..=参数 → [obj]→lpVtbl→call）。
;   槽位/偏移/GUID 全部取自本机 SDK 头文件（C 段扁平 vtbl），
;   探针程序与交叉验证记录见 2026-10-19 工作日志。
;
;   与 C 版的对应关系：
;     CreateReader      → IMFSourceReader 创建 + DXVA 属性 + 类型协商
;     BuildDrawChain    → 交换链/DComp/VideoProcessor 全链
;     D3DInit           → 设备/DXVA/reader/纹理/绘制链
;     DrawSample        → 零拷贝（IMFDXGIBuffer）+ 系统内存上传双路径
;     D3DPumpFrame      → 追帧 + 无缝循环
; ============================================================

; ------------------------------------------------------------
; CC0..CC6 - COM 虚调用助手
;   入口：g_a1 = 对象指针, g_a2 = vtable 槽位, g_a3.. = 参数
;   出口：rax = HRESULT（>=0 成功）
;   栈布局：sub rsp 量 = 32(影子) + N*8(栈参) + 8(对齐)，即 S=0/1 用 28h，S=2/3 用 38h
;   （只减 8 会让被调函数的 home slot [rsp+10h] 落在本函数返回地址上——曾致 rip=0 崩溃）
; ------------------------------------------------------------
CC0 PROC                          ; 仅 this
    sub rsp, 28h                  ; 32 影子 + 8 对齐；少了会被 home slot 覆盖返回地址
    mov rcx, g_a1
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 28h
    ret
CC0 ENDP

CC1 PROC                          ; this + 1 参
    sub rsp, 28h                  ; 32 影子 + 8 对齐；少了会被 home slot 覆盖返回地址
    mov rcx, g_a1
    mov rdx, g_a3
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 28h
    ret
CC1 ENDP

CC2 PROC                          ; this + 2 参
    sub rsp, 28h                  ; 32 影子 + 8 对齐；少了会被 home slot 覆盖返回地址
    mov rcx, g_a1
    mov rdx, g_a3
    mov r8,  g_a4
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 28h
    ret
CC2 ENDP

CC3 PROC                          ; this + 3 参
    sub rsp, 28h                  ; 32 影子 + 8 对齐；少了会被 home slot 覆盖返回地址
    mov rcx, g_a1
    mov rdx, g_a3
    mov r8,  g_a4
    mov r9,  g_a5
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 28h
    ret
CC3 ENDP

CC4 PROC                          ; this + 4 参（1 个栈参）
    sub rsp, 28h
    mov rcx, g_a1
    mov rdx, g_a3
    mov r8,  g_a4
    mov r9,  g_a5
    mov rax, g_a6
    mov [rsp+20h], rax
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 28h
    ret
CC4 ENDP

CC5 PROC                          ; this + 5 参（2 个栈参）
    sub rsp, 38h                  ; 需 32(影子)+16(2 栈参)=48；入口≡8 → 减量须≡8 mod 16 → 取 56
    mov rcx, g_a1
    mov rdx, g_a3
    mov r8,  g_a4
    mov r9,  g_a5
    mov rax, g_a6
    mov [rsp+20h], rax
    mov rax, g_a7
    mov [rsp+28h], rax
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 38h
    ret
CC5 ENDP

CC6 PROC                          ; this + 6 参（3 个栈参）
    sub rsp, 38h
    mov rcx, g_a1
    mov rdx, g_a3
    mov r8,  g_a4
    mov r9,  g_a5
    mov rax, g_a6
    mov [rsp+20h], rax
    mov rax, g_a7
    mov [rsp+28h], rax
    mov rax, g_a8
    mov [rsp+30h], rax
    mov rax, g_a2
    mov r11, [rcx]
    call qword ptr [r11+rax*8]
    add rsp, 38h
    ret
CC6 ENDP

; ------------------------------------------------------------
; ReleaseClear(rcx = 指针变量的地址) —— 释放并置 0（幂等）
; ------------------------------------------------------------
ReleaseClear PROC
    push rcx                    ; 保存 &指针变量（CC0 会篡改 rcx）→ 存于 [E-8]
    sub rsp, 20h                ; 8(push)+32=40 ≡ 0 (mod 16)，call 点对齐 ✓
    mov rax, [rcx]
    test rax, rax
    jz rc_done
    mov g_a1, rax
    mov g_a2, SLOT_Release
    call CC0
    mov rcx, [rsp+20h]          ; 取回 [E-8]（push 槽；恰在影子空间 [rsp,rsp+32) 上界之外，安全）
    mov qword ptr [rcx], 0
rc_done:
    add rsp, 20h
    pop rcx
    ret
ReleaseClear ENDP

; ------------------------------------------------------------
; HD3D11CreateDevice - 10 参包装（g_a1..g_a10）
; ------------------------------------------------------------
HD3D11CreateDevice PROC
    sub rsp, 58h
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
    call D3D11CreateDevice
    add rsp, 58h
    ret
HD3D11CreateDevice ENDP

; ------------------------------------------------------------
; HMFCreateFile - 5 参包装（g_a1..g_a5）
; ------------------------------------------------------------
HMFCreateFile PROC
    sub rsp, 28h
    mov rcx, g_a1
    mov rdx, g_a2
    mov r8,  g_a3
    mov r9,  g_a4
    mov rax, g_a5
    mov [rsp+20h], rax
    call MFCreateFile
    add rsp, 28h
    ret
HMFCreateFile ENDP

; ------------------------------------------------------------
; WHex8 - 32 位值写 8 位大写十六进制宽字符到 rdi（推进 rdi）
;   配合 LogLine 的 hr 尾串；内部无调用
; ------------------------------------------------------------
WHex8 PROC
    mov edx, ecx
    mov r11d, 8
wh_loop:
    mov eax, edx
    shr eax, 28
    and eax, 0Fh
    cmp eax, 10
    jb wh_dig
    add eax, 'A'-10
    jmp wh_put
wh_dig:
    add eax, '0'
wh_put:
    mov [rdi], ax
    add rdi, 2
    shl edx, 4
    dec r11d
    jnz wh_loop
    ret
WHex8 ENDP

; ------------------------------------------------------------
; WNumDec - 变长十进制宽字符写 rdi（推进 rdi）
;   倒序生成到 g_numtmp 后正序拷贝；内部无调用
; ------------------------------------------------------------
WNumDec PROC
    xor eax, eax
    mov qword ptr g_numtmp[0], rax
    mov qword ptr g_numtmp[8], rax
    mov qword ptr g_numtmp[16], rax
    mov qword ptr g_numtmp[24], rax
    lea r10, g_numtmp
    add r10, 30                     ; 指向第 16 个 word 槽（倒序写起点）
    mov eax, ecx
    test eax, eax
    jnz wnd_loop
    sub r10, 2
    mov word ptr [r10], '0'
    jmp wnd_copy
wnd_loop:
    test eax, eax
    jz wnd_copy
    xor edx, edx
    mov ecx, 10
    div ecx
    add edx, '0'
    sub r10, 2
    mov [r10], dx
    jmp wnd_loop
wnd_copy:
    movzx eax, word ptr [r10]
    test eax, eax
    jz wnd_done
    mov [rdi], ax
    add rdi, 2
    add r10, 2
    jmp wnd_copy
wnd_done:
    ret
WNumDec ENDP

; ------------------------------------------------------------
; IsVideoFile(rcx = path) -> eax = 1/0
;   扩展名表与 c/media.c 一致：mp4/mov/avi/wmv/mkv/webm/m4v
;   大小写不敏感；内部无调用
; ------------------------------------------------------------
IsVideoFile PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h                   ; 3 push(24)+32 = 56；8-56 ≡ 0 ✓
    mov rsi, rcx
    xor ebx, ebx                   ; 最后一个 '.' 的位置
ivf_scan:
    movzx eax, word ptr [rsi]
    test eax, eax
    jz ivf_scandone
    cmp eax, '.'
    jne ivf_next
    mov rbx, rsi
ivf_next:
    add rsi, 2
    jmp ivf_scan
ivf_scandone:
    test rbx, rbx
    jz ivf_no
    lea rdi, extTable
    mov ecx, 7
ivf_extloop:
    mov rdx, [rdi]
    mov rsi, rbx
ivf_cmp:
    movzx eax, word ptr [rsi]
    movzx r10d, word ptr [rdx]
    cmp eax, 'A'
    jb ivf_a1
    cmp eax, 'Z'
    ja ivf_a1
    add eax, 20h
ivf_a1:
    cmp r10d, 'A'
    jb ivf_a2
    cmp r10d, 'Z'
    ja ivf_a2
    add r10d, 20h
ivf_a2:
    cmp eax, r10d
    jne ivf_nextext
    test eax, eax
    jz ivf_yes
    add rsi, 2
    add rdx, 2
    jmp ivf_cmp
ivf_nextext:
    add rdi, 8
    dec ecx
    jnz ivf_extloop
ivf_no:
    xor eax, eax
    jmp ivf_done
ivf_yes:
    mov eax, 1
ivf_done:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
IsVideoFile ENDP

; ------------------------------------------------------------
; DpLog - 视频链路日志（tag=[d3d]，hr 为真实值）
;   入口：g_a1 = msg 宽串, g_a2 = hr
; ------------------------------------------------------------
DpLog PROC
    sub rsp, 28h
    mov rax, g_a2
    mov g_a3, rax
    mov rax, g_a1
    mov g_a2, rax
    lea rax, szTagD3d
    mov g_a1, rax
    call LogLine
    add rsp, 28h
    ret
DpLog ENDP

; ------------------------------------------------------------
; BuildInitInfo - 拼 "init ok %ux%u %ums %s %s" 到 g_dmsg
; ------------------------------------------------------------
BuildInitInfo PROC
    sub rsp, 28h
    lea rdi, g_dmsg
    lea rsi, szInitOk
    call CopyWide
    mov ecx, g_vw
    call WNumDec
    WCHR2 'x'
    mov ecx, g_vh
    call WNumDec
    WCHR2 ' '
    mov ecx, g_frameMs
    call WNumDec
    lea rsi, szMs
    call CopyWide
    cmp g_upIsNv12, 0
    je bii_rgb
    lea rsi, szNv12
    jmp bii_fmt
bii_rgb:
    lea rsi, szRgb32
bii_fmt:
    call CopyWide
    WCHR2 ' '
    cmp g_hwDecode, 0
    je bii_soft
    lea rsi, szDxva
    jmp bii_dec
bii_soft:
    lea rsi, szSoft
bii_dec:
    call CopyWide
    mov word ptr [rdi], 0
    add rsp, 28h
    ret
BuildInitInfo ENDP

; ------------------------------------------------------------
; BuildEosInfo - 拼 "eos ts=%u.%02u loop=%u%s" 到 g_dmsg
;   （C 版 %.2f 的等价值整数实现，秒.厘秒）
; ------------------------------------------------------------
BuildEosInfo PROC
    sub rsp, 28h
    lea rdi, g_dmsg
    lea rsi, szEosTs
    call CopyWide
    mov rax, g_lastTs
    test rax, rax
    jns bei_a
    xor eax, eax
bei_a:
    mov g_tsCalc, rax
    xor edx, edx
    mov ecx, 10000000
    div rcx                        ; rax = 秒, rdx = 余数(100ns)
    mov g_tsRem, rdx
    mov ecx, eax
    call WNumDec
    WCHR2 '.'
    mov rax, g_tsRem
    xor edx, edx
    mov ecx, 100000
    div ecx                        ; eax = 厘秒 (0..99)
    mov ecx, eax
    call WNum2
    lea rsi, szEosLoop
    call CopyWide
    mov ecx, g_loopCount
    call WNumDec
    cmp g_loopProbs, 0
    je bei_nosuffix
    lea rsi, szEosProbs
    call CopyWide
    jmp bei_end
bei_nosuffix:
    lea rsi, szEosOk
    call CopyWide
bei_end:
    mov word ptr [rdi], 0
    add rsp, 28h
    ret
BuildEosInfo ENDP

; ------------------------------------------------------------
; CreateReader(rcx = path, rdx = useDxva) -> rax = IMFSourceReader or 0
;   DXVA 模式：RGB32 优先（强制转换 MFT 把 GPU 纹理下系统内存），
;     NV12 备选；软解模式反过来。
;   中文路径必须走 MFCreateFile 字节流（FromURL 实测解析异常）。
; ------------------------------------------------------------
CreateReader PROC
    sub rsp, 28h
    mov g_crPath, rcx
    mov g_crDxva, edx
    lea rax, g_attr
    CALLV MFCreateAttributes, rax, 4
    test eax, eax
    js cr_fail0
    cmp g_attr, 0
    je cr_fail0
    cmp g_crDxva, 0
    je cr_nodxva
    cmp g_dxm, 0
    je cr_nodxva
    mov rax, g_attr
    mov g_a1, rax
    lea rax, ga_ReaderD3DMgr
    mov g_a2, SLOT_AttrSetUnknown
    mov g_a3, rax
    mov rax, g_dxm
    mov g_a4, rax
    call CC2
    mov rax, g_attr
    mov g_a1, rax
    lea rax, ga_HwXforms
    mov g_a2, SLOT_AttrSetUINT32
    mov g_a3, rax
    mov rax, 1
    mov g_a4, rax
    call CC2
cr_nodxva:
    mov rax, MF_ACCESSMODE_READ
    mov g_a1, rax
    xor eax, eax
    mov g_a2, rax                   ; MF_OPENMODE_FAIL_IF_NOT_EXIST = 0
    mov g_a3, rax                   ; MF_FILEFLAGS_NONE = 0
    mov rax, g_crPath
    mov g_a4, rax
    lea rax, g_stream
    mov g_a5, rax
    call HMFCreateFile
    test eax, eax
    js cr_fail0
    cmp g_stream, 0
    je cr_fail0
    mov rax, g_stream
    mov rcx, rax
    mov rdx, g_attr
    lea r8, g_crReader
    call MFCreateSourceReaderFromByteStream
    mov g_hrTmp, eax
    lea rcx, g_stream
    call ReleaseClear
    lea rcx, g_attr
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    js cr_fail0
    cmp g_crReader, 0
    je cr_fail0
    mov rax, g_crReader
    mov g_a1, rax
    mov rax, MF_SRCREADER_ALL_STREAMS
    mov g_a2, SLOT_SetStreamSelection
    mov g_a3, rax
    mov g_a4, 0
    call CC2
    mov rax, g_crReader
    mov g_a1, rax
    mov rax, MF_SRCREADER_FIRST_VIDEO
    mov g_a2, SLOT_SetStreamSelection
    mov g_a3, rax
    mov rax, 1
    mov g_a4, rax
    call CC2
    ; 首选/备选 subtype
    cmp g_crDxva, 0
    je cr_softfirst
    lea rax, gv_RGB32
    mov g_firstSub, rax
    lea rax, gv_NV12
    mov g_secondSub, rax
    jmp cr_havesubs
cr_softfirst:
    lea rax, gv_NV12
    mov g_firstSub, rax
    lea rax, gv_RGB32
    mov g_secondSub, rax
cr_havesubs:
    ; ---- 首选类型 ----
    lea rax, g_mt2
    CALLV MFCreateMediaType, rax
    test eax, eax
    js cr_relreader
    cmp g_mt2, 0
    je cr_relreader
    mov rax, g_mt2
    mov g_a1, rax
    lea rax, ga_MajorType
    mov g_a2, SLOT_AttrSetGUID
    mov g_a3, rax
    lea rax, ga_MediaTypeVideo
    mov g_a4, rax
    call CC2
    mov rax, g_mt2
    mov g_a1, rax
    lea rax, ga_SubType
    mov g_a2, SLOT_AttrSetGUID
    mov g_a3, rax
    mov rax, g_firstSub
    mov g_a4, rax
    call CC2
    mov rax, g_crReader
    mov g_a1, rax
    mov rax, MF_SRCREADER_FIRST_VIDEO
    mov g_a2, SLOT_SetCurrentMediaType
    mov g_a3, rax
    mov g_a4, 0
    mov rax, g_mt2
    mov g_a5, rax
    call CC3
    mov g_hrTmp, eax
    lea rcx, g_mt2
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    jns cr_ok
    ; ---- 备选类型 ----
    lea rax, g_mt2
    CALLV MFCreateMediaType, rax
    test eax, eax
    js cr_relreader
    cmp g_mt2, 0
    je cr_relreader
    mov rax, g_mt2
    mov g_a1, rax
    lea rax, ga_MajorType
    mov g_a2, SLOT_AttrSetGUID
    mov g_a3, rax
    lea rax, ga_MediaTypeVideo
    mov g_a4, rax
    call CC2
    mov rax, g_mt2
    mov g_a1, rax
    lea rax, ga_SubType
    mov g_a2, SLOT_AttrSetGUID
    mov g_a3, rax
    mov rax, g_secondSub
    mov g_a4, rax
    call CC2
    mov rax, g_crReader
    mov g_a1, rax
    mov rax, MF_SRCREADER_FIRST_VIDEO
    mov g_a2, SLOT_SetCurrentMediaType
    mov g_a3, rax
    mov g_a4, 0
    mov rax, g_mt2
    mov g_a5, rax
    call CC3
    mov g_hrTmp, eax
    lea rcx, g_mt2
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    jns cr_ok
cr_relreader:
    lea rcx, g_crReader
    call ReleaseClear
cr_fail0:
    lea rcx, g_attr
    call ReleaseClear               ; 幂等（早期失败时为 0）
    xor eax, eax
    jmp cr_done
cr_ok:
    mov rax, g_crReader
cr_done:
    add rsp, 28h
    ret
CreateReader ENDP

; ------------------------------------------------------------
; ReleaseDrawChain - 释放交换链/DComp/VP 视图（保 reader/设备）
; ------------------------------------------------------------
ReleaseDrawChain PROC
    sub rsp, 28h
    lea rcx, g_inView
    call ReleaseClear
    lea rcx, g_outView
    call ReleaseClear
    lea rcx, g_vp
    call ReleaseClear
    lea rcx, g_vpe
    call ReleaseClear
    lea rcx, g_visual
    call ReleaseClear
    lea rcx, g_target
    call ReleaseClear
    lea rcx, g_dcomp
    call ReleaseClear
    lea rcx, g_swap
    call ReleaseClear
    add rsp, 28h
    ret
ReleaseDrawChain ENDP

; ------------------------------------------------------------
; BuildDrawChain -> eax = 1/0
;   顺序与 C 版一致：Composition 交换链 → DComp 目标/视觉/提交
;   → VideoProcessor 枚举器/处理器/输入视图/输出视图 → 矩形+色彩空间。
;   g_scW/g_scH 仅在全部成功后才提交（失败保持旧值让 PumpFrame 重试）。
; ------------------------------------------------------------
BuildDrawChain PROC
    sub rsp, 28h
    call ReleaseDrawChain
    cmp g_dev, 0
    je bdc_fail
    cmp g_vd, 0
    je bdc_fail
    cmp g_vhwnd, 0
    je bdc_fail
    cmp g_vw, 0
    je bdc_fail
    ; ---- 目标尺寸（客户区，失败回主屏）----
    lea rax, g_rc
    CALLV GetClientRect, g_vhwnd, rax
    mov eax, dword ptr g_rc[8]
    sub eax, dword ptr g_rc[0]
    mov g_bw, eax
    mov eax, dword ptr g_rc[12]
    sub eax, dword ptr g_rc[4]
    mov g_bh, eax
    cmp g_bw, 0
    jg bdc_haveSize
    CALLV GetSystemMetrics, SM_CXSCREEN
    mov g_bw, eax
    CALLV GetSystemMetrics, SM_CYSCREEN
    mov g_bh, eax
bdc_haveSize:
    cmp g_bw, 0
    je bdc_fail
    cmp g_bh, 0
    je bdc_fail
    ; ---- Composition 交换链（FLIP_SEQUENTIAL + AlphaMode IGNORE）----
    lea rdi, g_sd1
    xor eax, eax
    mov ecx, 6
    rep stosq
    mov eax, g_bw
    mov dword ptr g_sd1[0], eax
    mov eax, g_bh
    mov dword ptr g_sd1[4], eax
    mov dword ptr g_sd1[8], DXGI_FORMAT_B8G8R8A8_UNORM
    mov dword ptr g_sd1[16], 1                 ; SampleDesc.Count
    mov dword ptr g_sd1[24], DXGI_USAGE_RENDER_TARGET_OUTPUT
    mov dword ptr g_sd1[28], 2                 ; BufferCount
    mov dword ptr g_sd1[36], DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL
    mov dword ptr g_sd1[40], DXGI_ALPHA_MODE_IGNORE
    lea rax, gi_DxgiFact2
    lea r10, g_fact2
    CALLV CreateDXGIFactory1, rax, r10
    test eax, eax
    js bdc_fail
    cmp g_fact2, 0
    je bdc_fail
    mov rax, g_fact2
    mov g_a1, rax
    mov g_a2, SLOT_CreateSwapChainForComp
    mov rax, g_dev
    mov g_a3, rax
    lea rax, g_sd1
    mov g_a4, rax
    mov g_a5, 0
    lea rax, g_swap
    mov g_a6, rax
    call CC4
    mov g_hrTmp, eax
    lea rcx, g_fact2
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    js bdc_fail
    cmp g_swap, 0
    je bdc_fail
    ; ---- DComp：设备 → 目标(绑壁纸窗口) → 视觉(内容=交换链) → 提交 ----
    ; 注意：DCompositionCreateDevice 首参是 IDXGIDevice 对象指针本身（值），不是 &变量
    ; （曾误传 lea &g_dxgiDev → dcomp 两层解引用把 vtable 指针当函数调用，rip=vtable 数据地址 AV）
    mov rax, g_dev
    mov g_a1, rax
    lea rax, gi_DxgiDev
    mov g_a2, SLOT_QI
    mov g_a3, rax
    lea rax, g_dxgiDev
    mov g_a4, rax
    call CC2
    test eax, eax
    js bdc_failqi
    cmp g_dxgiDev, 0
    je bdc_failqi
    mov rax, g_dxgiDev
    lea r10, gi_DcompDev
    lea r11, g_dcomp
    CALLV DCompositionCreateDevice, rax, r10, r11
    mov g_hrTmp, eax
    lea rcx, g_dxgiDev
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    js bdc_faildcomp
    mov rax, g_dcomp
    mov g_a1, rax
    mov g_a2, SLOT_DCompCreateTarget
    mov rax, g_vhwnd
    mov g_a3, rax
    mov rax, 1
    mov g_a4, rax
    lea rax, g_target
    mov g_a5, rax
    call CC3
    test eax, eax
    js bdc_failtarget
    mov rax, g_dcomp
    mov g_a1, rax
    mov g_a2, SLOT_DCompCreateVisual
    lea rax, g_visual
    mov g_a3, rax
    call CC1
    test eax, eax
    js bdc_failvisual
    mov rax, g_visual
    mov g_a1, rax
    mov g_a2, SLOT_DCompVisualSetContent
    mov rax, g_swap
    mov g_a3, rax
    call CC1
    test eax, eax
    js bdc_failcontent
    mov rax, g_target
    mov g_a1, rax
    mov g_a2, SLOT_DCompTargetSetRoot
    mov rax, g_visual
    mov g_a3, rax
    call CC1
    test eax, eax
    js bdc_failroot
    mov rax, g_dcomp
    mov g_a1, rax
    mov g_a2, SLOT_DCompCommit
    call CC0
    test eax, eax
    js bdc_failcommit
    lea rax, szSwapchainDcomp
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    ; ---- VideoProcessor ----
    lea rdi, g_cd
    xor eax, eax
    mov ecx, 5
    rep stosq
    mov dword ptr g_cd[0], 0                   ; PROGRESSIVE
    mov eax, g_vw
    mov dword ptr g_cd[12], eax                ; InputWidth
    mov eax, g_vh
    mov dword ptr g_cd[16], eax                ; InputHeight
    mov eax, g_bw
    mov dword ptr g_cd[28], eax                ; OutputWidth
    mov eax, g_bh
    mov dword ptr g_cd[32], eax                ; OutputHeight
    mov dword ptr g_cd[36], 0                  ; PLAYBACK_NORMAL
    mov rax, g_vd
    mov g_a1, rax
    lea rax, g_cd
    mov g_a2, SLOT_CreateVPEnumerator
    mov g_a3, rax
    lea rax, g_vpe
    mov g_a4, rax
    call CC2
    test eax, eax
    js bdc_failvp
    mov rax, g_vd
    mov g_a1, rax
    mov g_a2, SLOT_CreateVideoProcessor
    mov rax, g_vpe
    mov g_a3, rax
    mov g_a4, 0
    lea rax, g_vp
    mov g_a5, rax
    call CC3
    test eax, eax
    js bdc_failvp
    cmp g_vp, 0
    je bdc_failvp
    ; ---- 输入视图（绑定上传纹理；FourCC 必须显式声明否则采样全黑）----
    lea rdi, g_ivd
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov eax, g_upIsNv12
    test eax, eax
    jz bdc_ivd0
    mov dword ptr g_ivd[0], FOURCC_NV12
bdc_ivd0:
    mov dword ptr g_ivd[4], D3D11_VPIV_DIMENSION_TEXTURE2D
    mov dword ptr g_ivd[8], 0                  ; MipSlice
    mov dword ptr g_ivd[12], 0                 ; ArraySlice
    mov rax, g_vd
    mov g_a1, rax
    mov g_a2, SLOT_CreateVPInputView
    mov rax, g_upTex
    mov g_a3, rax
    mov rax, g_vpe
    mov g_a4, rax
    lea rax, g_ivd
    mov g_a5, rax
    lea rax, g_inView
    mov g_a6, rax
    call CC4
    test eax, eax
    js bdc_failview
    ; ---- 输出视图（交换链后备缓冲）----
    mov rax, g_swap
    mov g_a1, rax
    mov g_a2, SLOT_GetBuffer
    mov g_a3, 0
    lea rax, gi_Tex2D
    mov g_a4, rax
    lea rax, g_bb
    mov g_a5, rax
    call CC3
    test eax, eax
    js bdc_failview
    lea rdi, g_ovd
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov dword ptr g_ovd[0], D3D11_VPOV_DIMENSION_TEXTURE2D
    mov rax, g_vd
    mov g_a1, rax
    mov g_a2, SLOT_CreateVPOutputView
    mov rax, g_bb
    mov g_a3, rax
    mov rax, g_vpe
    mov g_a4, rax
    lea rax, g_ovd
    mov g_a5, rax
    lea rax, g_outView
    mov g_a6, rax
    call CC4
    mov g_hrTmp, eax
    lea rcx, g_bb
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    js bdc_failview
    cmp g_inView, 0
    je bdc_failview
    cmp g_outView, 0
    je bdc_failview
    ; ---- 源/目标矩形铺满 + 色彩空间 ----
    mov dword ptr g_srect[0], 0
    mov dword ptr g_srect[4], 0
    mov eax, g_vw
    mov dword ptr g_srect[8], eax
    mov eax, g_vh
    mov dword ptr g_srect[12], eax
    mov dword ptr g_drect[0], 0
    mov dword ptr g_drect[4], 0
    mov eax, g_bw
    mov dword ptr g_drect[8], eax
    mov eax, g_bh
    mov dword ptr g_drect[12], eax
    mov rax, g_vc
    mov g_a1, rax
    mov g_a2, SLOT_VPSetStreamSourceRect
    mov rax, g_vp
    mov g_a3, rax
    mov g_a4, 0
    mov rax, 1
    mov g_a5, rax
    lea rax, g_srect
    mov g_a6, rax
    call CC4
    mov rax, g_vc
    mov g_a1, rax
    mov g_a2, SLOT_VPSetStreamDestRect
    mov rax, g_vp
    mov g_a3, rax
    mov g_a4, 0
    mov rax, 1
    mov g_a5, rax
    lea rax, g_drect
    mov g_a6, rax
    call CC4
    mov rax, g_vc
    mov g_a1, rax
    mov g_a2, SLOT_VPSetStreamFrameFormat
    mov rax, g_vp
    mov g_a3, rax
    mov g_a4, 0
    mov g_a5, 0                   ; PROGRESSIVE
    call CC3
    ; 输入色彩空间：Usage=0, RGB_Range=0, Matrix=BT.709(bit2), Nominal=16-235(bit4)
    mov dword ptr g_cs, 14h
    mov rax, g_vc
    mov g_a1, rax
    mov g_a2, SLOT_VPSetStreamColorSpace
    mov rax, g_vp
    mov g_a3, rax
    mov g_a4, 0
    lea rax, g_cs
    mov g_a5, rax
    call CC3
    mov dword ptr g_ocs, 0        ; 输出全量程
    mov rax, g_vc
    mov g_a1, rax
    mov g_a2, SLOT_VPSetOutputColorSpace
    mov rax, g_vp
    mov g_a3, rax
    lea rax, g_ocs
    mov g_a4, rax
    call CC2
    ; ---- 全部成功才提交尺寸 ----
    mov eax, g_bw
    mov g_scW, eax
    mov eax, g_bh
    mov g_scH, eax
    mov eax, 1
    jmp bdc_done
bdc_failqi:
    lea rax, szDcompQi
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_faildcomp:
    lea rax, szDcompCreate
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_failtarget:
    lea rax, szDcompTarget
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_failvisual:
    lea rax, szDcompVisual
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_failcontent:
    lea rax, szDcompContent
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_failroot:
bdc_failcommit:
    lea rax, szDcompCommit
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_failvp:
    lea rax, szVpFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_failview:
    lea rax, szViewFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp bdc_fail
bdc_fail:
    call ReleaseDrawChain
    xor eax, eax
bdc_done:
    add rsp, 28h
    ret
BuildDrawChain ENDP

; ------------------------------------------------------------
; D3DInit(rcx = hwnd, rdx = videoPath) -> eax = 1/0
;   内部先 D3DShutdown；设备（VIDEO+BGRA，失败退级 BGRA）→
;   多线程保护 → video 接口 → DXVA 管理器 → reader → 格式 →
;   上传纹理 → 绘制链。
; ------------------------------------------------------------
D3DInit PROC
    sub rsp, 28h
    mov g_initHwnd, rcx
    mov g_initPath, rdx
    call D3DShutdown
    ; g_vpath = path（循环重建 reader 用）
    mov rsi, g_initPath
    lea rdi, g_vpath
    mov ecx, 519
    rep movsw
    mov word ptr [rdi], 0
    mov rax, g_initHwnd
    mov g_vhwnd, rax
    ; ---- 1) D3D11 设备（VIDEO_SUPPORT | BGRA_SUPPORT）----
    mov g_a1, 0
    mov rax, D3D_DRIVER_TYPE_HARDWARE
    mov g_a2, rax
    mov g_a3, 0
    mov rax, D3D11_CREATE_DEVICE_VIDEO_SUPPORT or D3D11_CREATE_DEVICE_BGRA_SUPPORT
    mov g_a4, rax
    mov g_a5, 0
    mov g_a6, 0
    mov rax, D3D11_SDK_VERSION
    mov g_a7, rax
    lea rax, g_dev
    mov g_a8, rax
    lea rax, g_fl
    mov g_a9, rax
    lea rax, g_ctx
    mov g_a10, rax
    call HD3D11CreateDevice
    test eax, eax
    js di_retry
    cmp g_dev, 0
    jne di_mt
di_retry:
    ; 失败但可能已写出非空对象 → 先释放再退级重试（老驱动无 VIDEO_SUPPORT）
    lea rcx, g_dev
    call ReleaseClear
    lea rcx, g_ctx
    call ReleaseClear
    mov g_a4, D3D11_CREATE_DEVICE_BGRA_SUPPORT
    call HD3D11CreateDevice
    test eax, eax
    js di_faildev
    cmp g_dev, 0
    je di_faildev
di_mt:
    ; ---- 多线程保护（MF 解码工作线程共用 device，否则首帧即 EOS）----
    mov rax, g_dev
    mov g_a1, rax
    lea rax, gi_D3D10MT
    mov g_a2, SLOT_QI
    mov g_a3, rax
    lea rax, g_mt
    mov g_a4, rax
    call CC2
    test eax, eax
    js di_nomt
    cmp g_mt, 0
    je di_nomt
    mov rax, g_mt
    mov g_a1, rax
    mov g_a2, SLOT_SetMultithreadProtected
    mov rax, 1
    mov g_a3, rax
    call CC1
    lea rcx, g_mt
    call ReleaseClear
di_nomt:
    ; ---- video 接口 ----
    mov rax, g_dev
    mov g_a1, rax
    lea rax, gi_VideoDev
    mov g_a2, SLOT_QI
    mov g_a3, rax
    lea rax, g_vd
    mov g_a4, rax
    call CC2
    test eax, eax
    js di_failvideo
    mov rax, g_ctx
    mov g_a1, rax
    lea rax, gi_VideoCtx
    mov g_a2, SLOT_QI
    mov g_a3, rax
    lea rax, g_vc
    mov g_a4, rax
    call CC2
    test eax, eax
    js di_failvideo
    ; ---- 2) DXVA 共享管理器 ----
    lea rax, g_resetToken
    lea r10, g_dxm
    CALLV MFCreateDXGIDeviceManager, rax, r10
    test eax, eax
    js di_nodxm
    mov rax, g_dxm
    mov g_a1, rax
    mov g_a2, SLOT_ResetDevice
    mov rax, g_dev
    mov g_a3, rax
    mov eax, g_resetToken
    mov g_a4, rax
    call CC2
    test eax, eax
    jns di_nodxm
    lea rcx, g_dxm
    call ReleaseClear
di_nodxm:
    ; ---- 3) 解码器：先 DXVA 硬解，失败退软解 ----
    lea rcx, g_vpath
    mov rdx, 1
    call CreateReader
    mov g_reader, rax
    mov g_hwDecode, 1              ; 首次（DXVA）成功 → 硬解标志（对齐 c 版 g_hwDecode=(reader!=NULL)；
    test rax, rax                  ;   曾误置 0 致日志恒报 soft，且 di_hw1 支路成死代码）
    jnz di_haveReader
    ; DXVA 失败 → 退软解（标志清零）
    lea rcx, g_vpath
    xor edx, edx
    call CreateReader
    mov g_reader, rax
    mov g_hwDecode, 0
    test rax, rax
    jnz di_haveReader
    lea rax, szReaderFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    call D3DShutdown
    xor eax, eax
    jmp di_done
di_haveReader:
    ; ---- 4) 输出格式：尺寸/帧率/subtype/时长 ----
    mov rax, g_reader
    mov g_a1, rax
    mov rax, MF_SRCREADER_FIRST_VIDEO
    mov g_a2, SLOT_GetCurrentMediaType
    mov g_a3, rax
    lea rax, g_cur
    mov g_a4, rax
    call CC2
    test eax, eax
    js di_failcurtype
    cmp g_cur, 0
    je di_failcurtype
    ; 帧尺寸（GetUINT64 手动拆包：高32=宽 低32=高）
    mov rax, g_cur
    mov g_a1, rax
    lea rax, ga_FrameSize
    mov g_a2, SLOT_AttrGetUINT64
    mov g_a3, rax
    lea rax, g_packed
    mov g_a4, rax
    call CC2
    test eax, eax
    js di_nosize
    mov rax, g_packed
    shr rax, 32
    mov g_vw, eax
    mov eax, dword ptr g_packed
    mov g_vh, eax
di_nosize:
    ; 帧率
    mov qword ptr g_packed, 0
    mov rax, g_cur
    mov g_a1, rax
    lea rax, ga_FrameRate
    mov g_a2, SLOT_AttrGetUINT64
    mov g_a3, rax
    lea rax, g_packed
    mov g_a4, rax
    call CC2
    test eax, eax
    js di_norate
    mov rax, g_packed
    shr rax, 32
    mov g_num, eax
    mov eax, dword ptr g_packed
    mov g_den, eax
di_norate:
    ; subtype
    mov rax, g_cur
    mov g_a1, rax
    lea rax, ga_SubType
    mov g_a2, SLOT_AttrGetGUID
    mov g_a3, rax
    lea rax, g_subtype
    mov g_a4, rax
    call CC2
    lea rcx, g_cur
    call ReleaseClear
    ; 时长
    lea rdi, g_pv
    xor eax, eax
    mov ecx, 3
    rep stosq
    mov rax, g_reader
    mov g_a1, rax
    mov rax, MF_SRCREADER_MEDIASOURCE
    mov g_a2, SLOT_GetPresentationAttribute
    mov g_a3, rax
    lea rax, ga_Duration
    mov g_a4, rax
    lea rax, g_pv
    mov g_a5, rax
    call CC3
    test eax, eax
    js di_nodur
    movzx eax, word ptr g_pv
    cmp eax, VT_I8
    jne di_nodur
    mov rax, qword ptr g_pv[8]
    mov g_duration, rax
di_nodur:
    cmp g_vw, 0
    je di_failsize
    cmp g_vh, 0
    je di_failsize
    ; upIsNv12 = (subtype == NV12)
    lea rsi, g_subtype
    lea rdi, gv_NV12
    mov ecx, 4
    repe cmpsd
    mov g_upIsNv12, 0
    jne di_notnv12
    mov g_upIsNv12, 1
di_notnv12:
    ; frameMs = 1000*den/num，clamp [10,100]
    mov eax, g_num
    test eax, eax
    jz di_noframems
    mov eax, g_den
    test eax, eax
    jz di_noframems
    mov eax, g_den
    xor edx, edx
    mov ecx, 1000
    mul ecx
    div g_num
    cmp eax, 10
    jae di_fm1
    mov eax, 10
di_fm1:
    cmp eax, 100
    jbe di_fm2
    mov eax, 100
di_fm2:
    mov g_frameMs, eax
di_noframems:
    ; ---- 5) 上传纹理 ----
    lea rdi, g_td
    xor eax, eax
    mov ecx, 5
    rep stosq
    mov dword ptr [rdi], 0
    mov eax, g_vw
    mov dword ptr g_td[0], eax
    mov eax, g_vh
    mov dword ptr g_td[4], eax
    mov dword ptr g_td[8], 1                   ; MipLevels
    mov dword ptr g_td[12], 1                  ; ArraySize
    mov eax, g_upIsNv12
    test eax, eax
    jz di_rgbfmt
    mov dword ptr g_td[16], DXGI_FORMAT_NV12
    jmp di_fmtok
di_rgbfmt:
    mov dword ptr g_td[16], DXGI_FORMAT_B8G8R8A8_UNORM
di_fmtok:
    mov dword ptr g_td[20], 1                  ; SampleDesc.Count
    mov dword ptr g_td[28], D3D11_USAGE_DEFAULT
    mov rax, g_dev
    mov g_a1, rax
    lea rax, g_td
    mov g_a2, SLOT_CreateTexture2D
    mov g_a3, rax
    mov g_a4, 0
    lea rax, g_upTex
    mov g_a5, rax
    call CC3
    test eax, eax
    js di_failtex
    cmp g_upTex, 0
    je di_failtex
    ; ---- 6) 交换链 + VideoProcessor ----
    call BuildDrawChain
    test eax, eax
    jz di_failchain
    call BuildInitInfo
    lea rax, g_dmsg
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    mov g_active, 1
    CALLV GetTickCount64
    mov g_startTick, rax
    mov eax, 1
    jmp di_done
di_faildev:
    lea rax, szDevFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp di_fail
di_failvideo:
    lea rax, szVideoIfacesFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp di_fail
di_failcurtype:
    lea rax, szCurTypeFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp di_fail
di_failsize:
    lea rax, szSizeFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp di_fail
di_failtex:
    lea rax, szUploadTexFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp di_fail
di_failchain:
    lea rax, szCompSwapFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
di_fail:
    call D3DShutdown
    xor eax, eax
di_done:
    add rsp, 28h
    ret
D3DInit ENDP

; ------------------------------------------------------------
; BltVp(rcx = 输入视图) -> eax = 1/0
;   VideoProcessorBlt 合成一帧到交换链后备；失败限频日志
; ------------------------------------------------------------
BltVp PROC
    sub rsp, 28h
    mov g_bltView, rcx
    lea rdi, g_vs
    xor eax, eax
    mov ecx, 9
    rep stosq
    mov dword ptr g_vs[0], 1                   ; Enable = TRUE
    mov rax, g_bltView
    mov qword ptr g_vs[32], rax                 ; pInputSurface（@32，前面有 5 个整型+对齐）
    mov rax, g_vc
    mov g_a1, rax
    mov g_a2, SLOT_VPBlt
    mov rax, g_vp
    mov g_a3, rax
    mov rax, g_outView
    mov g_a4, rax
    mov g_a5, 0                                ; OutputFrame
    mov rax, 1
    mov g_a6, rax                              ; StreamCount
    lea rax, g_vs
    mov g_a7, rax                              ; pStreams
    call CC5
    mov g_hrTmp, eax
    test eax, eax
    jns bv_ok
    mov eax, g_vpbltFailN
    xor edx, edx
    mov ecx, 500
    div ecx
    test edx, edx
    jnz bv_nolog
    lea rax, szVpbltFailed
    mov g_a1, rax
    mov eax, g_hrTmp
    mov g_a2, rax
    call DpLog
bv_nolog:
    inc g_vpbltFailN
    xor eax, eax
    jmp bv_done
bv_ok:
    mov eax, 1
bv_done:
    add rsp, 28h
    ret
BltVp ENDP

; ------------------------------------------------------------
; PresentNow -> eax = 1/0（垂直同步呈现；首帧/失败限频日志）
; ------------------------------------------------------------
PresentNow PROC
    sub rsp, 28h
    mov rax, g_swap
    mov g_a1, rax
    mov g_a2, SLOT_Present
    mov rax, 1
    mov g_a3, rax
    mov g_a4, 0
    call CC2
    mov g_hrTmp, eax
    cmp g_presentLogged, 0
    jne pn_checkfail
    mov g_presentLogged, 1
    lea rax, szFirstPresent
    mov g_a1, rax
    mov eax, g_hrTmp
    mov g_a2, rax
    call DpLog
pn_checkfail:
    mov eax, g_hrTmp
    test eax, eax
    jns pn_ok
    mov eax, g_presentFailN
    xor edx, edx
    mov ecx, 500
    div ecx
    test edx, edx
    jnz pn_nolog
    lea rax, szPresentFailed
    mov g_a1, rax
    mov eax, g_hrTmp
    mov g_a2, rax
    call DpLog
pn_nolog:
    inc g_presentFailN
    xor eax, eax
    jmp pn_done
pn_ok:
    mov eax, 1
pn_done:
    add rsp, 28h
    ret
PresentNow ENDP

; ------------------------------------------------------------
; DrawSample(rcx = IMFSample, rdx = present) -> eax = 1/0
;   路径 1：DXVA 零拷贝（buffer 直接封装 GPU 纹理）
;   路径 2：系统内存 Lock2D/Lock → UpdateSubresource 上传
; ------------------------------------------------------------
DrawSample PROC
    sub rsp, 28h
    test rcx, rcx
    jz ds_zero
    cmp g_outView, 0
    je ds_zero
    mov g_sample, rcx
    mov g_present, edx
    ; ConvertToContiguousBuffer
    mov rax, g_sample
    mov g_a1, rax
    mov g_a2, SLOT_ConvertToContiguousBuffer
    lea rax, g_buf
    mov g_a3, rax
    call CC1
    test eax, eax
    js ds_zero
    cmp g_buf, 0
    je ds_zero
    ; ---- 路径 1：DXVA 零拷贝 ----
    mov rax, g_buf
    mov g_a1, rax
    lea rax, gi_MfDxgiBuf
    mov g_a2, SLOT_QI
    mov g_a3, rax
    lea rax, g_dxb
    mov g_a4, rax
    call CC2
    test eax, eax
    js ds_path2
    cmp g_dxb, 0
    je ds_path2
    mov rax, g_dxb
    mov g_a1, rax
    lea rax, gi_Tex2D
    mov g_a2, SLOT_GetResource
    mov g_a3, rax
    lea rax, g_tmpTex
    mov g_a4, rax
    call CC2
    test eax, eax
    js ds_dxbfail
    cmp g_tmpTex, 0
    je ds_dxbfail
    mov rax, g_dxb
    mov g_a1, rax
    mov g_a2, SLOT_GetSubresourceIndex
    lea rax, g_rsub
    mov g_a3, rax
    call CC1
    test eax, eax
    js ds_texrel
    ; 输入视图描述（FourCC 必须显式声明，否则采样全黑）
    lea rdi, g_ivd
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov eax, g_upIsNv12
    test eax, eax
    jz ds_fourcc0
    mov dword ptr g_ivd[0], FOURCC_NV12
ds_fourcc0:
    mov dword ptr g_ivd[4], D3D11_VPIV_DIMENSION_TEXTURE2D
    mov dword ptr g_ivd[8], 0
    mov eax, g_rsub
    mov dword ptr g_ivd[12], eax
    mov rax, g_vd
    mov g_a1, rax
    mov g_a2, SLOT_CreateVPInputView
    mov rax, g_tmpTex
    mov g_a3, rax
    mov rax, g_vpe
    mov g_a4, rax
    lea rax, g_ivd
    mov g_a5, rax
    lea rax, g_tmpView
    mov g_a6, rax
    call CC4
    test eax, eax
    js ds_texrel
    cmp g_tmpView, 0
    je ds_texrel
    mov rcx, g_tmpView
    call BltVp
    mov g_hrTmp, eax
    cmp g_zerocopyLogged, 0
    jne ds_zc1
    mov g_zerocopyLogged, 1
    lea rax, szZerocopyPath
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
ds_zc1:
    lea rcx, g_tmpView
    call ReleaseClear
    lea rcx, g_tmpTex
    call ReleaseClear
    lea rcx, g_dxb
    call ReleaseClear
    lea rcx, g_buf
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    jz ds_zero
    cmp g_present, 0
    je ds_ret_ok
    call PresentNow
    jmp ds_done
ds_texrel:
    lea rcx, g_tmpTex
    call ReleaseClear
ds_dxbfail:
    lea rcx, g_dxb
    call ReleaseClear
ds_path2:
    ; ---- 路径 2：系统内存上传 ----
    cmp g_upTex, 0
    je ds_relbuf
    cmp g_inView, 0
    je ds_relbuf
    mov g_b2d, 0
    mov g_locked2d, 0
    ; 先试 IMF2DBuffer::Lock2D
    mov rax, g_buf
    mov g_a1, rax
    lea rax, gi_Mf2DBuf
    mov g_a2, SLOT_QI
    mov g_a3, rax
    lea rax, g_b2d
    mov g_a4, rax
    call CC2
    test eax, eax
    js ds_plainlock
    cmp g_b2d, 0
    je ds_plainlock
    mov rax, g_b2d
    mov g_a1, rax
    mov g_a2, SLOT_Lock2D
    lea rax, g_pix
    mov g_a3, rax
    lea rax, g_pitch
    mov g_a4, rax
    call CC2
    test eax, eax
    js ds_b2drel
    mov g_locked2d, 1
    ; 负 stride = bottom-up：翻行序
    mov eax, g_pitch
    test eax, eax
    jns ds_locked
    neg eax
    mov g_pitch, eax
    mov ecx, g_vh
    dec ecx
    imul rax, rcx
    add g_pix, rax
    jmp ds_locked
ds_b2drel:
    lea rcx, g_b2d
    call ReleaseClear
ds_plainlock:
    ; 退路：普通 Lock + 宽度推 stride
    mov rax, g_buf
    mov g_a1, rax
    mov g_a2, SLOT_BufLock
    lea rax, g_pix
    mov g_a3, rax
    mov g_a4, 0
    lea rax, g_len
    mov g_a5, rax
    call CC3
    test eax, eax
    js ds_relbuf
    cmp g_pix, 0
    je ds_relbuf
    mov eax, g_upIsNv12
    test eax, eax
    jz ds_plainrgb
    mov eax, g_vw
    mov g_pitch, eax
    jmp ds_locked
ds_plainrgb:
    mov eax, g_vw
    shl eax, 2
    mov g_pitch, eax
ds_locked:
    ; 上传（NV12 两个平面 / RGB32 一个）
    mov eax, g_upIsNv12
    test eax, eax
    jz ds_rgb_upload
    mov rax, g_ctx
    mov g_a1, rax
    mov rax, g_upTex
    mov g_a2, SLOT_UpdateSubresource
    mov g_a3, rax
    mov g_a4, 0                                ; subresource 0 = Y
    mov g_a5, 0                                ; box
    mov rax, g_pix
    mov g_a6, rax
    mov eax, g_pitch
    mov g_a7, rax
    mov g_a8, 0                                ; depth
    call CC6
    mov eax, g_pitch
    mov ecx, g_vh
    imul rax, rcx
    add rax, g_pix
    mov g_uvptr, rax
    mov rax, g_ctx
    mov g_a1, rax
    mov rax, g_upTex
    mov g_a2, SLOT_UpdateSubresource
    mov g_a3, rax
    mov rax, 1
    mov g_a4, rax                              ; subresource 1 = UV
    mov g_a5, 0
    mov rax, g_uvptr
    mov g_a6, rax
    mov eax, g_pitch
    mov g_a7, rax
    mov g_a8, 0
    call CC6
    jmp ds_uploaded
ds_rgb_upload:
    mov rax, g_ctx
    mov g_a1, rax
    mov rax, g_upTex
    mov g_a2, SLOT_UpdateSubresource
    mov g_a3, rax
    mov g_a4, 0
    mov g_a5, 0
    mov rax, g_pix
    mov g_a6, rax
    mov eax, g_pitch
    mov g_a7, rax
    mov g_a8, 0
    call CC6
ds_uploaded:
    ; 解锁
    cmp g_locked2d, 0
    je ds_plainunlock
    mov rax, g_b2d
    mov g_a1, rax
    mov g_a2, SLOT_Unlock2D
    call CC0
    lea rcx, g_b2d
    call ReleaseClear
    jmp ds_relbuf
ds_plainunlock:
    mov rax, g_buf
    mov g_a1, rax
    mov g_a2, SLOT_BufUnlock
    call CC0
ds_relbuf:
    lea rcx, g_buf
    call ReleaseClear
    ; GPU 转换 + 缩放
    mov rcx, g_inView
    call BltVp
    test eax, eax
    jz ds_zero
    cmp g_present, 0
    je ds_ret_ok
    call PresentNow
    jmp ds_done
ds_ret_ok:
    mov eax, 1
    jmp ds_done
ds_zero:
    xor eax, eax
ds_done:
    add rsp, 28h
    ret
DrawSample ENDP

; ------------------------------------------------------------
; D3DPumpFrame -> eax = 下一 tick 间隔(ms)
;   按墙上时钟追帧 + EOS 无缝循环（seek 回开头，交换链保留帧）
; ------------------------------------------------------------
D3DPumpFrame PROC
    sub rsp, 28h
    cmp g_active, 0
    je dp_idle
    cmp g_reader, 0
    je dp_idle
    ; 延迟 trim（播放稳定后归还备用页）
    cmp g_trimmed, 0
    jne dp_notrim
    cmp g_startTick, 0
    je dp_notrim
    CALLV GetTickCount64
    sub rax, g_startTick
    cmp rax, 15000
    jbe dp_notrim
    mov g_trimmed, 1
    CALLV GetCurrentProcess
    mov g_a1, rax
    mov rax, -1
    mov g_a2, rax
    mov g_a3, rax
    CALLV SetProcessWorkingSetSize, g_a1, g_a2, g_a3
dp_notrim:
    ; 窗口尺寸变了 → 重建交换链自适应
    cmp g_vhwnd, 0
    je dp_nosize
    CALLV IsWindow, g_vhwnd
    test eax, eax
    jz dp_nosize
    lea rax, g_rc
    CALLV GetClientRect, g_vhwnd, rax
    mov eax, dword ptr g_rc[8]
    sub eax, dword ptr g_rc[0]
    mov g_bw, eax
    mov eax, dword ptr g_rc[12]
    sub eax, dword ptr g_rc[4]
    mov g_bh, eax
    cmp g_bw, 0
    jle dp_nosize
    cmp g_bh, 0
    jle dp_nosize
    mov eax, g_bw
    cmp eax, g_scW
    jne dp_resize
    mov eax, g_bh
    cmp eax, g_scH
    jne dp_resize
    jmp dp_nosize
dp_resize:
    call BuildDrawChain
dp_nosize:
    ; ---- 追帧时钟 ----
    CALLV GetTickCount64
    mov g_now64, rax
    cmp g_startWall, 0
    jne dp_havewall
    mov rax, g_now64
    mov g_startWall, rax
    mov g_lastTs, -1
dp_havewall:
    mov rax, g_now64
    sub rax, g_startWall
    imul rax, rax, 10000
    add rax, g_startTs
    mov g_vTarget, rax
    mov g_drawn, 0
dp_loop:
    mov rax, g_lastTs
    cmp rax, g_vTarget
    jge dp_loopdone
    cmp g_drawn, 4
    jge dp_loopdone
    cmp g_reader, 0
    je dp_loopdone
    mov rax, g_reader
    mov g_a1, rax
    mov rax, MF_SRCREADER_FIRST_VIDEO
    mov g_a2, SLOT_ReadSample
    mov g_a3, rax
    mov g_a4, 0                                ; controlFlags
    mov g_a5, 0                                ; actualStreamIndex
    lea rax, g_flags
    mov g_a6, rax
    lea rax, g_ts
    mov g_a7, rax
    lea rax, g_sample
    mov g_a8, rax
    call CC6
    mov g_hrTmp, eax
    test eax, eax
    js dp_readfail
    mov eax, g_flags
    and eax, MF_SRCREADERF_EOFS
    jz dp_havesample
    jmp dp_eos
dp_havesample:
    cmp g_sample, 0
    je dp_loopdone                             ; STREAMTICK 空帧：等下个 tick
    mov rcx, g_sample
    mov rdx, 0
    call DrawSample
    mov g_hrTmp, eax
    lea rcx, g_sample
    call ReleaseClear
    mov eax, g_hrTmp
    test eax, eax
    jz dp_loopdone
    mov rax, g_ts
    mov g_lastTs, rax
    mov g_loopRetry, 0
    inc g_drawn
    jmp dp_loop
dp_readfail:
    lea rax, szReadsampleFailed
    mov g_a1, rax
    mov eax, g_hrTmp
    mov g_a2, rax
    call DpLog
    mov g_active, 0
    mov eax, 16
    jmp dp_done
dp_eos:
    cmp g_sample, 0
    je dp_eos1
    lea rcx, g_sample
    call ReleaseClear
dp_eos1:
    ; ★ 无缝循环：seek 回开头，渲染管线不中断、交换链保留画面
    ; 分级回退：seek(0) → seek(1) 强制真 seek → 重建 reader
    mov g_pvpos, 0
    cmp g_loopRetry, 0
    je dp_seekpos
    mov g_pvpos, 1
dp_seekpos:
    lea rdi, g_pv
    xor eax, eax
    mov ecx, 3
    rep stosq
    mov word ptr g_pv[0], VT_I8
    mov eax, g_pvpos
    mov dword ptr g_pv[8], eax                 ; hVal.QuadPart 低 32（高 32 已清零）
    mov rax, g_reader
    mov g_a1, rax
    mov g_a2, SLOT_SetCurrentPosition
    lea rax, g_guidNull
    mov g_a3, rax
    lea rax, g_pv
    mov g_a4, rax
    call CC2
    mov g_hrTmp, eax
    ; loopProbs = FAILED(hr) || loopRetry >= 2
    mov g_loopProbs, 0
    test eax, eax
    js dp_lp1
    cmp g_loopRetry, 2
    jb dp_lp2
dp_lp1:
    mov g_loopProbs, 1
dp_lp2:
    cmp g_loopProbs, 0
    je dp_seekok
    ; 重建 reader
    lea rcx, g_vpath
    mov rdx, 1
    call CreateReader
    mov g_nreader, rax
    test rax, rax
    jnz dp_nr1
    lea rcx, g_vpath
    xor edx, edx
    call CreateReader
    mov g_nreader, rax
    test rax, rax
    jnz dp_nr1
    lea rax, szLoopRebuildFailed
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    mov g_active, 0
    mov eax, 500
    jmp dp_done
dp_nr1:
    lea rcx, g_reader
    call ReleaseClear
    mov rax, g_nreader
    mov g_reader, rax
    lea rax, szLoopReaderRebuilt
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
    jmp dp_loopcount
dp_seekok:
    inc g_loopRetry
dp_loopcount:
    inc g_loopCount
    ; 循环日志限频：异常路径 / 首轮 / 每 500 轮
    mov eax, g_loopCount
    cmp eax, 1
    je dp_eoslog
    xor edx, edx
    mov ecx, 500
    div ecx
    test edx, edx
    jz dp_eoslog
    cmp g_loopProbs, 0
    jne dp_eoslog
    jmp dp_eosnolog
dp_eoslog:
    call BuildEosInfo
    lea rax, g_dmsg
    mov g_a1, rax
    mov g_a2, 0
    call DpLog
dp_eosnolog:
    ; 重置播放时钟：从新一轮第 0ms 起算
    mov rax, g_now64
    mov g_startWall, rax
    mov g_startTs, 0
    mov g_lastTs, -1
    mov g_vTarget, 0
    ; ★ 必须 break 不能 continue：target=0/lastTs=-1 会让循环条件恒真，
    ; 源在 seek 后仍持续 EOS 时退化为无界自旋，看门狗与 quit 握手全部失效。
    jmp dp_present
dp_loopdone:
dp_present:
    cmp g_swap, 0
    je dp_ret8
    call PresentNow
dp_ret8:
    mov eax, 8
    jmp dp_done
dp_idle:
    mov eax, 33
dp_done:
    add rsp, 28h
    ret
D3DPumpFrame ENDP

; ------------------------------------------------------------
; D3DSetWindow(rcx = hwnd) - 窗口重建/重绑定后换绘制链目标
; ------------------------------------------------------------
D3DSetWindow PROC
    sub rsp, 28h
    test rcx, rcx
    jz dsw_done
    cmp rcx, g_vhwnd
    je dsw_done
    mov g_vhwnd, rcx
    cmp g_dev, 0
    je dsw_done
    call BuildDrawChain
dsw_done:
    add rsp, 28h
    ret
D3DSetWindow ENDP

; ------------------------------------------------------------
; D3DShutdown - 全量释放（reader/绘制链/设备），状态复位
; ------------------------------------------------------------
D3DShutdown PROC
    sub rsp, 28h
    mov g_active, 0
    mov g_trimmed, 0
    mov g_startTick, 0
    mov g_loopCount, 0
    mov g_lastTs, 0
    mov g_startWall, 0
    mov g_startTs, 0
    mov g_loopRetry, 0
    call ReleaseDrawChain
    lea rcx, g_upTex
    call ReleaseClear
    lea rcx, g_reader
    call ReleaseClear
    lea rcx, g_dxm
    call ReleaseClear
    lea rcx, g_vc
    call ReleaseClear
    lea rcx, g_vd
    call ReleaseClear
    lea rcx, g_ctx
    call ReleaseClear
    lea rcx, g_dev
    call ReleaseClear
    mov g_vhwnd, 0
    mov g_scW, 0
    mov g_scH, 0
    mov g_vw, 0
    mov g_vh, 0
    mov g_hwDecode, 0
    add rsp, 28h
    ret
D3DShutdown ENDP

; ------------------------------------------------------------
; StartFrameTimer - 按当前素材类型重设/停掉帧定时器
; ------------------------------------------------------------
StartFrameTimer PROC
    sub rsp, 28h
    cmp g_isVideo, 0
    je sft_img
    CALLV SetTimer, g_host, TIMER_FRAME, 16, 0
    jmp sft_done
sft_img:
    CALLV KillTimer, g_host, TIMER_FRAME
sft_done:
    add rsp, 28h
    ret
StartFrameTimer ENDP

; ------------------------------------------------------------
; AdvanceFrame - WM_TIMER(TIMER_FRAME)：视频泵帧并重设间隔
; ------------------------------------------------------------
AdvanceFrame PROC
    sub rsp, 28h
    cmp g_isVideo, 0
    je af_done
    call D3DPumpFrame
    cmp eax, 10
    jae af_set
    mov eax, 10
af_set:
    mov r10d, eax
    CALLV SetTimer, g_host, TIMER_FRAME, r10, 0
af_done:
    add rsp, 28h
    ret
AdvanceFrame ENDP

; ------------------------------------------------------------
; LoadMediaInto(rcx = path) -> eax = 1/0
;   视频 → D3DInit（内部先 D3DShutdown）；图片 → D3DShutdown + LoadImageFile
;   对齐 c/main.c LoadMediaInto；失败由调用方负责回滚旧素材
; ------------------------------------------------------------
LoadMediaInto PROC
    sub rsp, 28h
    mov qword ptr g_lmiPath, rcx
    lea rcx, g_lmiPath
    call IsVideoFile
    test eax, eax
    jz lmi_image
    ; ---- 视频：释放旧 GDI+ 图，交给 D3D 播放器 ----
    cmp g_img, 0
    je lmi_v
    CALLV GdipDisposeImage, g_img
    mov g_img, 0
lmi_v:
    mov rcx, g_hwnd
    lea rdx, g_lmiPath
    call D3DInit
    test eax, eax
    jz lmi_fail
    mov g_isVideo, 1
    lea rdi, g_curMedia
    lea rsi, g_lmiPath
    mov ecx, 259
    rep movsw
    mov word ptr [rdi], 0
    mov eax, 1
    jmp lmi_done
lmi_image:
    ; ---- 图片：停视频（避免两套同时占 GPU），加载图 ----
    call D3DShutdown
    mov g_isVideo, 0
    lea rcx, g_lmiPath
    call LoadImageFile
    test eax, eax
    jz lmi_fail
    mov eax, 1
    jmp lmi_done
lmi_fail:
    xor eax, eax
lmi_done:
    add rsp, 28h
    ret
LoadMediaInto ENDP

END

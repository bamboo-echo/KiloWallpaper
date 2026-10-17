// ffi.rs — 手写 Win32 / GDI / GDI+ 绑定（零 crate 依赖）
//
// 初心：运行时占用最小。所有调用直接 extern "system" 到系统 DLL，不引入任何
// 绑定 crate（windows crate 会生成大量绑定代码、膨胀二进制；windows-sys 又不含
// D3D11/MF/DComp）。COM 接口（D3D11/MF/DComp）按 C 版方式手写 vtable。
//
// 本文件先覆盖主进程 / 桌面嵌入 / GIF 路径所需的 Win32 + GDI + GDI+；
// D3D11 / Media Foundation / DirectComposition 的 vtable 在文件末尾追加。
#![allow(non_snake_case, non_camel_case_types, dead_code)]

use core::ffi::c_void;

// ---------- 基础类型（与 Windows SDK 的 x64 ABI 对齐） ----------
pub type HWND = *mut c_void;
pub type HDC = *mut c_void;
pub type HINSTANCE = *mut c_void;
pub type HMODULE = *mut c_void;
pub type HANDLE = *mut c_void;
pub type HMONITOR = *mut c_void;
pub type HBITMAP = *mut c_void;
pub type HBRUSH = *mut c_void;
pub type HCURSOR = *mut c_void;
pub type HGDIOBJ = *mut c_void;
pub type HMENU = *mut c_void;
pub type BOOL = i32;
pub type DWORD = u32;
pub type UINT = u32;
pub type LONG = i32;
pub type WPARAM = usize;
pub type LPARAM = isize;
pub type LRESULT = isize;
pub type HRESULT = i32;
pub type WCHAR = u16;
pub type ULONG_PTR = usize;
pub type UINT32 = u32;
pub type UINT64 = u64;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const S_OK: HRESULT = 0;
pub const E_FAIL: HRESULT = 0x8000_4005u32 as i32;
pub const E_NOINTERFACE: HRESULT = 0x8000_4002u32 as i32;
pub const MAX_PATH: usize = 260;
pub const INVALID_HANDLE_VALUE: HANDLE = -1isize as HANDLE;

// ---------- 结构体 ----------
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct RECT {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct POINT {
    pub x: i32,
    pub y: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MSG {
    pub hwnd: HWND,
    pub message: u32,
    pub wParam: WPARAM,
    pub lParam: LPARAM,
    pub time: u32,
    pub pt: POINT,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SYSTEMTIME {
    pub wYear: u16,
    pub wMonth: u16,
    pub wDayOfWeek: u16,
    pub wDay: u16,
    pub wHour: u16,
    pub wMinute: u16,
    pub wSecond: u16,
    pub wMilliseconds: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct GUID {
    pub Data1: u32,
    pub Data2: u16,
    pub Data3: u16,
    pub Data4: [u8; 8],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PAINTSTRUCT {
    pub hdc: HDC,
    pub fErase: BOOL,
    pub rcPaint: RECT,
    pub fRestore: BOOL,
    pub fIncUpdate: BOOL,
    pub rgbReserved: [u8; 32],
}
impl Default for PAINTSTRUCT {
    fn default() -> Self {
        unsafe { core::mem::zeroed() }
    }
}

pub type WNDPROC = Option<unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT>;

#[repr(C)]
pub struct WNDCLASSW {
    pub style: UINT,
    pub lpfnWndProc: WNDPROC,
    pub cbClsExtra: i32,
    pub cbWndExtra: i32,
    pub hInstance: HINSTANCE,
    pub hIcon: HANDLE,
    pub hCursor: HCURSOR,
    pub hbrBackground: HBRUSH,
    pub lpszMenuName: *const WCHAR,
    pub lpszClassName: *const WCHAR,
}
impl Default for WNDCLASSW {
    fn default() -> Self {
        unsafe { core::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Default)]
pub struct STARTUPINFOW {
    pub cb: u32,
    pub lpReserved: *const WCHAR,
    pub lpDesktop: *const WCHAR,
    pub lpTitle: *const WCHAR,
    pub dwX: u32,
    pub dwY: u32,
    pub dwXSize: u32,
    pub dwYSize: u32,
    pub dwXCountChars: u32,
    pub dwYCountChars: u32,
    pub dwFillAttribute: u32,
    pub dwFlags: u32,
    pub wShowWindow: u16,
    pub cbReserved2: u16,
    pub lpReserved2: *mut u8,
    pub hStdInput: HANDLE,
    pub hStdOutput: HANDLE,
    pub hStdError: HANDLE,
}

#[repr(C)]
#[derive(Default)]
pub struct PROCESS_INFORMATION {
    pub hProcess: HANDLE,
    pub hThread: HANDLE,
    pub dwProcessId: u32,
    pub dwThreadId: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct MONITORINFO {
    pub cbSize: u32,
    pub rcMonitor: RECT,
    pub rcWork: RECT,
    pub dwFlags: u32,
}

// GDI+ PropertyItem（读 GIF 帧延时）
#[repr(C)]
pub struct PropertyItem {
    pub id: u32,
    pub length: u32,
    pub type_: u16,
    pub value: *mut c_void,
}

// ---------- 常量 ----------
pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_DISPLAYCHANGE: u32 = 0x007E;
pub const WM_DPICHANGED: u32 = 0x02E0;

pub const WS_POPUP: u32 = 0x8000_0000;
pub const WS_CHILD: u32 = 0x4000_0000;
pub const WS_VISIBLE: u32 = 0x1000_0000;
pub const WS_CAPTION: u32 = 0x00C0_0000;
pub const WS_SYSMENU: u32 = 0x0008_0000;
pub const WS_THICKFRAME: u32 = 0x0004_0000;

pub const WS_EX_NOACTIVATE: u32 = 0x0800_0000;
pub const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
pub const WS_EX_LAYERED: u32 = 0x0008_0000;
pub const WS_EX_TOPMOST: u32 = 0x0000_0008;
pub const WS_EX_TRANSPARENT: u32 = 0x0000_0020;

pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const SWP_FRAMECHANGED: u32 = 0x0020;
pub const SWP_SHOWWINDOW: u32 = 0x0040;
pub const HWND_BOTTOM: HWND = 1 as HWND;
pub const HWND_MESSAGE: HWND = -3isize as HWND;

pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;
pub const BLACK_BRUSH: i32 = 4;
pub const IDC_ARROW: *const WCHAR = 32512 as *const WCHAR;
pub const LWA_ALPHA: u32 = 0x0000_0002;
pub const SRCCOPY: u32 = 0x00CC_0020;
pub const MONITOR_DEFAULTTOPRIMARY: u32 = 1;
pub const SMTO_NORMAL: u32 = 0;
pub const DETACHED_PROCESS: u32 = 0x0000_0008;
pub const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
pub const MOVEFILE_WRITE_THROUGH: u32 = 0x0000_0008;
pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
pub const ERROR_ALREADY_EXISTS: u32 = 183;
pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;
pub const GENERIC_READ: u32 = 0x8000_0000;
pub const OPEN_EXISTING: u32 = 3;
pub const FILE_SHARE_READ: u32 = 0x0000_0001;
pub const CP_UTF8: u32 = 65001;

// ---------- kernel32 ----------
#[link(name = "kernel32")]
extern "system" {
    pub fn GetModuleFileNameW(h: HMODULE, buf: *mut WCHAR, n: u32) -> u32;
    pub fn GetModuleHandleW(name: *const WCHAR) -> HMODULE;
    pub fn GetLastError() -> u32;
    pub fn CreateMutexW(attr: *mut c_void, owner: BOOL, name: *const WCHAR) -> HANDLE;
    pub fn CloseHandle(h: HANDLE) -> BOOL;
    pub fn CreateProcessW(
        app: *const WCHAR,
        cmd: *mut WCHAR,
        pa: *mut c_void,
        ta: *mut c_void,
        inherit: BOOL,
        flags: u32,
        env: *mut c_void,
        dir: *const WCHAR,
        si: *const STARTUPINFOW,
        pi: *mut PROCESS_INFORMATION,
    ) -> BOOL;
    pub fn OpenProcess(access: u32, inherit: BOOL, pid: u32) -> HANDLE;
    pub fn QueryFullProcessImageNameW(h: HANDLE, flags: u32, buf: *mut WCHAR, len: *mut u32) -> BOOL;
    pub fn MoveFileExW(from: *const WCHAR, to: *const WCHAR, flags: u32) -> BOOL;
    pub fn GetFileAttributesW(path: *const WCHAR) -> u32;
    pub fn DeleteFileW(path: *const WCHAR) -> BOOL;
    pub fn CreateFileW(
        path: *const WCHAR,
        access: u32,
        share: u32,
        sec: *mut c_void,
        disp: u32,
        flags: u32,
        tmpl: HANDLE,
    ) -> HANDLE;
    pub fn ReadFile(h: HANDLE, buf: *mut u8, n: u32, read: *mut u32, ov: *mut c_void) -> BOOL;
    pub fn MultiByteToWideChar(cp: u32, flags: u32, src: *const u8, src_len: i32, dst: *mut WCHAR, dst_len: i32) -> i32;
    pub fn GetFullPathNameW(path: *const WCHAR, n: u32, buf: *mut WCHAR, file: *mut *mut WCHAR) -> u32;
    pub fn GetTickCount64() -> u64;
    pub fn GetCurrentProcess() -> HANDLE;
    pub fn SetProcessWorkingSetSize(p: HANDLE, min: usize, max: usize) -> BOOL;
    pub fn GetCurrentProcessId() -> u32;
    pub fn Sleep(ms: u32);
    pub fn GetLocalTime(st: *mut SYSTEMTIME);
    pub fn GetProcAddress(h: HMODULE, name: *const u8) -> *mut c_void;
    pub fn ExitProcess(code: u32) -> !;
}

// ---------- user32 ----------
#[link(name = "user32")]
extern "system" {
    pub fn RegisterClassW(wc: *const WNDCLASSW) -> u16;
    pub fn CreateWindowExW(
        ex: u32,
        cls: *const WCHAR,
        title: *const WCHAR,
        style: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: HWND,
        menu: HMENU,
        inst: HINSTANCE,
        param: *mut c_void,
    ) -> HWND;
    pub fn DefWindowProcW(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT;
    pub fn GetMessageW(msg: *mut MSG, h: HWND, min: u32, max: u32) -> BOOL;
    pub fn TranslateMessage(msg: *const MSG) -> BOOL;
    pub fn DispatchMessageW(msg: *const MSG) -> LRESULT;
    pub fn PostQuitMessage(code: i32);
    pub fn SetTimer(h: HWND, id: usize, ms: u32, proc: *mut c_void) -> usize;
    pub fn KillTimer(h: HWND, id: usize) -> BOOL;
    pub fn GetParent(h: HWND) -> HWND;
    pub fn SetParent(h: HWND, parent: HWND) -> HWND;
    pub fn IsWindow(h: HWND) -> BOOL;
    pub fn IsWindowVisible(h: HWND) -> BOOL;
    pub fn DestroyWindow(h: HWND) -> BOOL;
    pub fn SetWindowPos(h: HWND, after: HWND, x: i32, y: i32, w: i32, h: i32, flags: u32) -> BOOL;
    pub fn InvalidateRect(h: HWND, rc: *const RECT, erase: BOOL) -> BOOL;
    pub fn GetClientRect(h: HWND, rc: *mut RECT) -> BOOL;
    pub fn GetWindowRect(h: HWND, rc: *mut RECT) -> BOOL;
    pub fn GetSystemMetrics(idx: i32) -> i32;
    pub fn SendMessageTimeoutW(
        h: HWND,
        msg: u32,
        wp: WPARAM,
        lp: LPARAM,
        flags: u32,
        timeout: u32,
        result: *mut usize,
    ) -> LRESULT;
    pub fn FindWindowW(cls: *const WCHAR, title: *const WCHAR) -> HWND;
    pub fn FindWindowExW(parent: HWND, after: HWND, cls: *const WCHAR, title: *const WCHAR) -> HWND;
    pub fn EnumWindows(cb: Option<unsafe extern "system" fn(HWND, LPARAM) -> BOOL>, lp: LPARAM) -> BOOL;
    pub fn GetClassNameW(h: HWND, buf: *mut WCHAR, n: i32) -> i32;
    pub fn GetWindowLongPtrW(h: HWND, idx: i32) -> isize;
    pub fn SetWindowLongPtrW(h: HWND, idx: i32, val: isize) -> isize;
    pub fn SetLayeredWindowAttributes(h: HWND, key: u32, alpha: u8, flags: u32) -> BOOL;
    pub fn RegisterWindowMessageW(name: *const WCHAR) -> u32;
    pub fn LoadCursorW(inst: HINSTANCE, name: *const WCHAR) -> HCURSOR;
    pub fn GetStockObject(idx: i32) -> HGDIOBJ;
    pub fn MonitorFromPoint(pt: POINT, flags: u32) -> HMONITOR;
    pub fn GetMonitorInfoW(mon: HMONITOR, info: *mut MONITORINFO) -> BOOL;
    pub fn SetProcessDpiAwarenessContext(ctx: isize) -> BOOL;
    pub fn BeginPaint(h: HWND, ps: *mut PAINTSTRUCT) -> HDC;
    pub fn EndPaint(h: HWND, ps: *const PAINTSTRUCT) -> BOOL;
    pub fn FillRect(dc: HDC, rc: *const RECT, brush: HBRUSH) -> i32;
    pub fn CreateSolidBrush(color: u32) -> HBRUSH;
    pub fn InvalidateRect_none();
    pub fn RedrawWindow(h: HWND, rc: *const RECT, rgn: *mut c_void, flags: u32) -> BOOL;
}

// ---------- gdi32 ----------
#[link(name = "gdi32")]
extern "system" {
    pub fn CreateCompatibleDC(dc: HDC) -> HDC;
    pub fn CreateCompatibleBitmap(dc: HDC, w: i32, h: i32) -> HBITMAP;
    pub fn SelectObject(dc: HDC, obj: HGDIOBJ) -> HGDIOBJ;
    pub fn DeleteObject(obj: HGDIOBJ) -> BOOL;
    pub fn DeleteDC(dc: HDC) -> BOOL;
    pub fn BitBlt(dst: HDC, x: i32, y: i32, w: i32, h: i32, src: HDC, sx: i32, sy: i32, rop: u32) -> BOOL;
}

// ---------- gdiplus（flat API） ----------
pub type GpStatus = i32;
pub type GpImage = c_void;
pub type GpGraphics = c_void;
pub const Ok: GpStatus = 0;
pub const PropertyTagFrameDelay: u32 = 0x5100;
pub const FrameDimensionTime: GUID = GUID {
    Data1: 0x6AEDBD6D,
    Data2: 0x3FB5,
    Data3: 0x418A,
    Data4: [0x83, 0xA6, 0x7F, 0x45, 0x22, 0x9D, 0xC8, 0x72],
};

#[repr(C)]
pub struct GdiplusStartupInput {
    pub GdiplusVersion: u32,
    pub DebugEventCallback: *mut c_void,
    pub SuppressBackgroundThread: BOOL,
    pub SuppressExternalCodecs: BOOL,
}

#[link(name = "gdiplus")]
extern "system" {
    pub fn GdiplusStartup(token: *mut ULONG_PTR, input: *const GdiplusStartupInput, output: *mut c_void) -> GpStatus;
    pub fn GdiplusShutdown(token: ULONG_PTR);
    pub fn GdipLoadImageFromFile(path: *const WCHAR, image: *mut *mut GpImage) -> GpStatus;
    pub fn GdipDisposeImage(image: *mut GpImage) -> GpStatus;
    pub fn GdipGetImageWidth(image: *mut GpImage, w: *mut u32) -> GpStatus;
    pub fn GdipGetImageHeight(image: *mut GpImage, h: *mut u32) -> GpStatus;
    pub fn GdipImageGetFrameDimensionsCount(image: *mut GpImage, n: *mut u32) -> GpStatus;
    pub fn GdipImageGetFrameDimensionsList(image: *mut GpImage, buf: *mut GUID, n: u32) -> GpStatus;
    pub fn GdipImageGetFrameCount(image: *mut GpImage, dim: *const GUID, n: *mut u32) -> GpStatus;
    pub fn GdipImageSelectActiveFrame(image: *mut GpImage, dim: *const GUID, idx: u32) -> GpStatus;
    pub fn GdipGetPropertyItemSize(image: *mut GpImage, id: u32, size: *mut u32) -> GpStatus;
    pub fn GdipGetPropertyItem(image: *mut GpImage, id: u32, size: u32, buf: *mut c_void) -> GpStatus;
    pub fn GdipCreateFromHDC(dc: HDC, g: *mut *mut GpGraphics) -> GpStatus;
    pub fn GdipDeleteGraphics(g: *mut GpGraphics) -> GpStatus;
    pub fn GdipSetInterpolationMode(g: *mut GpGraphics, mode: i32) -> GpStatus;
    pub fn GdipDrawImageRectI(g: *mut GpGraphics, img: *mut GpImage, x: i32, y: i32, w: i32, h: i32) -> GpStatus;
}

// ============================================================================
// D3D11 / DXGI / Media Foundation / DirectComposition 的 vtable 绑定
// 见 ffi_d3d.rs（COM 接口手写，与 C 版同一套偏移）。
// ============================================================================

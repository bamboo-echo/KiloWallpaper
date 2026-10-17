// win.zig - Windows API 绑定层（KiloWallpaper Zig 版）
//
// 设计决策（与 cpp/ 对齐的关键差异）：
//   * COM 接口（D3D11 / DXGI / DComp / Media Foundation）的 vtable 布局与全部
//     GUID 常量、Win32 函数签名，由 @cImport 直接翻译 SDK 头文件得到。
//     理由：这些接口的方法索引（vtable offset）极深（例如 ID3D11DeviceContext::
//     UpdateSubresource、ID3D11VideoContext::VideoProcessorBlt 等），手写极易
//     串位导致调用到错误函数；SDK 头文件是唯一可靠的来源。
//     —— 因此本文件在【编译期】依赖 Windows SDK 头文件（项目本就要求编译期有
//        SDK，运行时零依赖）。cpp/build.bat 也是同样前提。
//   * GDI+ 是 C++ 类库（gdiplus.h 无法被 translate-c 解析），故改用 GDI+ 的
//     平面 C 接口 Gdip*（gdiplus.dll 按原名导出），手写这部分 extern 声明。
//
// 若需要完全不依赖 SDK 头文件的版本，应改用预生成的 zigwin32 绑定；本实现
// 选择 SDK 头文件以确保 vtable/GUID 正确性。
const builtin = @import("builtin");
const std = @import("std");

// ---- 翻译 SDK 头文件：拿到 COM 接口类型、GUID 常量、Win32 函数签名 ----
pub const c = @cImport({
    // 版本宏：让 SDK 头暴露 Win10/Win11 的 API（DXGI 1.2、DComp 等）
    @cDefine("WINVER", "0x0A00");
    @cDefine("INITGUID", {}); // 让 DEFINE_GUID 全部展开为定义，避免依赖 mfuuid/uuid 导入库
    @cDefine("DECLSPEC_UUID(x)", ""); // translate-c 无法处理 __declspec(uuid)，置空
    @cDefine("MIDL_INTERFACE(x)", "struct"); // 同上：去掉 uuid 声明，保留 struct 定义
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("NTDDI_VERSION", "0x0A000000");
    @cDefine("UNICODE", {});
    @cDefine("_UNICODE", {});
    @cDefine("COBJMACROS", {}); // 不需要，但部分头依赖
    @cInclude("stdio.h"); // _wfopen / fwrite / fclose / fgetws
    @cInclude("stdlib.h"); // _wtoi
    @cInclude("ctype.h"); // towlower
    @cInclude("string.h");
    @cInclude("windows.h");
    @cInclude("objbase.h"); // CoInitializeEx / CoUninitialize
    @cInclude("shlwapi.h"); // PathIsRelativeW / PathFindExtensionW
    @cInclude("d3d11.h");
    @cInclude("dxgi1_2.h"); // CreateDXGIFactory1 / IDXGIFactory2 / IDXGISwapChain1
    // dcomp.h 在 Zig translate-c 下无法解析（DECLARE_INTERFACE 多重继承展开报
    // duplicate member / expected ')' 等）；改用手写最小 vtable（见文件末尾）。
    @cInclude("mfapi.h"); // MFStartup / MFCreateXxx
    @cInclude("mfidl.h"); // IMFSourceReader 等接口
    @cInclude("mfreadwrite.h"); // MF_SOURCE_READER_D3D_MANAGER 等
    @cInclude("mfobjects.h"); // IMFDXGIBuffer / IMFDXGIDeviceManager
});

// ---- 常用类型别名（从 c 命名空间取，便于其它模块引用） ----
pub const HINSTANCE = c.HINSTANCE;
pub const HWND = c.HWND;

// translate-c 的 HWND_MESSAGE / HWND_BOTTOM 常量在对齐检查上失败（[*c] 需对齐），
// 这里按指针值直接构造。
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub const HWND_BOTTOM: HWND = @ptrFromInt(@as(usize, 1));

// 这两个 IID 只在 mfuuid.lib 定义（SDK 头仅 EXTERN_C 声明），而链接 mfuuid 会与
// translate-c 展开的 MF GUID 重复，故按 MIDL_INTERFACE 的值手写。
pub const IID_IMF2DBuffer = GUID{
    .Data1 = 0x7DC9D5F9, .Data2 = 0x9ED9, .Data3 = 0x44EC,
    .Data4 = .{ 0x9B, 0xBF, 0x06, 0x00, 0xBB, 0x58, 0x9F, 0xBB },
};
pub const IID_IMFDXGIBuffer = GUID{
    .Data1 = 0xE7174CFA, .Data2 = 0x1C9E, .Data3 = 0x48B1,
    .Data4 = .{ 0x88, 0x66, 0x62, 0x62, 0x26, 0xBF, 0xC2, 0x58 },
};

// D3D/DXGI 的 IID 同样只在 dxguid.lib 定义（与 translate-c 的 INITGUID 冲突），
// 按 SDK 头的 MIDL_INTERFACE 值手写。
pub const IID_ID3D10Multithread = GUID{
    .Data1 = 0x9B7E4E00, .Data2 = 0x342C, .Data3 = 0x4106,
    .Data4 = .{ 0xA1, 0x9F, 0x4F, 0x27, 0x04, 0xF6, 0x89, 0xF0 },
};
pub const IID_ID3D11VideoDevice = GUID{
    .Data1 = 0x10EC4D5B, .Data2 = 0x975A, .Data3 = 0x4689,
    .Data4 = .{ 0xB9, 0xE4, 0xD0, 0xAA, 0xC3, 0x0F, 0xE3, 0x33 },
};
pub const IID_ID3D11VideoContext = GUID{
    .Data1 = 0x61F21C45, .Data2 = 0x3C0E, .Data3 = 0x4A74,
    .Data4 = .{ 0x9C, 0xEA, 0x67, 0x10, 0x0D, 0x9A, 0xD5, 0xE4 },
};
pub const IID_ID3D11Texture2D = GUID{
    .Data1 = 0x6F15AAF2, .Data2 = 0xD208, .Data3 = 0x4E89,
    .Data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C },
};
pub const IID_IDXGIFactory2 = GUID{
    .Data1 = 0x50C83A1C, .Data2 = 0xE072, .Data3 = 0x4C48,
    .Data4 = .{ 0x87, 0xB0, 0x36, 0x30, 0xFA, 0x36, 0xA6, 0xD0 },
};
pub const IID_IDXGIDevice = GUID{
    .Data1 = 0x54EC77FA, .Data2 = 0x1377, .Data3 = 0x44E6,
    .Data4 = .{ 0x8C, 0x32, 0x88, 0xFD, 0x5F, 0x44, 0xC8, 0x4C },
};
pub const HDC = c.HDC;
pub const HANDLE = c.HANDLE;
pub const HMENU = c.HMENU;
pub const HMODULE = c.HMODULE;
pub const HMONITOR = c.HMONITOR;
pub const HBITMAP = c.HBITMAP;
pub const HBRUSH = c.HBRUSH;
pub const HCURSOR = c.HCURSOR;
pub const HRESULT = c.HRESULT;
pub const GUID = c.GUID;
pub const RECT = c.RECT;
pub const POINT = c.POINT;
pub const MSG = c.MSG;
pub const DWORD = c.DWORD;
pub const BOOL = c.BOOL;
pub const LONG = c.LONG;
pub const UINT = c.UINT;
pub const WCHAR = c.WCHAR;
pub const LPWSTR = c.LPWSTR;
pub const LPCWSTR = c.LPCWSTR;
pub const LRESULT = c.LRESULT;
pub const WPARAM = c.WPARAM;
pub const LPARAM = c.LPARAM;
pub const ULONG_PTR = c.ULONG_PTR;
pub const SIZE_T = c.SIZE_T;
pub const BYTE = c.BYTE;
pub const INT = c.INT;
pub const UINT32 = c.UINT32;

pub const TRUE: BOOL = @intFromBool(true);
pub const FALSE: BOOL = 0;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

// MAKEFOURCC 宏（DXVA 输入视图显式声明 FourCC 用，实测不声明采样全黑）
pub fn MAKEFOURCC(a: u8, b: u8, c_: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c_) << 16) | (@as(u32, d) << 24);
}

// ============================================================================
//  GDI+ 平面 C 接口（gdiplus.h 是 C++，translate-c 无法解析，这里手写 extern）
// ============================================================================
pub const GpStatus = c_int;
pub const GpImage = opaque {};
pub const GpGraphics = opaque {};
pub const GpBitmap = opaque {};

pub const Ok: GpStatus = 0;

// PropertyTagFrameDelay = 0x5100（GDI+ 帧延时属性，单位 1/100 秒）
pub const PropertyTagFrameDelay: c_uint = 0x5100;

// InterpolationMode.HighQualityBicubic = 7（封面缩放用，避免锯齿）
pub const InterpolationModeHighQualityBicubic: c_int = 7;

pub extern fn GdipLoadImageFromFile(
    filename: [*]const WCHAR,
    image: [*]?*GpImage,
) callconv(.C) GpStatus;

pub extern fn GdipDisposeImage(image: ?*GpImage) callconv(.C) GpStatus;

pub extern fn GdipGetImageWidth(image: ?*GpImage, width: [*]UINT) callconv(.C) GpStatus;
pub extern fn GdipGetImageHeight(image: ?*GpImage, height: [*]UINT) callconv(.C) GpStatus;

// 注意：帧维度函数的真实导出名带 Image 前缀（GdipImageGetFrameDimensions*）。
// 写成 GdipGetFrameDimensions* 会链接失败（gdiplus.lib 无此符号，实测确认）。
pub extern fn GdipImageGetFrameDimensionsCount(image: ?*GpImage, count: [*]UINT) callconv(.C) GpStatus;
pub extern fn GdipImageGetFrameDimensionsList(
    image: ?*GpImage,
    buffer: [*]GUID,
    count: UINT,
) callconv(.C) GpStatus;
pub extern fn GdipImageGetFrameCount(
    image: ?*GpImage,
    dimensionID: [*]const GUID,
    count: [*]UINT,
) callconv(.C) GpStatus;

pub extern fn GdipGetPropertyItemSize(
    image: ?*GpImage,
    propId: c_uint,
    size: [*]UINT,
) callconv(.C) GpStatus;
pub extern fn GdipGetPropertyItem(
    image: ?*GpImage,
    propId: c_uint,
    propSize: UINT,
    buffer: ?*anyopaque,
) callconv(.C) GpStatus;
pub extern fn GdipImageSelectActiveFrame(
    image: ?*GpImage,
    dimensionID: [*]const GUID,
    frameIndex: UINT,
) callconv(.C) GpStatus;

pub extern fn GdipCreateFromHDC(hdc: HDC, graphics: [*]?*GpGraphics) callconv(.C) GpStatus;
pub extern fn GdipDeleteGraphics(graphics: ?*GpGraphics) callconv(.C) GpStatus;
pub extern fn GdipSetInterpolationMode(
    graphics: ?*GpGraphics,
    interpolationMode: c_int,
) callconv(.C) GpStatus;
pub extern fn GdipDrawImageRectI(
    graphics: ?*GpGraphics,
    image: ?*GpImage,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.C) GpStatus;

// GDI+ PropertyItem 结构（gdiplus.h 定义，手写以便读取帧延时）
pub const PropertyItem = extern struct {
    id: c_uint,
    length: c_uint,
    type_: c_uint,
    value: ?*anyopaque,
};

// GDI+ 启动/关闭（gdiplusinit.h 的 startup 结构带 C++ 构造函数，translate-c 无法
// 解析 gdiplus.h；这里按 ABI 布局手写，与 C 版 wallpaper.h 的垫片一致）。
pub const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32,
    DebugEventCallback: ?*anyopaque,
    SuppressBackgroundThread: BOOL,
    SuppressExternalCodecs: BOOL,
};
pub extern fn GdiplusStartup(
    token: *ULONG_PTR,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.C) GpStatus;
pub extern fn GdiplusShutdown(token: ULONG_PTR) callconv(.C) void;

// ============================================================================
//  轻量 PROPVARIANT 辅助（仅用于本程序用到的 VT_I8，无需真正释放）
// ============================================================================
pub fn PropVariantInit(pv: *c.PROPVARIANT) void {
    const bytes = @as([*]u8, @ptrCast(pv))[0..@sizeOf(c.PROPVARIANT)];
    @memset(bytes, 0);
}
pub fn PropVariantClear(pv: *c.PROPVARIANT) void {
    // 本程序只给 pv 赋过 VT_I8（长整型，无堆分配），清零即可。
    const bytes = @as([*]u8, @ptrCast(pv))[0..@sizeOf(c.PROPVARIANT)];
    @memset(bytes, 0);
}

// ============================================================================
//  便捷封装：把 C 的 Win32 调用包一层，减少调用点噪音
// ============================================================================

// 取本进程 exe 所在目录（含尾随反斜杠），用 GetModuleFileNameW + 截断路径。
pub fn getExeDir(allocator: std.mem.Allocator) ![]u16 {
    var buf: [c.MAX_PATH]WCHAR = undefined;
    const n = c.GetModuleFileNameW(null, &buf, c.MAX_PATH);
    if (n == 0) return error.GetModuleFileNameFailed;
    const slice = buf[0..n];
    // 找到最后一个反斜杠
    var last: usize = 0;
    for (slice, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') last = i + 1;
    }
    return allocator.dupe(u16, slice[0..last]);
}

// ============================================================================
//  DirectComposition 手写绑定（对齐 cpp 版与 C 版的 vtable 偏移）
//  IUnknown(3) 之后：Device: Commit(3) WaitForCommitCompletion(4)
//  GetFrameStatistics(5) CreateTargetForHwnd(6) CreateVisual(7)
// ============================================================================
pub const IDCompositionDevice = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (?*IDCompositionDevice, *const GUID, *?*anyopaque) callconv(.C) HRESULT,
        AddRef: *const fn (?*IDCompositionDevice) callconv(.C) u32,
        Release: ?*const fn (?*IDCompositionDevice) callconv(.C) u32,
        Commit: *const fn (?*IDCompositionDevice) callconv(.C) HRESULT,
        WaitForCommitCompletion: *const fn (?*IDCompositionDevice) callconv(.C) HRESULT,
        GetFrameStatistics: *const fn (?*IDCompositionDevice, ?*anyopaque) callconv(.C) HRESULT,
        CreateTargetForHwnd: *const fn (?*IDCompositionDevice, HWND, BOOL, *?*IDCompositionTarget) callconv(.C) HRESULT,
        CreateVisual: *const fn (?*IDCompositionDevice, *?*IDCompositionVisual) callconv(.C) HRESULT,
    };
};

pub const IDCompositionTarget = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (?*IDCompositionTarget, *const GUID, *?*anyopaque) callconv(.C) HRESULT,
        AddRef: *const fn (?*IDCompositionTarget) callconv(.C) u32,
        Release: ?*const fn (?*IDCompositionTarget) callconv(.C) u32,
        SetRoot: *const fn (?*IDCompositionTarget, ?*IDCompositionVisual) callconv(.C) HRESULT,
    };
};

pub const IDCompositionVisual = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (?*IDCompositionVisual, *const GUID, *?*anyopaque) callconv(.C) HRESULT,
        AddRef: *const fn (?*IDCompositionVisual) callconv(.C) u32,
        Release: ?*const fn (?*IDCompositionVisual) callconv(.C) u32,
        // dcomp.h 顺序：SetOffsetX/SetOffsetX(anim)/SetOffsetY/SetOffsetY(anim)/
        // SetTransform/SetTransform(anim)/SetTransformParent/SetEffect/
        // SetBitmapInterpolationMode/SetBorderMode/SetClip/SetClip(anim)/
        // SetContent。只调用 SetContent，其余占位保证偏移正确。
        SetOffsetX: *const anyopaque,
        SetOffsetXAnimation: *const anyopaque,
        SetOffsetY: *const anyopaque,
        SetOffsetYAnimation: *const anyopaque,
        SetTransform: *const anyopaque,
        SetTransformAnimation: *const anyopaque,
        SetTransformParent: *const anyopaque,
        SetEffect: *const anyopaque,
        SetBitmapInterpolationMode: *const anyopaque,
        SetBorderMode: *const anyopaque,
        SetClip: *const anyopaque,
        SetClipAnimation: *const anyopaque,
        SetContent: *const fn (?*IDCompositionVisual, ?*anyopaque) callconv(.C) HRESULT,
    };
};

pub const IID_IDCompositionDevice = GUID{
    .Data1 = 0xC37EA93A,
    .Data2 = 0xE7AA,
    .Data3 = 0x450D,
    .Data4 = .{ 0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3 },
};

pub extern fn DCompositionCreateDevice(
    dxgiDevice: *anyopaque,
    riid: *const GUID,
    dcompDevice: *?*anyopaque,
) HRESULT;

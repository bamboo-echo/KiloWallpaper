// d3dplayer.zig - 视频壁纸播放器（对应 cpp/d3dplayer.cpp）
//
// 核心：MF SourceReader(DXVA 硬解) 逐帧读 + D3D11 VideoProcessor GPU 转换 +
// DirectComposition 呈现 + 无缝循环（读到 EOS 后 SetCurrentPosition(0) 回开头）。
//
// 全部踩坑逐条落实（详见 README 与 cpp 注释）：
//  - DXVA 需要给 D3D11 device 开 ID3D10Multithread 多线程保护（否则首帧即 EOS）。
//  - 必须用字节流方式打开文件（MFCreateFile + FromByteStream），不要 FromURL。
//  - 不开 ADVANCED_VIDEO_PROCESSING。
//  - 解码器输出类型：DXVA 优先 RGB32（强制转换 MFT 下载）；软解优先 NV12。
//  - 呈现必须用 DComp（layered 子窗口上 DXGI blt 重定向表面不生效→黑屏）。
//  - DXVA 零拷贝路径创建输入视图必须显式声明 FourCC 'NV12'。
//  - 软解/零拷贝不可用时走 UpdateSubresource 上传（注意负 stride 翻行序）。
//  - 分级回退 seek(0)→seek(1)→重建 reader；seek 后必须 break（否则无界自旋）。
//  - 交换链成功后才提交尺寸；失败保持旧值让下一 tick 重试。
//  - 循环日志限频（异常/首轮/每 500 轮）。
const std = @import("std");

// PROPVARIANT 的 C 布局（translate-c 的 union 字段名不稳定，直接按 ABI 写：
// vt 在 offset 0，hVal 在 offset 8）。
const PVLayout = extern struct { vt: u16, r1: u16, r2: u16, r3: u16, hVal: i64 };
const win = @import("win.zig");
const common = @import("common.zig");

// ---- COM 调用便捷：用 SDK 头翻译出的 vtable 布局，用 lpVtbl.*.Method 形式调用 ----
fn release(com_obj: anytype) void {
    const obj = com_obj;
    if (obj != null) {
        const vtbl = obj.?.*.lpVtbl;
        _ = vtbl.*.Release.?(obj);
    }
}

// ---------- 状态（对应 cpp 的 static 全局） ----------
var g_dev: ?*win.c.ID3D11Device = null;
var g_ctx: ?*win.c.ID3D11DeviceContext = null;
var g_swap: ?*win.c.IDXGISwapChain1 = null;
var g_dcomp: ?*win.IDCompositionDevice = null;
var g_target: ?*win.IDCompositionTarget = null;
var g_visual: ?*win.IDCompositionVisual = null;
var g_vd: ?*win.c.ID3D11VideoDevice = null;
var g_vc: ?*win.c.ID3D11VideoContext = null;
var g_vpe: ?*win.c.ID3D11VideoProcessorEnumerator = null;
var g_vp: ?*win.c.ID3D11VideoProcessor = null;
var g_inView: ?*win.c.ID3D11VideoProcessorInputView = null;
var g_outView: ?*win.c.ID3D11VideoProcessorOutputView = null;
var g_dxm: ?*win.c.IMFDXGIDeviceManager = null;
var g_reader: ?*win.c.IMFSourceReader = null;
var g_upTex: ?*win.c.ID3D11Texture2D = null;
var g_upIsNv12: bool = true;
var g_vw: win.UINT = 0;
var g_vh: win.UINT = 0;
var g_frameMs: win.UINT = 33;
var g_scW: win.UINT = 0;
var g_scH: win.UINT = 0;
var g_hwnd: ?win.HWND = null;
var g_active: bool = false;
var g_hwDecode: bool = false;
var g_startTick: u64 = 0;
var g_trimmed: bool = false;
var g_loopCount: win.UINT = 0;
var g_lastTs: i64 = 0;
var g_duration: i64 = 0;
var g_loopRetry: i32 = 0;
var g_pathW: [win.c.MAX_PATH]win.WCHAR = [_]win.WCHAR{0} ** win.c.MAX_PATH;
var g_pathLen: usize = 0;
var g_startWall: i64 = 0;
var g_startTs: i64 = 0;

fn dpLog(comptime fmt: []const u8, args: anytype) void {
    common.logImpl("d3d", fmt, args);
}

// ---------- 解码器：优先 DXVA 硬解，失败逐级回退 ----------
fn createReader(useDxva: bool) ?*win.c.IMFSourceReader {
    var attr: ?*win.c.IMFAttributes = null;
    if (win.c.MFCreateAttributes(&attr, 4) != win.S_OK or attr == null) return null;
    if (useDxva and g_dxm != null) {
        // 绑 DXVA 共享管理器 + 允许硬件变换
        _ = attr.?.*.lpVtbl.*.SetUnknown.?(attr, &win.c.MF_SOURCE_READER_D3D_MANAGER, @ptrCast(g_dxm));
        _ = attr.?.*.lpVtbl.*.SetUINT32.?(attr, &win.c.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
        // 不开 ADVANCED_VIDEO_PROCESSING（会引发首帧即 EOS / 时长=0，实测复现）
    }
    // 字节流方式打开（FromURL 对中文路径解析异常，实测复现）
    var stream: ?*win.c.IMFByteStream = null;
    const hr = win.c.MFCreateFile(win.c.MF_ACCESSMODE_READ, win.c.MF_OPENMODE_FAIL_IF_NOT_EXIST,
        win.c.MF_FILEFLAGS_NONE, g_pathW[0..g_pathLen].ptr, &stream);
    if (hr != win.S_OK or stream == null) {
        release(attr);
        return null;
    }
    var reader: ?*win.c.IMFSourceReader = null;
    const hr2 = win.c.MFCreateSourceReaderFromByteStream(stream, attr, &reader);
    release(stream);
    release(attr);
    if (hr2 != win.S_OK or reader == null) {
        release(reader);
        return null;
    }
    _ = reader.?.*.lpVtbl.*.SetStreamSelection.?(reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_ALL_STREAMS))), win.c.FALSE);
    _ = reader.?.*.lpVtbl.*.SetStreamSelection.?(reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_FIRST_VIDEO_STREAM))), win.c.TRUE);

    // 输出类型协商：DXVA → 优先 RGB32（强制转换 MFT 下载）；软解 → 优先 NV12。
    const first = if (useDxva) &win.c.MFVideoFormat_RGB32 else &win.c.MFVideoFormat_NV12;
    const second = if (useDxva) &win.c.MFVideoFormat_NV12 else &win.c.MFVideoFormat_RGB32;
    var mt: ?*win.c.IMFMediaType = null;
    if (win.c.MFCreateMediaType(&mt) == win.S_OK and mt != null) {
        _ = mt.?.*.lpVtbl.*.SetGUID.?(mt, &win.c.MF_MT_MAJOR_TYPE, &win.c.MFMediaType_Video);
        _ = mt.?.*.lpVtbl.*.SetGUID.?(mt, &win.c.MF_MT_SUBTYPE, first);
        const h = reader.?.*.lpVtbl.*.SetCurrentMediaType.?(reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_FIRST_VIDEO_STREAM))), null, mt);
        release(mt);
        if (h == win.S_OK) return reader;
    }
    if (win.c.MFCreateMediaType(&mt) == win.S_OK and mt != null) {
        _ = mt.?.*.lpVtbl.*.SetGUID.?(mt, &win.c.MF_MT_MAJOR_TYPE, &win.c.MFMediaType_Video);
        _ = mt.?.*.lpVtbl.*.SetGUID.?(mt, &win.c.MF_MT_SUBTYPE, second);
        const h = reader.?.*.lpVtbl.*.SetCurrentMediaType.?(reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_FIRST_VIDEO_STREAM))), null, mt);
        release(mt);
        if (h == win.S_OK) return reader;
    }
    release(reader);
    return null;
}

fn releaseDrawChain() void {
    // 必须 release 后立刻置 null：buildDrawChain 每次先调本函数，
    // 若残留已释放指针，二次 Release 会 use-after-free → AV。
    release(g_inView);  g_inView = null;
    release(g_outView); g_outView = null;
    release(g_vp);      g_vp = null;
    release(g_vpe);     g_vpe = null;
    release(g_visual);  g_visual = null;
    release(g_target);  g_target = null;
    release(g_dcomp);   g_dcomp = null;
    release(g_swap);    g_swap = null;
}

fn buildDrawChain() bool {
    releaseDrawChain();
    if (g_dev == null or g_vd == null or g_hwnd == null or g_vw == 0) return false;

    var rc: win.RECT = undefined;
    _ = win.c.GetClientRect(g_hwnd.?, &rc);
    const w: win.UINT = if (rc.right > 0) @intCast(rc.right) else @intCast(win.c.GetSystemMetrics(win.c.SM_CXSCREEN));
    const h: win.UINT = if (rc.bottom > 0) @intCast(rc.bottom) else @intCast(win.c.GetSystemMetrics(win.c.SM_CYSCREEN));
    if (w == 0 or h == 0) return false;

    // Composition 交换链（FLIP 模型）+ DComp visual。layered 子窗口上 DXGI blt
    // 重定向表面不生效（黑屏），DComp 直接向 DWM 提交纹理是唯一可靠路径。
    var sd: win.c.DXGI_SWAP_CHAIN_DESC1 = undefined;
    sd.Width = w;
    sd.Height = h;
    sd.Format = win.c.DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc = .{ .Count = 1, .Quality = 0 };
    sd.BufferUsage = win.c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = win.c.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sd.AlphaMode = win.c.DXGI_ALPHA_MODE_IGNORE;
    sd.Flags = 0;
    sd.Scaling = win.c.DXGI_SCALING_STRETCH;
    sd.Stereo = win.c.FALSE;

    var factory2: ?*win.c.IDXGIFactory2 = null;
    var hr = win.c.CreateDXGIFactory1(&win.IID_IDXGIFactory2, @ptrCast(&factory2));
    if (hr == win.S_OK) {
        hr = factory2.?.*.lpVtbl.*.CreateSwapChainForComposition.?(factory2, @ptrCast(g_dev), &sd, null, &g_swap);
        release(factory2);
    }
    if (hr != win.S_OK or g_swap == null) {
        dpLog("comp swapchain failed hr=0x{X}", .{hr});
        return false;
    }

    // DComp：设备 → 目标(绑壁纸窗口) → visual(内容=交换链) → 提交
    var dxgiDev: ?*win.c.IDXGIDevice = null;
    hr = g_dev.?.*.lpVtbl.*.QueryInterface.?(g_dev, &win.IID_IDXGIDevice, @ptrCast(&dxgiDev));
    if (hr != win.S_OK) {
        dpLog("dcomp: qi dxgidevice hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }
    hr = win.DCompositionCreateDevice(dxgiDev.?, &win.IID_IDCompositionDevice, @ptrCast(&g_dcomp));
    release(dxgiDev);
    if (hr != win.S_OK) {
        dpLog("dcomp: create device hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }
    hr = g_dcomp.?.*.lpVtbl.*.CreateTargetForHwnd(g_dcomp, g_hwnd.?, win.c.TRUE, &g_target);
    if (hr != win.S_OK) {
        dpLog("dcomp: create target hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }
    hr = g_dcomp.?.*.lpVtbl.*.CreateVisual(g_dcomp, &g_visual);
    if (hr != win.S_OK) {
        dpLog("dcomp: create visual hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }
    hr = g_visual.?.*.lpVtbl.*.SetContent(g_visual, @ptrCast(g_swap));
    if (hr != win.S_OK) {
        dpLog("dcomp: set content hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }
    hr = g_target.?.*.lpVtbl.*.SetRoot(g_target, g_visual);
    if (hr == win.S_OK) hr = g_dcomp.?.*.lpVtbl.*.Commit(g_dcomp);
    if (hr != win.S_OK) {
        dpLog("dcomp: commit hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }
    dpLog("swapchain: dcomp-model", .{});

    // VideoProcessor：视频尺寸 → 屏幕尺寸（全屏拉伸，= 原方案 ARMode_None）
    var cd: win.c.D3D11_VIDEO_PROCESSOR_CONTENT_DESC = undefined;
    cd.InputFrameFormat = win.c.D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = g_vw;
    cd.InputHeight = g_vh;
    cd.OutputWidth = w;
    cd.OutputHeight = h;
    cd.Usage = win.c.D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    hr = g_vd.?.*.lpVtbl.*.CreateVideoProcessorEnumerator.?(g_vd, &cd, &g_vpe);
    if (hr == win.S_OK) hr = g_vd.?.*.lpVtbl.*.CreateVideoProcessor.?(g_vd, g_vpe, 0, &g_vp);
    if (hr != win.S_OK or g_vp == null) {
        dpLog("vp failed hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }

    // 输入视图：绑定上传纹理
    var ivd: win.c.D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC = std.mem.zeroes(win.c.D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC);
    ivd.ViewDimension = win.c.D3D11_VPIV_DIMENSION_TEXTURE2D;
    hr = g_vd.?.*.lpVtbl.*.CreateVideoProcessorInputView.?(g_vd, @ptrCast(g_upTex.?), g_vpe, &ivd, &g_inView);

    // 输出视图：交换链后备缓冲
    var bb: ?*win.c.ID3D11Texture2D = null;
    if (hr == win.S_OK) hr = g_swap.?.*.lpVtbl.*.GetBuffer.?(g_swap, 0, &win.IID_ID3D11Texture2D, @ptrCast(&bb));
    if (hr == win.S_OK) {
        var ovd: win.c.D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC = std.mem.zeroes(win.c.D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC);
        ovd.ViewDimension = win.c.D3D11_VPOV_DIMENSION_TEXTURE2D;
        hr = g_vd.?.*.lpVtbl.*.CreateVideoProcessorOutputView.?(g_vd, @ptrCast(bb.?), g_vpe, &ovd, &g_outView);
        release(bb);
    }
    if (hr != win.S_OK or g_inView == null or g_outView == null) {
        dpLog("view failed hr=0x{X}", .{hr});
        releaseDrawChain();
        return false;
    }

    // 源矩形铺满目标 + 色彩空间（BT.709 输入 → 全量程 RGB 输出）。
    var src: win.RECT = .{ .left = 0, .top = 0, .right = @intCast(g_vw), .bottom = @intCast(g_vh) };
    var dst: win.RECT = .{ .left = 0, .top = 0, .right = @intCast(w), .bottom = @intCast(h) };
    g_vc.?.*.lpVtbl.*.VideoProcessorSetStreamSourceRect.?(g_vc, g_vp, 0, win.c.TRUE, &src);
    g_vc.?.*.lpVtbl.*.VideoProcessorSetStreamDestRect.?(g_vc, g_vp, 0, win.c.TRUE, &dst);
    g_vc.?.*.lpVtbl.*.VideoProcessorSetStreamFrameFormat.?(g_vc, g_vp, 0, win.c.D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    // COLOR_SPACE 是位域 struct，translate-c 生成 opaque；按 ABI 直接写 _bitfield：
    // bit0-1 Usage=0, bit2 RGB_Range=0(全量程), bit3 YCbCr_Matrix=1(BT.709),
    // bit4 xvYCC=0, bit5-6 Nominal_Range=0(16-235)。
    var cs: extern struct { _bitfield: u32 } = .{ ._bitfield = 0x8 };
    _ = g_vc.?.*.lpVtbl.*.VideoProcessorSetStreamColorSpace.?(g_vc, g_vp, 0, @ptrCast(&cs));
    var ocs: extern struct { _bitfield: u32 } = .{ ._bitfield = 0 };
    _ = g_vc.?.*.lpVtbl.*.VideoProcessorSetOutputColorSpace.?(g_vc, g_vp, @ptrCast(&ocs));

    // 全部成功后才提交交换链尺寸：失败路径保持旧值，让下个 tick 重试。
    g_scW = w;
    g_scH = h;
    return true;
}

// ---------- 初始化 ----------
pub fn d3dInit(hwnd: win.HWND, videoPath: []const win.WCHAR) bool {
    d3dShutdown();
    g_hwnd = hwnd;
    // 拷贝路径到全局
    var i: usize = 0;
    while (i < videoPath.len and i < g_pathW.len - 1) : (i += 1) g_pathW[i] = videoPath[i];
    g_pathW[i] = 0;
    g_pathLen = i;

    // 1. D3D11 设备（需要 VIDEO_SUPPORT 供 DXVA / VideoProcessor）
    var flags: win.UINT = win.c.D3D11_CREATE_DEVICE_VIDEO_SUPPORT | win.c.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    var fl: win.c.D3D_FEATURE_LEVEL = win.c.D3D_FEATURE_LEVEL_11_0;
    var hr = win.c.D3D11CreateDevice(null, win.c.D3D_DRIVER_TYPE_HARDWARE, null, flags, null, 0,
        win.c.D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
    if (hr != win.S_OK or g_dev == null) {
        if (g_dev != null) {
            release(g_dev);
            g_dev = null;
        }
        if (g_ctx != null) {
            release(g_ctx);
            g_ctx = null;
        }
        flags = win.c.D3D11_CREATE_DEVICE_BGRA_SUPPORT; // 老驱动退级重试
        hr = win.c.D3D11CreateDevice(null, win.c.D3D_DRIVER_TYPE_HARDWARE, null, flags, null, 0,
            win.c.D3D11_SDK_VERSION, &g_dev, &fl, &g_ctx);
        if (hr != win.S_OK or g_dev == null) {
            dpLog("device failed hr=0x{X}", .{hr});
            d3dShutdown();
            return false;
        }
    }
    // 关键：MF 的 DXVA 解码器在工作线程使用本 device，必须开多线程保护，
    // 否则并发访问 device 导致数据流断（实测：首帧即 EOS）。
    {
        var mt: ?*win.c.ID3D10Multithread = null;
        if (g_dev.?.*.lpVtbl.*.QueryInterface.?(g_dev, &win.IID_ID3D10Multithread, @ptrCast(&mt)) == win.S_OK and mt != null) {
            _ = mt.?.*.lpVtbl.*.SetMultithreadProtected.?(mt, win.c.TRUE);
            release(mt);
        }
    }
    if (g_dev.?.*.lpVtbl.*.QueryInterface.?(g_dev, &win.IID_ID3D11VideoDevice, @ptrCast(&g_vd)) != win.S_OK or
        g_ctx.?.*.lpVtbl.*.QueryInterface.?(g_ctx, &win.IID_ID3D11VideoContext, @ptrCast(&g_vc)) != win.S_OK)
    {
        dpLog("video ifaces failed", .{});
        d3dShutdown();
        return false;
    }

    // 2. DXVA 共享管理器
    var resetToken: win.UINT = 0;
    if (win.c.MFCreateDXGIDeviceManager(&resetToken, &g_dxm) == win.S_OK) {
        if (g_dxm.?.*.lpVtbl.*.ResetDevice.?(g_dxm, @ptrCast(g_dev.?), resetToken) != win.S_OK) {
            release(g_dxm);
            g_dxm = null;
        }
    }

    // 3. 解码器：优先 DXVA 硬解，失败退软解。
    // 二分探针：KW_NO_READER=1 时跳过 MF 解码器（硬编码 2560x1440 NV12），
    // 其余 D3D 资源照常构建，用于定位 80.5MB 大池是否来自 MF。
    var noReaderBuf: [8]u8 = undefined;
    const skipReader = win.c.GetEnvironmentVariableA("KW_NO_READER", &noReaderBuf, 8) > 0;
    if (skipReader) {
        g_vw = 2560;
        g_vh = 1440;
        g_upIsNv12 = true;
        g_frameMs = 41;
        g_hwDecode = false;
        dpLog("probe: MF reader skipped (KW_NO_READER=1)", .{});
    } else {
        g_reader = createReader(true);
        g_hwDecode = g_reader != null;
        if (g_reader == null) {
            g_reader = createReader(false);
            if (g_reader == null) {
                dpLog("reader failed", .{});
                d3dShutdown();
                return false;
            }
        }

        // 4. 读输出格式信息：尺寸/帧率/子类型/时长
        var cur: ?*win.c.IMFMediaType = null;
        hr = g_reader.?.*.lpVtbl.*.GetCurrentMediaType.?(g_reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_FIRST_VIDEO_STREAM))), &cur);
        if (hr != win.S_OK or cur == null) {
            dpLog("cur type failed hr=0x{X}", .{hr});
            d3dShutdown();
            return false;
        }
        var num: win.UINT = 0;
        var den: win.UINT = 1;
        var attrVal: u64 = 0;
        _ = cur.?.*.lpVtbl.*.GetUINT64.?(cur, &win.c.MF_MT_FRAME_SIZE, &attrVal);
        g_vw = @intCast(attrVal >> 32);
        g_vh = @intCast(attrVal & 0xFFFF_FFFF);
        _ = cur.?.*.lpVtbl.*.GetUINT64.?(cur, &win.c.MF_MT_FRAME_RATE, &attrVal);
        num = @intCast(attrVal >> 32);
        den = @intCast(attrVal & 0xFFFF_FFFF);
        var sub: win.GUID = std.mem.zeroes(win.GUID);
        _ = cur.?.*.lpVtbl.*.GetGUID.?(cur, &win.c.MF_MT_SUBTYPE, &sub);
        release(cur);
        var dur: win.c.PROPVARIANT = std.mem.zeroes(win.c.PROPVARIANT);
        win.PropVariantInit(&dur);
        const durRaw: *PVLayout = @ptrCast(&dur);
        if (g_reader.?.*.lpVtbl.*.GetPresentationAttribute.?(g_reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_MEDIASOURCE))),
            &win.c.MF_PD_DURATION, &dur) == win.S_OK and durRaw.vt == @as(u16, @intCast(win.c.VT_I8)))
        {
            g_duration = durRaw.hVal;
        }
        win.PropVariantClear(&dur);
        if (g_vw == 0 or g_vh == 0) {
            dpLog("size failed", .{});
            d3dShutdown();
            return false;
        }
        g_upIsNv12 = (sub.Data1 == win.c.MFVideoFormat_NV12.Data1 and
            sub.Data2 == win.c.MFVideoFormat_NV12.Data2 and
            sub.Data3 == win.c.MFVideoFormat_NV12.Data3 and
            std.mem.eql(u8, &sub.Data4, &win.c.MFVideoFormat_NV12.Data4));
        if (num > 0 and den > 0) {
            var ms: win.UINT = @intCast((1000 * den) / num);
            if (ms < 10) ms = 10;
            if (ms > 100) ms = 100;
            g_frameMs = ms;
        }
    }

    // 5. 上传纹理（NV12 或 RGB32）
    var td: win.c.D3D11_TEXTURE2D_DESC = undefined;
    td.Width = g_vw;
    td.Height = g_vh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = if (g_upIsNv12) win.c.DXGI_FORMAT_NV12 else win.c.DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc = .{ .Count = 1, .Quality = 0 };
    td.Usage = win.c.D3D11_USAGE_DEFAULT;
    td.BindFlags = 0;
    td.CPUAccessFlags = 0;
    td.MiscFlags = 0;
    hr = g_dev.?.*.lpVtbl.*.CreateTexture2D.?(g_dev, &td, null, &g_upTex);
    if (hr != win.S_OK or g_upTex == null) {
        dpLog("upload tex failed hr=0x{X}", .{hr});
        d3dShutdown();
        return false;
    }

    // 6. 交换链 + VideoProcessor
    if (!buildDrawChain()) {
        d3dShutdown();
        return false;
    }

    dpLog("init ok {d}x{d} {d}ms {s} {s}", .{ g_vw, g_vh, g_frameMs, if (g_upIsNv12) "NV12" else "RGB32", if (g_hwDecode) "DXVA" else "soft" });

    g_active = true;
    g_startTick = win.c.GetTickCount64();
    return true;
}

// ---------- VP 合成一帧到后备缓冲；present 时同步上屏 ----------
fn bltVp(view: ?*win.c.ID3D11VideoProcessorInputView) bool {
    var vs: win.c.D3D11_VIDEO_PROCESSOR_STREAM = std.mem.zeroes(win.c.D3D11_VIDEO_PROCESSOR_STREAM);
    vs.Enable = win.c.TRUE;
    vs.OutputIndex = 0;
    vs.InputFrameOrField = 0;
    vs.pInputSurface = view;
    const hr = g_vc.?.*.lpVtbl.*.VideoProcessorBlt.?(g_vc, g_vp.?, g_outView, 0, 1, &vs);
    if (hr != win.S_OK) {
        bltVp_n += 1;
        if (bltVp_n == 1 or bltVp_n % 500 == 0) dpLog("vpblt failed hr=0x{X}", .{hr});
        return false;
    }
    return true;
}
var bltVp_n: win.UINT = 0;

fn presentNow() bool {
    const hr = g_swap.?.*.lpVtbl.*.Present.?(g_swap, 1, 0); // 垂直同步
    if (present_logged == false) {
        dpLog("first present hr=0x{X}", .{hr});
        present_logged = true;
    }
    if (hr != win.S_OK) {
        present_n += 1;
        if (present_n == 1 or present_n % 500 == 0) dpLog("present failed hr=0x{X}", .{hr});
    }
    return hr == win.S_OK;
}
var present_logged: bool = false;
var present_n: win.UINT = 0;

fn drawSample(sample: ?*win.c.IMFSample, present: bool) bool {
    if (sample == null or g_outView == null) return false;
    var buf: ?*win.c.IMFMediaBuffer = null;
    const hr = sample.?.*.lpVtbl.*.ConvertToContiguousBuffer.?(sample, &buf);
    if (hr != win.S_OK or buf == null) return false;

    // ---- 路径 1：DXVA 零拷贝（buffer 直接封装 GPU 纹理）----
    var dxb: ?*win.c.IMFDXGIBuffer = null;
    if (buf.?.*.lpVtbl.*.QueryInterface.?(buf, &win.IID_IMFDXGIBuffer, @ptrCast(&dxb)) == win.S_OK and dxb != null) {
        var tex: ?*win.c.ID3D11Texture2D = null;
        var sub: win.UINT = 0;
        if (buf.?.*.lpVtbl.*.QueryInterface.?(buf, &win.IID_ID3D11Texture2D, @ptrCast(&tex)) == win.S_OK and tex != null and
            dxb.?.*.lpVtbl.*.GetSubresourceIndex.?(dxb, &sub) == win.S_OK)
        {
            var ivd: win.c.D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC = std.mem.zeroes(win.c.D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC);
            ivd.ViewDimension = win.c.D3D11_VPIV_DIMENSION_TEXTURE2D;
            // 解码器输出纹理必须显式声明 FourCC，否则视图采样全黑（实测复现）
            ivd.FourCC = if (g_upIsNv12) win.MAKEFOURCC('N', 'V', '1', '2') else 0;
            { // ArraySlice 在 union 内 offset 12（FourCC 4 + ViewDimension 4 + MipSlice 4）
                const p: [*]u8 = @ptrCast(&ivd);
                @as(*u32, @ptrCast(@alignCast(p + 12))).* = sub;
            }
            var view: ?*win.c.ID3D11VideoProcessorInputView = null;
            if (g_vd.?.*.lpVtbl.*.CreateVideoProcessorInputView.?(g_vd, @ptrCast(tex.?), g_vpe, &ivd, &view) == win.S_OK and view != null) {
                const ok = bltVp(view);
                if (zerocopy_logged == false) {
                    dpLog("frame: zerocopy path", .{});
                    zerocopy_logged = true;
                }
                release(view);
                release(tex);
                release(dxb);
                release(buf);
                if (ok and present) return presentNow();
                return ok;
            }
            release(tex);
        }
        release(dxb);
    }

    // ---- 路径 2：系统内存上传（软解 / 零拷贝不可用时）----
    if (g_upTex == null or g_inView == null) {
        release(buf);
        return false;
    }
    var b2d: ?*win.c.IMF2DBuffer = null;
    var p: [*]win.BYTE = undefined;
    var pitch: win.LONG = 0;
    const locked2d = buf.?.*.lpVtbl.*.QueryInterface.?(buf, &win.IID_IMF2DBuffer, @ptrCast(&b2d)) == win.S_OK and b2d != null and
        b2d.?.*.lpVtbl.*.Lock2D.?(b2d, @ptrCast(&p), &pitch) == win.S_OK;
    var pAny: ?[*]win.BYTE = if (locked2d) p else null;
    if (locked2d and pitch < 0) {
        // 负 stride = bottom-up，翻行序
        pAny = p + @as(usize, @intCast(-pitch)) * (g_vh - 1);
        pitch = -pitch;
    }
    if (!locked2d) {
        var len: win.DWORD = 0;
        if (buf.?.*.lpVtbl.*.Lock.?(buf, @ptrCast(&pAny), null, &len) != win.S_OK or pAny == null) {
            release(buf);
            return false;
        }
        pitch = if (g_upIsNv12) @intCast(g_vw) else @intCast(g_vw * 4);
    }

    if (g_upIsNv12) {
        // Y 平面 → subresource 0；UV 平面 → subresource 1
        g_ctx.?.*.lpVtbl.*.UpdateSubresource.?(g_ctx, @ptrCast(g_upTex), 0, null, @ptrCast(pAny), @as(win.UINT, @intCast(pitch)), 0);
        g_ctx.?.*.lpVtbl.*.UpdateSubresource.?(g_ctx, @ptrCast(g_upTex), 1, null,
            @ptrCast(pAny.? + @as(usize, @intCast(pitch)) * g_vh), @as(win.UINT, @intCast(pitch)), 0);
    } else {
        g_ctx.?.*.lpVtbl.*.UpdateSubresource.?(g_ctx, @ptrCast(g_upTex), 0, null, @ptrCast(pAny), @as(win.UINT, @intCast(pitch)), 0);
    }

    if (locked2d) _ = b2d.?.*.lpVtbl.*.Unlock2D.?(b2d) else _ = buf.?.*.lpVtbl.*.Unlock.?(buf);
    release(b2d);
    release(buf);

    // GPU 转换 NV12→RGB 并缩放到屏幕
    if (!bltVp(g_inView)) return false;
    if (present) return presentNow();
    return true;
}
var zerocopy_logged: bool = false;

// ---------- 泵帧：按墙上时钟追帧 + 无缝循环 ----------
pub fn d3dPumpFrame() win.UINT {
    if (!g_active or g_reader == null) return 33;

    // 延迟 trim（播放稳定后归还备用页，任务管理器占用下降）
    if (!g_trimmed and g_startTick != 0 and win.c.GetTickCount64() - g_startTick > 15000) {
        g_trimmed = true;
        _ = win.c.SetProcessWorkingSetSize(win.c.GetCurrentProcess(), @as(win.SIZE_T, @bitCast(@as(isize, -1))), @as(win.SIZE_T, @bitCast(@as(isize, -1))));
    }

    // 窗口尺寸变了（重嵌入/分辨率切换）→ 重建交换链自适应
    if (g_hwnd != null and win.c.IsWindow(g_hwnd.?) != 0) {
        var rc: win.RECT = undefined;
        _ = win.c.GetClientRect(g_hwnd.?, &rc);
        if (rc.right > 0 and rc.bottom > 0 and
            (@as(win.UINT, @intCast(rc.right)) != g_scW or @as(win.UINT, @intCast(rc.bottom)) != g_scH))
        {
            _ = buildDrawChain();
        }
    }

    const now: i64 = @intCast(win.c.GetTickCount64());
    if (g_startWall == 0) {
        g_startWall = now;
        g_lastTs = -1;
    }
    // 目标时间点（100ns）：视频时间轴上"现在应该播到的位置"
    const target = g_startTs + (now - g_startWall) * 10000;

    var drawn: i32 = 0;
    while (g_lastTs < target and drawn < 4 and g_reader != null) {
        var flags: win.DWORD = 0;
        var ts: i64 = 0;
        var s: ?*win.c.IMFSample = null;
        const hr = g_reader.?.*.lpVtbl.*.ReadSample.?(g_reader, @as(c_ulong, @bitCast(@as(c_int, win.c.MF_SOURCE_READER_FIRST_VIDEO_STREAM))), 0, null, &flags, &ts, &s);
        if (hr != win.S_OK) {
            dpLog("readsample failed hr=0x{X}", .{hr});
            g_active = false;
            return 16;
        }
        if (flags & win.c.MF_SOURCE_READERF_ENDOFSTREAM != 0) {
            if (s != null) {
                release(s);
                s = null;
            }
            // ★ 无缝循环：seek 回开头，渲染管线不中断、交换链保留画面。
            const pos: i64 = if (g_loopRetry == 0) 0 else 1;
            var pv: win.c.PROPVARIANT = std.mem.zeroes(win.c.PROPVARIANT);
            win.PropVariantInit(&pv);
            const pvRaw: *PVLayout = @ptrCast(&pv);
            pvRaw.vt = @intCast(win.c.VT_I8);
            pvRaw.hVal = pos;
            const zeroGuid: win.GUID = std.mem.zeroes(win.GUID);
            const seekHr = g_reader.?.*.lpVtbl.*.SetCurrentPosition.?(g_reader, &zeroGuid, &pv);
            win.PropVariantClear(&pv);
            const loopProbs = seekHr != win.S_OK or g_loopRetry >= 2;
            if (loopProbs) {
                // 分级回退的最后一级：重建整个 SourceReader
                const nr = createReader(true);
                const nr2 = if (nr == null) createReader(false) else nr;
                if (nr2 != null) {
                    release(g_reader);
                    g_reader = nr2;
                    dpLog("loop: reader rebuilt", .{});
                } else {
                    dpLog("loop rebuild failed", .{});
                    g_active = false;
                    return 500;
                }
            } else {
                g_loopRetry += 1;
            }
            g_loopCount += 1;
            // 循环日志限频（异常/首轮/每 500 轮）
            if (loopProbs or g_loopCount == 1 or g_loopCount % 500 == 0) {
                dpLog("eos ts={d:.2}s loop={} {s}", .{ @as(f64, @floatFromInt(g_lastTs)) / 10000000.0, g_loopCount, if (loopProbs) "(seek/reader problems)" else "" });
            }
            // 重置播放时钟：从新的一轮第 0ms 起算
            g_startWall = now;
            g_startTs = 0;
            g_lastTs = -1;
            // ★ 必须 break，不能 continue：target 已置 0、g_lastTs=-1 会让 while
            // 条件 (-1 < 0) 恒真，且 drawn 在 EOS 路径不自增 → 源持续 EOS 时退化为
            // 无界自旋，独占消息循环导致看门狗/关闭握手失效。break 后本 tick 直接
            // 呈现保留帧，下个 tick 从新一轮正常读帧。
            break;
        }
        if (s == null) break; // STREAMTICK 空帧：等下个 tick
        const ok = drawSample(s, false); // 只合成到后备缓冲
        if (ok) {
            g_lastTs = ts;
            g_loopRetry = 0;
            drawn += 1;
        }
        release(s);
        if (!ok) break;
    }

    // 本 tick 无论是否更新内容都 vsync 呈现（重复帧无开销，节奏对齐刷新率）
    if (g_swap != null) _ = presentNow();
    return 8; // 高频 tick：追帧逻辑吸收定时器误差
}

// ---------- 重绑窗口（看门狗重建/重嵌入后） ----------
pub fn d3dSetWindow(hwnd: win.HWND) void {
    if (g_hwnd != null and g_hwnd.? == hwnd) return;
    g_hwnd = hwnd;
    if (g_dev != null) _ = buildDrawChain(); // 换窗口 = 交换链必须重建
}

// ---------- 关闭 ----------
pub fn d3dShutdown() void {
    g_active = false;
    g_trimmed = false;
    g_startTick = 0;
    g_loopCount = 0;
    g_lastTs = 0;
    g_startWall = 0;
    g_startTs = 0;
    g_loopRetry = 0;
    bltVp_n = 0;
    present_n = 0;
    present_logged = false;
    zerocopy_logged = false;
    releaseDrawChain();
    release(g_upTex);
    release(g_reader);
    release(g_dxm);
    release(g_vc);
    release(g_vd);
    release(g_ctx);
    release(g_dev);
    g_upTex = null;
    g_reader = null;
    g_dxm = null;
    g_vc = null;
    g_vd = null;
    g_ctx = null;
    g_dev = null;
    g_hwnd = null;
    g_scW = 0;
    g_scH = 0;
    g_vw = 0;
    g_vh = 0;
    g_hwDecode = false;
}

// d3dplayer.rs — DXVA 硬解 + D3D11 VideoProcessor + DirectComposition 视频壁纸
// 对齐 cpp/d3dplayer.cpp：无缝循环（EOS → seek(0) → seek(1) → 重建 reader）。
//
// 渲染管线：MF SourceReader(DXVA) → NV12/RGB32 → UpdateSubresource 上传
//          → VideoProcessor GPU 转换/缩放 → Composition 交换链 Present(vsync)
//          → DirectComposition Visual（layered 跨进程子窗口唯一可靠呈现路径）。

use std::cell::Cell;

use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::DirectComposition::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::*;
use windows::Win32::Graphics::Direct3D10::ID3D10Multithread;
use windows::Win32::System::Threading::SetProcessWorkingSetSize;
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::System::Threading::GetCurrentProcess;
use windows::Win32::System::Variant::VT_I8;
use windows::Win32::UI::WindowsAndMessaging::{
    GetClientRect, GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN,
};

use crate::common;

#[derive(Default)]
struct State {
    dev: Option<ID3D11Device>,
    ctx: Option<ID3D11DeviceContext>,
    swap: Option<IDXGISwapChain1>,
    dcomp: Option<IDCompositionDevice>,
    target: Option<IDCompositionTarget>,
    visual: Option<IDCompositionVisual>,
    vd: Option<ID3D11VideoDevice>,
    vc: Option<ID3D11VideoContext>,
    vpe: Option<ID3D11VideoProcessorEnumerator>,
    vp: Option<ID3D11VideoProcessor>,
    in_view: Option<ID3D11VideoProcessorInputView>,
    out_view: Option<ID3D11VideoProcessorOutputView>,
    dxm: Option<IMFDXGIDeviceManager>,
    reader: Option<IMFSourceReader>,
    up_tex: Option<ID3D11Texture2D>,
    up_is_nv12: bool,
    vw: u32,
    vh: u32,
    frame_ms: u32,
    sc_w: u32,
    sc_h: u32,
    hwnd: HWND,
    active: bool,
    hw_decode: bool,
    start_tick: u64,
    trimmed: bool,
    path: String,
    loop_retry: i32,
    last_ts: i64,
    start_wall: u64,
    start_ts: i64,
}

thread_local! {
    static S: Cell<State> = Cell::new(State::default());
}

fn log(tag: &str, msg: &str) {
    common::log(tag, msg);
}

unsafe fn release_chain(s: &mut State) {
    s.in_view = None;
    s.out_view = None;
    s.vp = None;
    s.vpe = None;
    s.visual = None;
    s.target = None;
    s.dcomp = None;
    s.swap = None;
}

unsafe fn create_reader(path: &str, use_dxva: bool, dxm: Option<&IMFDXGIDeviceManager>) -> Option<IMFSourceReader> {
    let mut attr: Option<IMFAttributes> = None;
    if MFCreateAttributes(&mut attr, 4).is_err() {
        return None;
    }
    let attr = attr?;
    if use_dxva {
        if let Some(m) = dxm {
            let _ = attr.SetUnknown(&MF_SOURCE_READER_D3D_MANAGER, m);
            let _ = attr.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
        }
    }

    // 字节流打开（含中文路径时 FromURL 会解析异常，实测复现）
    let wpath: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    let stream = MFCreateFile(
        MF_ACCESSMODE_READ,
        MF_OPENMODE_FAIL_IF_NOT_EXIST,
        MF_FILEFLAGS_NONE,
        PCWSTR(wpath.as_ptr()),
    )
    .ok()?;

    let reader = MFCreateSourceReaderFromByteStream(&stream, &attr).ok()?;

    let _ = reader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false);
    let _ = reader.SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32, true);

    let (first, second) = if use_dxva {
        (MFVideoFormat_RGB32, MFVideoFormat_NV12)
    } else {
        (MFVideoFormat_NV12, MFVideoFormat_RGB32)
    };

    for sub in [first, second] {
        let mt = match MFCreateMediaType() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let _ = mt.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video);
        let _ = mt.SetGUID(&MF_MT_SUBTYPE, &sub);
        if reader
            .SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32, None, &mt)
            .is_ok()
        {
            return Some(reader);
        }
    }
    None
}

unsafe fn build_chain(s: &mut State) -> bool {
    release_chain(s);
    let dev = match &s.dev {
        Some(d) => d,
        None => return false,
    };
    let vd = match &s.vd {
        Some(v) => v,
        None => return false,
    };
    if s.hwnd.0.is_null() || s.vw == 0 {
        return false;
    }

    let mut rc = RECT::default();
    let _ = GetClientRect(s.hwnd, &mut rc);
    let mut w = (rc.right - rc.left) as u32;
    let mut h = (rc.bottom - rc.top) as u32;
    if w == 0 || h == 0 {
        w = GetSystemMetrics(SM_CXSCREEN) as u32;
        h = GetSystemMetrics(SM_CYSCREEN) as u32;
    }
    if w == 0 || h == 0 {
        return false;
    }

    // Composition 交换链（FLIP）
    let sd = DXGI_SWAP_CHAIN_DESC1 {
        Width: w,
        Height: h,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
        BufferCount: 2,
        SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
        AlphaMode: DXGI_ALPHA_MODE_IGNORE,
        ..Default::default()
    };
    let factory: IDXGIFactory2 = match CreateDXGIFactory1() {
        Ok(f) => f,
        Err(_) => return false,
    };
    let swap = match factory.CreateSwapChainForComposition(dev, &sd, None) {
        Ok(sw) => sw,
        Err(e) => {
            log("d3d", &format!("comp swapchain failed {e:?}"));
            return false;
        }
    };

    let dxgi_dev: IDXGIDevice = match dev.cast() {
        Ok(d) => d,
        Err(_) => return false,
    };
    let dcomp: IDCompositionDevice = match DCompositionCreateDevice(&dxgi_dev) {
        Ok(d) => d,
        Err(_) => return false,
    };
    let target = match dcomp.CreateTargetForHwnd(s.hwnd, true) {
        Ok(t) => t,
        Err(_) => return false,
    };
    let visual = match dcomp.CreateVisual() {
        Ok(v) => v,
        Err(_) => return false,
    };
    if visual.SetContent(&swap).is_err() {
        return false;
    }
    if target.SetRoot(&visual).is_err() || dcomp.Commit().is_err() {
        return false;
    }

    // VideoProcessor
    let cd = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
        InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
        InputFrameRate: DXGI_RATIONAL { Numerator: 0, Denominator: 0 },
        InputWidth: s.vw,
        InputHeight: s.vh,
        OutputFrameRate: DXGI_RATIONAL { Numerator: 0, Denominator: 0 },
        OutputWidth: w,
        OutputHeight: h,
        Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
    };
    let vpe = match vd.CreateVideoProcessorEnumerator(&cd) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let vp = match vd.CreateVideoProcessor(&vpe, 0) {
        Ok(v) => v,
        Err(_) => return false,
    };

    let up_tex = match &s.up_tex {
        Some(t) => t,
        None => return false,
    };
    let ivd = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
        ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
        ..Default::default()
    };
    let mut in_view_opt: Option<ID3D11VideoProcessorInputView> = None;
    if vd
        .CreateVideoProcessorInputView(up_tex, &vpe, &ivd, Some(&mut in_view_opt))
        .is_err()
    {
        return false;
    }
    let in_view = match in_view_opt {
        Some(v) => v,
        None => return false,
    };

    let bb: ID3D11Texture2D = match swap.GetBuffer(0) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let ovd = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
        ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
        ..Default::default()
    };
    let mut out_view_opt: Option<ID3D11VideoProcessorOutputView> = None;
    if vd
        .CreateVideoProcessorOutputView(&bb, &vpe, &ovd, Some(&mut out_view_opt))
        .is_err()
    {
        return false;
    }
    let out_view = match out_view_opt {
        Some(v) => v,
        None => return false,
    };

    let vc = match &s.vc {
        Some(v) => v,
        None => return false,
    };
    let src = RECT { left: 0, top: 0, right: s.vw as i32, bottom: s.vh as i32 };
    let dst = RECT { left: 0, top: 0, right: w as i32, bottom: h as i32 };
    let _ = vc.VideoProcessorSetStreamSourceRect(&vp, 0, true, Some(&src));
    let _ = vc.VideoProcessorSetStreamDestRect(&vp, 0, true, Some(&dst));
    let _ = vc.VideoProcessorSetStreamFrameFormat(&vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    let cs = D3D11_VIDEO_PROCESSOR_COLOR_SPACE {
        _bitfield: 0, // Usage=0(playback), RGB_Range=0(full), YCbCr_Matrix=1(BT.709)
    };
    let _ = vc.VideoProcessorSetStreamColorSpace(&vp, 0, &cs);
    let ocs = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: 0 };
    let _ = vc.VideoProcessorSetOutputColorSpace(&vp, &ocs);

    s.swap = Some(swap);
    s.dcomp = Some(dcomp);
    s.target = Some(target);
    s.visual = Some(visual);
    s.vpe = Some(vpe);
    s.vp = Some(vp);
    s.in_view = Some(in_view);
    s.out_view = Some(out_view);
    s.sc_w = w;
    s.sc_h = h;
    log("d3d", "swapchain: dcomp-model");
    true
}

pub fn init(hwnd: HWND, path: &str) -> bool {
    shutdown();
    S.with(|c| {
        let mut s = c.replace(State::default());
        s.hwnd = hwnd;
        s.path = path.to_string();
        unsafe {
            let flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
            let mut dev: Option<ID3D11Device> = None;
            let mut ctx: Option<ID3D11DeviceContext> = None;
            let mut fl = D3D_FEATURE_LEVEL_11_0;
            let hr = D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                flags,
                None,
                D3D11_SDK_VERSION,
                Some(&mut dev),
                Some(&mut fl),
                Some(&mut ctx),
            );
            if hr.is_err() || dev.is_none() {
                c.set(s);
                return false;
            }
            let dev = dev.unwrap();
            let ctx = ctx.unwrap();

            // MF 解码工作线程共用 device，必须开多线程保护
            if let Ok(mt) = dev.cast::<ID3D10Multithread>() {
                let _ = mt.SetMultithreadProtected(true);
            }

            let vd: ID3D11VideoDevice = match dev.cast() {
                Ok(v) => v,
                Err(_) => {
                    c.set(s);
                    return false;
                }
            };
            let vc: ID3D11VideoContext = match ctx.cast() {
                Ok(v) => v,
                Err(_) => {
                    c.set(s);
                    return false;
                }
            };

            let mut token: u32 = 0;
            let mut dxm: Option<IMFDXGIDeviceManager> = None;
            if MFCreateDXGIDeviceManager(&mut token, &mut dxm).is_ok() {
                if let Some(m) = &dxm {
                    if m.ResetDevice(&dev, token).is_err() {
                        dxm = None;
                    }
                }
            }

            let reader = create_reader(path, true, dxm.as_ref())
                .or_else(|| create_reader(path, false, None));
            let reader = match reader {
                Some(r) => r,
                None => {
                    c.set(s);
                    return false;
                }
            };
            s.hw_decode = dxm.is_some();

            let cur = match reader.GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32) {
                Ok(t) => t,
                Err(_) => {
                    c.set(s);
                    return false;
                }
            };
            let packed = cur.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
            s.vw = (packed >> 32) as u32;
            s.vh = (packed & 0xFFFF_FFFF) as u32;
            let sub = cur.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default();
            s.up_is_nv12 = sub == MFVideoFormat_NV12;
            let packed = cur.GetUINT64(&MF_MT_FRAME_RATE).unwrap_or(0);
            let num = (packed >> 32) as u32;
            let den = (packed & 0xFFFF_FFFF) as u32;
            if num > 0 && den > 0 {
                let mut ms = (1000u64 * den as u64 / num as u64) as u32;
                ms = ms.clamp(10, 100);
                s.frame_ms = ms;
            }

            if s.vw == 0 || s.vh == 0 {
                c.set(s);
                return false;
            }

            let td = D3D11_TEXTURE2D_DESC {
                Width: s.vw,
                Height: s.vh,
                MipLevels: 1,
                ArraySize: 1,
                Format: if s.up_is_nv12 { DXGI_FORMAT_NV12 } else { DXGI_FORMAT_B8G8R8A8_UNORM },
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: 0,
                CPUAccessFlags: 0,
                MiscFlags: 0,
            };
            let mut tex: Option<ID3D11Texture2D> = None;
            if dev.CreateTexture2D(&td, None, Some(&mut tex)).is_err() {
                c.set(s);
                return false;
            }

            s.dev = Some(dev);
            s.ctx = Some(ctx);
            s.vd = Some(vd);
            s.vc = Some(vc);
            s.dxm = dxm;
            s.reader = Some(reader);
            s.up_tex = tex;

            let ok = build_chain(&mut s);
            s.active = ok;
            s.start_tick = GetTickCount64();
            log("d3d", &format!("init ok {}x{} {}ms {} {}", s.vw, s.vh, s.frame_ms,
                if s.up_is_nv12 { "NV12" } else { "RGB32" },
                if s.hw_decode { "DXVA" } else { "soft" }));
            c.set(s);
            ok
        }
    })
}

pub fn pump_frame() -> u32 {
    S.with(|c| {
        let mut s = c.replace(State::default());
        if !s.active || s.reader.is_none() {
            c.set(s);
            return 33;
        }
        unsafe {
            if !s.trimmed && GetTickCount64() - s.start_tick > 15000 {
                s.trimmed = true;
                let _ = SetProcessWorkingSetSize(GetCurrentProcess(), usize::MAX, usize::MAX);
            }

            // 窗口尺寸变化 → 重建交换链
            if !s.hwnd.0.is_null() {
                let mut rc = RECT::default();
                let _ = GetClientRect(s.hwnd, &mut rc);
                let w = (rc.right - rc.left) as u32;
                let h = (rc.bottom - rc.top) as u32;
                if w > 0 && h > 0 && (w != s.sc_w || h != s.sc_h) {
                    build_chain(&mut s);
                }
            }

            let now = GetTickCount64();
            if s.start_wall == 0 {
                s.start_wall = now;
                s.last_ts = -1;
            }
            let target = s.start_ts + ((now - s.start_wall) as i64) * 10000;

            let reader = s.reader.clone().unwrap();
            let mut drawn = 0;
            while s.last_ts < target && drawn < 4 {
                let mut flags = 0u32;
                let mut ts: i64 = 0;
                let mut sample: Option<IMFSample> = None;
                if reader
                    .ReadSample(
                        MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                        0,
                        None,
                        Some(&mut flags),
                        Some(&mut ts),
                        Some(&mut sample),
                    )
                    .is_err()
                {
                    log("d3d", "readsample failed");
                    s.active = false;
                    c.set(s);
                    return 16;
                }
                if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                    // 无缝循环：seek 分级回退
                    let pos = if s.loop_retry == 0 { 0 } else { 1 };
                    let pv = PROPVARIANT::from(pos as i64);
                    let seek_ok = reader.SetCurrentPosition(&GUID::default(), &pv).is_ok();
                    let probs = !seek_ok || s.loop_retry >= 2;
                    if probs {
                        let nr = create_reader(&s.path, true, s.dxm.as_ref())
                            .or_else(|| create_reader(&s.path, false, None));
                        if let Some(nr) = nr {
                            s.reader = Some(nr);
                        } else {
                            s.active = false;
                            c.set(s);
                            return 500;
                        }
                    } else {
                        s.loop_retry += 1;
                    }
                    s.start_wall = now;
                    s.start_ts = 0;
                    s.last_ts = -1;
                    break;
                }
                let sample = match sample {
                    Some(x) => x,
                    None => break,
                };
                if draw_sample(&mut s, &sample) {
                    s.last_ts = ts;
                    s.loop_retry = 0;
                    drawn += 1;
                } else {
                    break;
                }
            }

            if let Some(sw) = &s.swap {
                let _ = sw.Present(1, DXGI_PRESENT(0));
            }
            c.set(s);
            8
        }
    })
}

unsafe fn draw_sample(s: &mut State, sample: &IMFSample) -> bool {
    let buf = match sample.ConvertToContiguousBuffer() {
        Ok(b) => b,
        Err(_) => return false,
    };

    // 路径 1：DXVA 零拷贝（buffer 封装 GPU 纹理）
    if let Ok(dxb) = buf.cast::<IMFDXGIBuffer>() {
        let mut ptr: *mut core::ffi::c_void = std::ptr::null_mut();
        if dxb.GetResource(&ID3D11Texture2D::IID, &mut ptr).is_ok() && !ptr.is_null() {
            let tex = ID3D11Texture2D::from_raw(ptr);
            let sub = dxb.GetSubresourceIndex().unwrap_or(0);
            if let (Some(vd), Some(vpe)) = (&s.vd, &s.vpe) {
                let ivd = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                    ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                    ..Default::default()
                };
                let mut view_opt: Option<ID3D11VideoProcessorInputView> = None;
                if vd
                    .CreateVideoProcessorInputView(&tex, vpe, &ivd, Some(&mut view_opt))
                    .is_ok()
                {
                    let view = match view_opt {
                        Some(v) => v,
                        None => return false,
                    };
                    let ok = blt_vp(s, &view);
                    log("d3d", "frame: zerocopy path");
                    if ok {
                        return true;
                    }
                }
            }
        }
    }

    // 路径 2：系统内存上传
    let (up_tex, in_view, vc, vp, out_view) = match (&s.up_tex, &s.in_view, &s.vc, &s.vp, &s.out_view) {
        (Some(a), Some(b), Some(c_), Some(d), Some(e)) => (a, b, c_, d, e),
        _ => return false,
    };
    let mut p: *mut u8 = std::ptr::null_mut();
    let mut pitch: i32 = 0;
    if let Ok(b2d) = buf.cast::<IMF2DBuffer>() {
        if b2d.Lock2D(&mut p, &mut pitch).is_err() {
            return false;
        }
        let (pp, ppitch) = if pitch < 0 {
            (p.offset(-(pitch as isize) * (s.vh as isize - 1)), -pitch)
        } else {
            (p, pitch)
        };
        if let Some(ctx) = &s.ctx {
            if s.up_is_nv12 {
                ctx.UpdateSubresource(up_tex, 0, None, pp as *const _, ppitch as u32, 0);
                ctx.UpdateSubresource(
                    up_tex,
                    1,
                    None,
                    pp.offset(ppitch as isize * s.vh as isize) as *const _,
                    ppitch as u32,
                    0,
                );
            } else {
                ctx.UpdateSubresource(up_tex, 0, None, pp as *const _, ppitch as u32, 0);
            }
        }
        let _ = b2d.Unlock2D();
    } else {
        return false;
    }

    let _ = (vc, vp, out_view);
    blt_vp(s, in_view)
}

unsafe fn blt_vp(s: &State, view: &ID3D11VideoProcessorInputView) -> bool {
    let (vc, vp, out_view) = match (&s.vc, &s.vp, &s.out_view) {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => return false,
    };
    let stream = D3D11_VIDEO_PROCESSOR_STREAM {
        Enable: TRUE,
        pInputSurface: std::mem::ManuallyDrop::new(Some(view.clone())),
        ..Default::default()
    };
    vc.VideoProcessorBlt(vp, out_view, 0, &[stream]).is_ok()
}

pub fn set_window(hwnd: HWND) {
    S.with(|c| {
        let mut s = c.replace(State::default());
        if s.hwnd == hwnd {
            c.set(s);
            return;
        }
        s.hwnd = hwnd;
        if s.dev.is_some() {
            unsafe {
                build_chain(&mut s);
            }
        }
        c.set(s);
    })
}

pub fn shutdown() {
    S.with(|c| {
        let mut s = c.replace(State::default());
        s.active = false;
        unsafe {
            release_chain(&mut s);
        }
        s.up_tex = None;
        s.reader = None;
        s.dxm = None;
        s.vc = None;
        s.vd = None;
        s.ctx = None;
        s.dev = None;
        s.hwnd = HWND::default();
        s.sc_w = 0;
        s.sc_h = 0;
        s.vw = 0;
        s.vh = 0;
        c.set(s);
    })
}

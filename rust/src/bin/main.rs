// main.rs — KiloWallpaper (Rust) 主进程，对齐 cpp/main.cpp
//
// 入口 / 窗口 / 看门狗 / 帧调度 / 配置 / 单实例 / 守护互保。

use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Graphics::GdiPlus::*;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use kilowallpaper::{common, d3dplayer, desktop, media, render, state};

const TIMER_FRAME: usize = 1;
const TIMER_WATCHDOG: usize = 2;
const WATCHDOG_MS: u32 = 3000;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_CREATE => {
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            state::WIN_W.set(rc.right - rc.left);
            state::WIN_H.set(rc.bottom - rc.top);
            LRESULT(0)
        }
        WM_SIZE => {
            state::WIN_W.set((lp.0 & 0xFFFF) as i32);
            state::WIN_H.set(((lp.0 >> 16) & 0xFFFF) as i32);
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_DISPLAYCHANGE | WM_DPICHANGED => {
            desktop::fit_to_parent_or_monitor(hwnd);
            let _ = InvalidateRect(hwnd, None, false);
            LRESULT(0)
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = BeginPaint(hwnd, &mut ps);
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            let w = rc.right - rc.left;
            let h = rc.bottom - rc.top;
            if w > 0 && h > 0 && !state::IS_VIDEO.get() {
                render::ensure_backbuffer(dc, w, h);
                let mem = render::get_mem_dc();
                if !mem.0.is_null() {
                    let br = CreateSolidBrush(COLORREF(0));
                    FillRect(mem, &rc, br);
                    let _ = DeleteObject(br);
                    render::draw_gif_frame(mem, w, h);
                    let _ = BitBlt(dc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
                }
            }
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_DESTROY => {
            if state::WALLPAPER_HWND.get() == hwnd {
                state::WALLPAPER_HWND.set(HWND::default());
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

unsafe extern "system" fn host_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let taskbar = state::TASKBAR_CREATED.get();
    if taskbar != 0 && msg == taskbar {
        watchdog_tick();
        return LRESULT(0);
    }
    match msg {
        WM_TIMER => {
            if wp.0 == TIMER_WATCHDOG {
                watchdog_tick();
            } else if wp.0 == TIMER_FRAME {
                advance_frame();
            }
            LRESULT(0)
        }
        WM_DISPLAYCHANGE => {
            let h = state::WALLPAPER_HWND.get();
            if !h.0.is_null() {
                desktop::fit_to_parent_or_monitor(h);
                let _ = InvalidateRect(h, None, false);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn advance_frame() {
    let hwnd = state::WALLPAPER_HWND.get();
    if hwnd.0.is_null() {
        return;
    }
    if state::IS_VIDEO.get() {
        let mut next = d3dplayer::pump_frame();
        if next < 10 {
            next = 10;
        }
        unsafe {
            SetTimer(state::HOST_HWND.get(), TIMER_FRAME, next, None);
        }
    } else {
        let fc = state::FRAME_COUNT.get();
        if fc == 0 {
            return;
        }
        if fc == 1 {
            unsafe {
                let _ = InvalidateRect(hwnd, None, false);
            }
            return;
        }
        let cur = (state::CUR_FRAME.get() + 1) % fc;
        state::CUR_FRAME.set(cur);
        let mut delay = *state::DELAYS.borrow().get(cur as usize).unwrap_or(&100);
        if delay < 10 {
            delay = 10;
        }
        unsafe {
            SetTimer(state::HOST_HWND.get(), TIMER_FRAME, delay, None);
            let _ = InvalidateRect(hwnd, None, false);
        }
    }
}

fn consume_quit() -> bool {
    if common::file_exists("wallpaper.quit") {
        common::delete_file("wallpaper.quit");
        return true;
    }
    false
}

fn watchdog_tick() {
    if consume_quit() {
        common::write_marker("wallpaper.graceful");
        unsafe {
            PostQuitMessage(0);
        }
        return;
    }
    let mut hwnd = state::WALLPAPER_HWND.get();
    if hwnd.0.is_null() || unsafe { !IsWindow(hwnd).as_bool() } {
        if !create_wallpaper_window() {
            return;
        }
        hwnd = state::WALLPAPER_HWND.get();
        desktop::embed_or_fallback(hwnd);
        d3dplayer::set_window(hwnd);
        return;
    }
    let p = unsafe { GetParent(hwnd).unwrap_or_default() };
    if p.0.is_null() || unsafe { !IsWindow(p).as_bool() } {
        desktop::embed_or_fallback(hwnd);
        d3dplayer::set_window(hwnd);
    } else {
        desktop::fit_to_parent_or_monitor(hwnd);
        desktop::ensure_wallpaper_zorder(hwnd);
    }
    // 守护死了就拉起
    if !common::is_our_process(
        common::read_pid_file("wallpaper.guard.pid"),
        "DynamicWallpaperGuard.exe",
    ) {
        common::launch_exe("DynamicWallpaperGuard.exe");
    }
}

fn create_wallpaper_window() -> bool {
    let r = desktop::get_primary_monitor_rect();
    let w = r.right - r.left;
    let h = r.bottom - r.top;
    let cls = wide("DynamicWallpaper");
    let title = wide("DynamicWallpaper");
    let hinst = unsafe { GetModuleHandleW(None) }.unwrap_or_default();
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
            PCWSTR(cls.as_ptr()),
            PCWSTR(title.as_ptr()),
            WS_POPUP,
            r.left,
            r.top,
            w,
            h,
            HWND(std::ptr::null_mut()),
            HMENU(std::ptr::null_mut()),
            HINSTANCE(hinst.0),
            None,
        )
    };
    let hwnd = match hwnd {
        std::result::Result::Ok(h) => h,
        Err(_) => return false,
    };
    state::WALLPAPER_HWND.set(hwnd);
    state::WIN_W.set(w);
    state::WIN_H.set(h);
    true
}

fn main() {
    if !common::create_single_instance("DynamicWallpaper_SingleInstance") {
        return;
    }
    let _ = consume_quit();
    common::write_pid_file("wallpaper.main.pid");
    common::register_restart();

    // DPI 必须在建窗前设 Per-Monitor V2
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    }

    let mut token: usize = 0;
    let mut gsi = GdiplusStartupInput {
        GdiplusVersion: 1,
        DebugEventCallback: 0,
        SuppressBackgroundThread: FALSE,
        SuppressExternalCodecs: FALSE,
    };
    unsafe {
        let _ = GdiplusStartup(&mut token, &mut gsi, std::ptr::null_mut());
    }

    let cmd = std::env::args().nth(1);
    let path = common::resolve_media_path(cmd.as_deref());
    if path.is_empty() {
        unsafe {
            let _ = GdiplusShutdown(token);
            let _ = MFShutdown();
            CoUninitialize();
        }
        return;
    }
    let is_video = media::is_video_file(&path);
    state::IS_VIDEO.set(is_video);

    if !is_video && !media::load_gif(&path) {
        unsafe {
            let _ = GdiplusShutdown(token);
            let _ = MFShutdown();
            CoUninitialize();
        }
        return;
    }

    let hinst = unsafe { GetModuleHandleW(None) }.unwrap_or_default();
    let host_cls = wide("DynamicWallpaperHost");
    let wp_cls = wide("DynamicWallpaper");

    unsafe {
        let host_wc = WNDCLASSW {
            lpfnWndProc: Some(host_proc),
            hInstance: HINSTANCE(hinst.0),
            lpszClassName: PCWSTR(host_cls.as_ptr()),
            ..Default::default()
        };
        RegisterClassW(&host_wc);

        let mut wc = WNDCLASSW {
            lpfnWndProc: Some(wnd_proc),
            hInstance: HINSTANCE(hinst.0),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            lpszClassName: PCWSTR(wp_cls.as_ptr()),
            ..Default::default()
        };
        RegisterClassW(&wc);

        state::TASKBAR_CREATED.set(RegisterWindowMessageW(w!("TaskbarCreated")));

        let host = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            PCWSTR(host_cls.as_ptr()),
            PCWSTR(wide("").as_ptr()),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            HMENU(std::ptr::null_mut()),
            HINSTANCE(hinst.0),
            None,
        )
        .unwrap_or_default();
        state::HOST_HWND.set(host);

        if host.0.is_null() || !create_wallpaper_window() {
            let _ = GdiplusShutdown(token);
            let _ = MFShutdown();
            CoUninitialize();
            return;
        }

        let hwnd = state::WALLPAPER_HWND.get();
        desktop::embed_or_fallback(hwnd);

        if is_video && !d3dplayer::init(hwnd, &path) {
            d3dplayer::shutdown();
            let _ = GdiplusShutdown(token);
            let _ = MFShutdown();
            CoUninitialize();
            return;
        }

        common::write_marker("wallpaper.ok");
        if !common::is_our_process(
            common::read_pid_file("wallpaper.guard.pid"),
            "DynamicWallpaperGuard.exe",
        ) {
            common::launch_exe("DynamicWallpaperGuard.exe");
        }

        let mut first_delay: u32 = 33;
        if is_video {
            first_delay = 16;
        } else if state::FRAME_COUNT.get() > 0 {
            first_delay = *state::DELAYS.borrow().get(0).unwrap_or(&100);
            if first_delay == 0 {
                first_delay = 100;
            }
        }
        SetTimer(host, TIMER_FRAME, first_delay, None);
        SetTimer(host, TIMER_WATCHDOG, WATCHDOG_MS, None);

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        let _ = KillTimer(host, TIMER_FRAME);
        let _ = KillTimer(host, TIMER_WATCHDOG);
        let hwnd2 = state::WALLPAPER_HWND.get();
        if !hwnd2.0.is_null() {
            let _ = DestroyWindow(hwnd2);
        }
        d3dplayer::shutdown();
        render::release_backbuffer();
        let img = state::IMG.get();
        if !img.is_null() {
            let _ = GdipDisposeImage(img);
            state::IMG.set(std::ptr::null_mut());
        }
        let _ = GdiplusShutdown(token);
        let _ = MFShutdown();
        CoUninitialize();
    }
}

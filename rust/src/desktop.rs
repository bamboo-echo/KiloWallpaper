// desktop.rs — 桌面嵌入层，对齐 cpp/desktop.cpp
//
// Win11 24H2+/25H2 raised desktop：
//   Progman(WS_EX_NOREDIRECTIONBITMAP)
//     ├─ SHELLDLL_DefView(WS_EX_LAYERED, 图标层)
//     └─ WorkerW(全屏, 系统壁纸层, z 在 DefView 之下)
// 主路径：壁纸窗口 SetParent 到 Progman + WS_EX_LAYERED，插到 DefView 之后、
// 系统 WorkerW 之前（双向 z 锚定）。对图标层零修改。

use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::common;
use crate::state::{PARENT, WIN_H, WIN_W};

fn class_of(h: HWND) -> String {
    let mut buf = [0u16; 64];
    let n = unsafe { GetClassNameW(h, &mut buf) };
    if n <= 0 {
        return String::new();
    }
    String::from_utf16_lossy(&buf[..n as usize])
}

pub fn get_primary_monitor_rect() -> RECT {
    unsafe {
        let mon = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(mon, &mut mi).as_bool() {
            return mi.rcMonitor;
        }
        RECT {
            left: 0,
            top: 0,
            right: GetSystemMetrics(SM_CXSCREEN),
            bottom: GetSystemMetrics(SM_CYSCREEN),
        }
    }
}

pub fn fit_to_parent_or_monitor(hwnd: HWND) {
    unsafe {
        let mut x = 0;
        let mut y = 0;
        let mut w = 0;
        let mut h = 0;
        let p = GetParent(hwnd).unwrap_or_default();
        if !p.0.is_null() {
            let mut pr = RECT::default();
            if GetClientRect(p, &mut pr).is_ok() {
                w = pr.right - pr.left;
                h = pr.bottom - pr.top;
            }
        } else {
            let r = get_primary_monitor_rect();
            x = r.left;
            y = r.top;
            w = r.right - r.left;
            h = r.bottom - r.top;
        }
        if w <= 0 || h <= 0 {
            return;
        }
        if WIN_W.get() == w && WIN_H.get() == h {
            return;
        }
        let _ = SetWindowPos(hwnd, HWND(std::ptr::null_mut()), x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
        WIN_W.set(w);
        WIN_H.set(h);
    }
}

pub fn find_progman() -> Option<HWND> {
    unsafe {
        let h = FindWindowW(w!("Progman"), None).unwrap_or_default();
        if !h.0.is_null() {
            return Some(h);
        }
        // 部分 25H2 上 FindWindow 返回 0，用 EnumWindows 兜底
        let mut out: Option<HWND> = None;
        unsafe extern "system" fn cb(h: HWND, lp: LPARAM) -> BOOL {
            let target = &mut *(lp.0 as *mut Option<HWND>);
            let mut buf = [0u16; 64];
            let n = GetClassNameW(h, &mut buf);
            if n > 0 && String::from_utf16_lossy(&buf[..n as usize]) == "Progman" {
                *target = Some(h);
                return BOOL(0);
            }
            BOOL(1)
        }
        let mut target: Option<HWND> = None;
        let _ = EnumWindows(Some(cb), LPARAM(&mut target as *mut _ as isize));
        target
    }
}

fn find_wallpaper_worker(progman: HWND) -> Option<HWND> {
    unsafe {
        let m = get_primary_monitor_rect();
        let mut w = FindWindowExW(progman, None, w!("WorkerW"), None).unwrap_or_default();
        while !w.0.is_null() {
            let mut r = RECT::default();
            if GetWindowRect(w, &mut r).is_ok()
                && (r.right - r.left) >= (m.right - m.left) * 9 / 10
                && (r.bottom - r.top) >= (m.bottom - m.top) * 9 / 10
            {
                return Some(w);
            }
            w = FindWindowExW(progman, w, w!("WorkerW"), None).unwrap_or_default();
        }
        None
    }
}

/// 双向 z 锚定：插到 DefView 之后、系统 WorkerW 之前。
pub fn ensure_wallpaper_zorder(hwnd: HWND) {
    unsafe {
        let parent = GetParent(hwnd).unwrap_or_default();
        if parent.0.is_null() {
            let _ = SetWindowPos(
                hwnd,
                HWND_BOTTOM,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
            return;
        }
        let pcls = class_of(parent);
        if pcls == "Progman" {
            let defview = FindWindowExW(parent, None, w!("SHELLDLL_DefView"), None).unwrap_or_default();
            if !defview.0.is_null() {
                let _ = SetWindowPos(
                    hwnd,
                    defview,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );
            }
            let worker = find_wallpaper_worker(parent);
            if let Some(w) = worker {
                if w != hwnd {
                    let _ = SetWindowPos(
                        w,
                        hwnd,
                        0,
                        0,
                        0,
                        0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                    );
                }
            } else {
                // 结构退化：重发 0x052C 让系统重建 WorkerW（5 秒限频由看门狗频率兜底）
                let mut _res: usize = 0;
                let _ = SendMessageTimeoutW(
                    parent,
                    0x052C,
                    WPARAM(0),
                    LPARAM(0),
                    SMTO_NORMAL,
                    1000,
                    Some(&mut _res as *mut usize as *mut usize),
                );
            }
        } else {
            let _ = SetWindowPos(
                hwnd,
                HWND_BOTTOM,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }
}

pub fn embed_or_fallback(hwnd: HWND) -> bool {
    unsafe {
        let progman = find_progman();
        // 嵌入前发 0x052C 唤醒 raised desktop
        if let Some(pm) = progman {
            let mut _res: usize = 0;
            let _ = SendMessageTimeoutW(
                pm,
                0x052C,
                WPARAM(0),
                LPARAM(0),
                SMTO_NORMAL,
                1000,
                Some(&mut _res as *mut usize as *mut usize),
            );
            std::thread::sleep(std::time::Duration::from_millis(120));
        }

        if let Some(pm) = progman {
            let defview = FindWindowExW(pm, None, w!("SHELLDLL_DefView"), None).unwrap_or_default();
            if !defview.0.is_null() {
                // 子窗口化 + LAYERED（DComp 呈现前提）
                let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
                let style = (style & !((WS_POPUP.0 | WS_CAPTION.0 | WS_THICKFRAME.0 | WS_SYSMENU.0) as isize))
                    | (WS_CHILD.0 | WS_VISIBLE.0) as isize;
                SetWindowLongPtrW(hwnd, GWL_STYLE, style);
                let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                let ex = (ex | (WS_EX_LAYERED.0 | WS_EX_NOACTIVATE.0) as isize) & !(WS_EX_TOPMOST.0 as isize);
                SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
                let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);

                if SetParent(hwnd, pm).is_ok() {
                    PARENT.set(pm);
                    let mut pr = RECT::default();
                    let _ = GetClientRect(pm, &mut pr);
                    let mut w = pr.right - pr.left;
                    let mut h = pr.bottom - pr.top;
                    if w <= 0 || h <= 0 {
                        let mr = get_primary_monitor_rect();
                        w = mr.right - mr.left;
                        h = mr.bottom - mr.top;
                    }
                    WIN_W.set(w);
                    WIN_H.set(h);
                    let _ = SetWindowPos(
                        hwnd,
                        HWND(std::ptr::null_mut()),
                        0,
                        0,
                        w,
                        h,
                        SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
                    );
                    ensure_wallpaper_zorder(hwnd);
                    common::log("embed", "progman-layered anchor");
                    return true;
                }
            }
        }

        // 兜底：顶层窗口压底（保底不黑屏，已知会盖图标）
        common::log("embed", "toplevel fallback");
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        let style = (style & !(WS_CHILD.0 as isize)) | (WS_POPUP.0 | WS_VISIBLE.0) as isize;
        SetWindowLongPtrW(hwnd, GWL_STYLE, style);
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let ex = (ex | (WS_EX_NOACTIVATE.0 | WS_EX_TOOLWINDOW.0) as isize) & !(WS_EX_TOPMOST.0 as isize);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
        let _ = SetParent(hwnd, HWND::default());
        let r = get_primary_monitor_rect();
        let w = r.right - r.left;
        let h = r.bottom - r.top;
        let _ = SetWindowPos(
            hwnd,
            HWND_BOTTOM,
            r.left,
            r.top,
            w,
            h,
            SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED,
        );
        PARENT.set(HWND::default());
        WIN_W.set(w);
        WIN_H.set(h);
        true
    }
}

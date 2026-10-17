// render.rs — GIF 绘制与双缓冲后备缓冲管理，对齐 cpp/render.cpp
//
// 用 GDI 内存 DC 双缓冲 + GDI+ HighQualityBicubic 做 cover 缩放，避免整屏闪烁。

use std::cell::Cell;

use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Graphics::GdiPlus::*;

use crate::media::FRAME_DIMENSION_TIME;
use crate::state::{CUR_FRAME, IMG};

thread_local! {
    static MEM_DC: Cell<HDC> = Cell::new(HDC(std::ptr::null_mut()));
    static MEM_BMP: Cell<HBITMAP> = Cell::new(HBITMAP(std::ptr::null_mut()));
    static OLD_BMP: Cell<HGDIOBJ> = Cell::new(HGDIOBJ(std::ptr::null_mut()));
    static BMP_W: Cell<i32> = Cell::new(0);
    static BMP_H: Cell<i32> = Cell::new(0);
}

pub fn get_mem_dc() -> HDC {
    MEM_DC.with(|c| c.get())
}

pub fn release_backbuffer() {
    MEM_DC.with(|dc_c| {
        MEM_BMP.with(|bmp_c| {
            OLD_BMP.with(|old_c| {
                let dc = dc_c.get();
                if dc.0.is_null() {
                    return;
                }
                unsafe {
                    let _ = SelectObject(dc, old_c.get());
                    let bmp = bmp_c.get();
                    if !bmp.0.is_null() {
                        let _ = DeleteObject(bmp);
                    }
                    let _ = DeleteDC(dc);
                }
                dc_c.set(HDC(std::ptr::null_mut()));
                bmp_c.set(HBITMAP(std::ptr::null_mut()));
                old_c.set(HGDIOBJ(std::ptr::null_mut()));
                BMP_W.with(|w| w.set(0));
                BMP_H.with(|h| h.set(0));
            })
        })
    })
}

pub fn ensure_backbuffer(dc: HDC, w: i32, h: i32) {
    let same = MEM_DC.with(|c| !c.get().0.is_null())
        && BMP_W.with(|c| c.get() == w)
        && BMP_H.with(|c| c.get() == h);
    if same {
        return;
    }
    release_backbuffer();
    if w <= 0 || h <= 0 {
        return;
    }
    unsafe {
        let mem = CreateCompatibleDC(dc);
        if mem.0.is_null() {
            return;
        }
        let bmp = CreateCompatibleBitmap(dc, w, h);
        if bmp.0.is_null() {
            let _ = DeleteDC(mem);
            return;
        }
        let old = SelectObject(mem, bmp);
        MEM_DC.with(|c| c.set(mem));
        MEM_BMP.with(|c| c.set(bmp));
        OLD_BMP.with(|c| c.set(old));
        BMP_W.with(|c| c.set(w));
        BMP_H.with(|c| c.set(h));
    }
}

pub fn draw_gif_frame(dc: HDC, dst_w: i32, dst_h: i32) {
    unsafe {
        let img = IMG.get();
        if img.is_null() {
            return;
        }
        let _ = GdipImageSelectActiveFrame(img, &FRAME_DIMENSION_TIME, CUR_FRAME.get());

        let mut iw: u32 = 0;
        let mut ih: u32 = 0;
        let _ = GdipGetImageWidth(img, &mut iw);
        let _ = GdipGetImageHeight(img, &mut ih);
        if iw == 0 || ih == 0 {
            return;
        }

        // cover：放大到铺满，宽高比不同时裁掉溢出
        let sw = dst_w as f64 / iw as f64;
        let sh = dst_h as f64 / ih as f64;
        let scale = sw.max(sh);
        let w = (iw as f64 * scale) as i32;
        let h = (ih as f64 * scale) as i32;
        let x = (dst_w - w) / 2;
        let y = (dst_h - h) / 2;

        let mut g: *mut GpGraphics = std::ptr::null_mut();
        if GdipCreateFromHDC(dc, &mut g) != Status(0) || g.is_null() {
            return;
        }
        let _ = GdipSetInterpolationMode(g, InterpolationMode(7)); // HighQualityBicubic
        let _ = GdipDrawImageRectI(g, img, x, y, w, h);
        let _ = GdipDeleteGraphics(g);
    }
}

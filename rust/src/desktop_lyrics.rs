//! 桌面歌词：Win32 分层窗口 + GDI 绘制。
//!
//! 不引 Flutter 多窗口插件——那要再跑一个引擎（60~100MB），而这里只需要一行字。
//!
//! 窗口特性：
//! - `WS_EX_LAYERED` + `LWA_ALPHA`：整体半透明，黑底压在白字下，任何壁纸都读得清
//! - `WS_EX_TOPMOST`：浮在其它窗口上
//! - `WS_EX_TOOLWINDOW`：不进 Alt+Tab 与任务栏
//! - `WS_EX_NOACTIVATE`：点击不抢焦点，不影响播放
//! - `WM_NCHITTEST` 返回 `HTCAPTION`：按住任意位置就能拖
//!
//! 窗口跑在独立线程的消息循环里；歌词放在全局状态中，改完 `PostMessage`
//! 让窗口线程重绘。

use std::sync::{Mutex, OnceLock};

struct LyricState {
    text: String,
    visible: bool,
}

static STATE: OnceLock<Mutex<LyricState>> = OnceLock::new();
/// 窗口句柄（`isize` 形式，避免把 HWND 类型泄到非 Windows 分支）
static HWND_SLOT: OnceLock<Mutex<Option<isize>>> = OnceLock::new();

fn state() -> &'static Mutex<LyricState> {
    STATE.get_or_init(|| {
        Mutex::new(LyricState {
            text: String::new(),
            visible: false,
        })
    })
}

fn slot() -> &'static Mutex<Option<isize>> {
    HWND_SLOT.get_or_init(|| Mutex::new(None))
}

fn text_now() -> String {
    state()
        .lock()
        .map(|guard| guard.text.clone())
        .unwrap_or_default()
}

/// 打开桌面歌词窗口；已创建过就只显示
pub fn show() -> anyhow::Result<()> {
    let existing = *slot().lock().unwrap_or_else(|p| p.into_inner());
    let hwnd = match existing {
        Some(hwnd) => hwnd,
        None => match imp::create_window() {
            Ok(created) => {
                *slot().lock().unwrap_or_else(|p| p.into_inner()) = Some(created);
                created
            }
            Err(error) => {
                return Err(error);
            }
        },
    };
    imp::show(hwnd);
    imp::repaint(hwnd);
    if let Ok(mut guard) = state().lock() {
        guard.visible = true;
    }
    Ok(())
}

/// 隐藏窗口；窗口与线程保留，下次打开不用重建
pub fn hide() -> anyhow::Result<()> {
    let slot_value = *slot().lock().unwrap_or_else(|p| p.into_inner());
    imp::hide(slot_value);
    if let Ok(mut guard) = state().lock() {
        guard.visible = false;
    }
    Ok(())
}

/// 更新显示的一行歌词；没打开窗口时只记文本，打开后立即生效
pub fn set_line(line: &str) -> anyhow::Result<()> {
    let changed = {
        let mut guard = state().lock().unwrap_or_else(|p| p.into_inner());
        if guard.text == line {
            false
        } else {
            guard.text = line.to_string();
            true
        }
    };
    if changed {
        if let Some(hwnd) = *slot().lock().unwrap_or_else(|p| p.into_inner()) {
            imp::repaint(hwnd);
        }
    }
    Ok(())
}

#[cfg(windows)]
mod imp {
    use anyhow::{anyhow, Result};
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
    use windows::Win32::Graphics::Gdi::{
        BeginPaint, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateFontW,
        CreateSolidBrush, DeleteDC, DeleteObject, DrawTextW, EndPaint, FillRect, InvalidateRect,
        SelectObject, SetBkMode, SetTextColor, UpdateWindow, DT_CENTER, DT_END_ELLIPSIS,
        DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER, HBRUSH, HFONT, HGDIOBJ, PAINTSTRUCT, SRCCOPY,
        TRANSPARENT,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::HiDpi::GetDpiForWindow;
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, FindWindowW, GetClientRect, GetMessageW,
        GetSystemMetrics, RegisterClassW, SetLayeredWindowAttributes, SetWindowPos, ShowWindow,
        TranslateMessage, CS_HREDRAW, CS_VREDRAW, HTCAPTION, HWND_TOPMOST, LWA_ALPHA, MSG,
        SM_CXSCREEN, SM_CYSCREEN, SWP_NOACTIVATE, SWP_NOSIZE, SW_HIDE, SW_SHOWNA, WM_APP, WM_CLOSE,
        WM_ERASEBKGND, WM_NCHITTEST, WM_PAINT, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
        WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
    };

    const WM_LYRIC: u32 = WM_APP + 1;
    const CLASS_NAME: &str = "LampPlayerDesktopLyric";

    /// 96 DPI 下的窗口尺寸
    const WIDTH_96: i32 = 760;
    const HEIGHT_96: i32 = 54;
    const FONT_96: i32 = 27;
    /// 整体不透明度：黑底压白字，太透会看不清，太实挡壁纸
    const ALPHA: u8 = 200;

    pub(super) fn create_window() -> Result<isize> {
        let (tx, rx) = std::sync::mpsc::channel::<Result<isize, String>>();
        std::thread::Builder::new()
            .name("desktop-lyric".to_string())
            .spawn(move || run(tx))
            .map_err(|error| anyhow!("创建桌面歌词线程失败: {error}"))?;
        match rx.recv() {
            Ok(Ok(hwnd)) => Ok(hwnd),
            Ok(Err(message)) => Err(anyhow!("{message}")),
            Err(_) => Err(anyhow!("桌面歌词线程提前退出")),
        }
    }

    pub(super) fn show(hwnd: isize) {
        unsafe {
            let _ = ShowWindow(HWND(hwnd), SW_SHOWNA);
            let _ = UpdateWindow(HWND(hwnd));
            let _ = SetWindowPos(
                HWND(hwnd),
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOACTIVATE | SWP_NOSIZE,
            );
        }
    }

    /// 隐藏窗口；句柄丢失时按类名兜底，避免半成品窗口关不掉
    pub(super) fn hide(hwnd: Option<isize>) {
        unsafe {
            let target = match hwnd {
                Some(raw) => HWND(raw),
                None => {
                    let class = wide(CLASS_NAME);
                    FindWindowW(PCWSTR(class.as_ptr()), PCWSTR::null())
                }
            };
            if target.0 != 0 {
                let _ = ShowWindow(target, SW_HIDE);
            }
        }
    }

    pub(super) fn repaint(hwnd: isize) {
        unsafe {
            let _ = InvalidateRect(HWND(hwnd), None, false);
        }
    }

    fn run(ready: std::sync::mpsc::Sender<Result<isize, String>>) {
        unsafe {
            let instance = match GetModuleHandleW(PCWSTR::null()) {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = ready.send(Err(format!("取模块句柄失败: {error}")));
                    return;
                }
            };
            let class = wide(CLASS_NAME);
            let class_ptr = PCWSTR(class.as_ptr());
            let wc = WNDCLASSW {
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(wnd_proc),
                hInstance: HINSTANCE(instance.0),
                lpszClassName: class_ptr,
                ..Default::default()
            };
            if RegisterClassW(&wc) == 0 {
                let _ = ready.send(Err("注册窗口类失败".to_string()));
                return;
            }

            let title = wide("Lamp Player 桌面歌词");
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                class_ptr,
                PCWSTR(title.as_ptr()),
                WS_POPUP,
                0,
                0,
                WIDTH_96,
                HEIGHT_96,
                None,
                None,
                HINSTANCE(instance.0),
                None,
            );
            if hwnd.0 == 0 {
                let _ = ready.send(Err("创建窗口失败".to_string()));
                return;
            }

            // 透明度失败不致命：窗口仍然能用，只是不透明
            // 透明度失败不致命：窗口仍然能用，只是不透明
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), ALPHA, LWA_ALPHA);

            // 首次落在屏幕下方居中偏上；之后用户拖到哪算哪
            let screen_w = GetSystemMetrics(SM_CXSCREEN);
            let screen_h = GetSystemMetrics(SM_CYSCREEN);
            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                (screen_w - WIDTH_96) / 2,
                screen_h - 220,
                WIDTH_96,
                HEIGHT_96,
                SWP_NOACTIVATE,
            );
            let _ = ShowWindow(hwnd, SW_SHOWNA);
            let _ = UpdateWindow(hwnd);
            let _ = ready.send(Ok(hwnd.0));

            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match message {
            WM_PAINT => {
                paint(hwnd);
                LRESULT(0)
            }
            // 自己铺底色，让系统再擦一次会闪
            WM_ERASEBKGND => LRESULT(1),
            WM_LYRIC => {
                let _ = unsafe { InvalidateRect(hwnd, None, false) };
                LRESULT(0)
            }
            // 整窗当标题栏：交给系统做拖动，省掉手算偏移
            WM_NCHITTEST => LRESULT(HTCAPTION as isize),
            WM_CLOSE => {
                let _ = unsafe { ShowWindow(hwnd, SW_HIDE) };
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
        }
    }

    unsafe fn paint(hwnd: HWND) {
        let mut ps = PAINTSTRUCT::default();
        let hdc = unsafe { BeginPaint(hwnd, &mut ps) };
        let mut rect = RECT::default();
        unsafe {
            let _ = GetClientRect(hwnd, &mut rect);
        }
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        if width <= 0 || height <= 0 {
            unsafe {
                let _ = EndPaint(hwnd, &ps);
            }
            return;
        }

        // 双缓冲：直接画到窗口 DC，拖动时会闪
        let mem = unsafe { CreateCompatibleDC(hdc) };
        let bitmap = unsafe { CreateCompatibleBitmap(hdc, width, height) };
        let old_bitmap = unsafe { SelectObject(mem, HGDIOBJ(bitmap.0)) };

        let brush: HBRUSH = unsafe { CreateSolidBrush(COLORREF(0x0018_1818)) };
        unsafe {
            FillRect(mem, &rect, brush);
            let _ = DeleteObject(HGDIOBJ(brush.0));
        }

        let text = super::text_now();
        if !text.is_empty() {
            let dpi = unsafe { GetDpiForWindow(hwnd) }.max(96);
            let scale = dpi as f32 / 96.0;
            let font = unsafe { make_font((FONT_96 as f32 * scale) as i32) };
            let old_font = unsafe { SelectObject(mem, HGDIOBJ(font.0)) };
            unsafe {
                SetBkMode(mem, TRANSPARENT);
                SetTextColor(mem, COLORREF(0x00F5_F5F5));
                let mut text_rect = rect;
                let mut wide_text = wide(&text);
                // DrawTextW 会把结尾的 NUL 当普通字符，长度要减一
                let char_count = wide_text.len() - 1;
                let text_ptr = &mut wide_text[..char_count];
                DrawTextW(
                    mem,
                    text_ptr,
                    &mut text_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX,
                );
                SelectObject(mem, old_font);
                let _ = DeleteObject(HGDIOBJ(font.0));
            }
        }

        unsafe {
            let _ = BitBlt(hdc, 0, 0, width, height, mem, 0, 0, SRCCOPY);
            SelectObject(mem, old_bitmap);
            let _ = DeleteObject(HGDIOBJ(bitmap.0));
            let _ = DeleteDC(mem);
            let _ = EndPaint(hwnd, &ps);
        }
    }

    unsafe fn make_font(size: i32) -> HFONT {
        let face = wide("Microsoft YaHei UI");
        unsafe {
            CreateFontW(
                -size,
                0,
                0,
                0,
                600,
                0,
                0,
                0,
                1,
                0,
                0,
                4,
                0,
                PCWSTR(face.as_ptr()),
            )
        }
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }
}

#[cfg(not(windows))]
mod imp {
    use anyhow::{bail, Result};

    pub(super) fn create_window() -> Result<isize> {
        bail!("当前平台不支持桌面歌词")
    }

    pub(super) fn show(_hwnd: isize) {}

    pub(super) fn hide(_hwnd: Option<isize>) {}

    pub(super) fn repaint(_hwnd: isize) {}
}

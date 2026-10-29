//! 桌面歌词：Win32 分层窗口 + GDI+ 逐像素绘制。
//!
//! 不引 Flutter 多窗口插件——那要再跑一个引擎（60~100MB），而这里只需要一行字。
//!
//! 窗口特性：
//! - `WS_EX_LAYERED` + `UpdateLayeredWindow`：整窗按像素 alpha 合成，没悬停时
//!   只剩字（背景完全透明），悬停时铺一层深灰圆角底并把工具栏露出来
//! - `WS_EX_TOPMOST`：浮在其它窗口上
//! - `WS_EX_TOOLWINDOW`：不进 Alt+Tab 与任务栏
//! - `WS_EX_NOACTIVATE`：点击不抢焦点，不影响播放
//! - 命中测试按上一帧的 alpha 判断：透明像素 `HTTRANSPARENT` 让鼠标穿到下层
//!   窗口，只有落在字或按钮上才算点到歌词（否则一块 760 宽的透明板会挡住
//!   底下所有点击）
//! - 按住非按钮区域 = `WM_NCLBUTTONDOWN(HTCAPTION)`，交给系统拖动
//! - 锁定 = `WS_EX_TRANSPARENT`，整窗鼠标穿透，同时不画背景与按钮
//!
//! 窗口跑在独立线程的消息循环里；歌词与开关放在全局状态中，改完 `PostMessage`
//! 让窗口线程重绘。按钮点击通过 `listen` 注册的回调回流给 Dart。

use std::sync::{Mutex, MutexGuard, OnceLock};

/// 悬停工具栏上的按钮
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub enum Button {
    FontDown,
    FontUp,
    Previous,
    PlayPause,
    Next,
    Lock,
    Close,
}

/// 窗口按钮回流给 Dart 的命令
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub enum Command {
    PlayPause,
    Previous,
    Next,
    Close,
    LockChanged(bool),
    FontSizeChanged(i32),
}

/// 字号范围与步进（96 DPI 下的逻辑像素）
pub const MIN_FONT_SIZE: i32 = 16;
pub const MAX_FONT_SIZE: i32 = 56;
/// 只有 Windows 实现里的按钮会用到；非 Windows 平台（CI 的 clippy）别报死代码
#[cfg_attr(not(windows), allow(dead_code))]
pub const FONT_STEP: i32 = 3;
pub const DEFAULT_FONT_SIZE: i32 = 27;

struct LyricState {
    text: String,
    visible: bool,
    playing: bool,
    font_size: i32,
    locked: bool,
    hovered: bool,
    hovered_button: Option<Button>,
    pressed_button: Option<Button>,
}

/// 上一帧的 alpha 通道：命中测试靠它判断某个像素是不是「实的」
#[cfg(windows)]
struct Frame {
    width: i32,
    height: i32,
    alpha: Vec<u8>,
}

static STATE: OnceLock<Mutex<LyricState>> = OnceLock::new();
/// 窗口句柄（`isize` 形式，避免把 HWND 类型泄到非 Windows 分支）
static HWND_SLOT: OnceLock<Mutex<Option<isize>>> = OnceLock::new();
/// 按钮命令的回调；Dart 侧只注册一次
type Handler = Box<dyn Fn(Command) + Send + Sync>;
static HANDLER: OnceLock<Mutex<Option<Handler>>> = OnceLock::new();
#[cfg(windows)]
static FRAME: OnceLock<Mutex<Option<Frame>>> = OnceLock::new();

fn state() -> MutexGuard<'static, LyricState> {
    STATE
        .get_or_init(|| {
            Mutex::new(LyricState {
                text: String::new(),
                visible: false,
                playing: false,
                font_size: DEFAULT_FONT_SIZE,
                locked: false,
                hovered: false,
                hovered_button: None,
                pressed_button: None,
            })
        })
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn slot() -> MutexGuard<'static, Option<isize>> {
    HWND_SLOT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(windows)]
fn frame() -> MutexGuard<'static, Option<Frame>> {
    FRAME
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 注册按钮命令回调；重复调用以后一次为准
pub fn listen<F>(handler: F)
where
    F: Fn(Command) + Send + Sync + 'static,
{
    *HANDLER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Box::new(handler));
}

#[cfg(windows)]
fn emit(command: Command) {
    let guard = HANDLER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(handler) = guard.as_ref() {
        handler(command);
    }
}

/// 只在 Windows 绘制时取状态；其它平台不编译，免得被判死代码
#[cfg(windows)]
#[allow(clippy::type_complexity)]
fn snapshot() -> (String, bool, i32, bool, bool, Option<Button>) {
    let guard = state();
    (
        guard.text.clone(),
        guard.playing,
        guard.font_size,
        guard.locked,
        guard.hovered,
        guard.hovered_button,
    )
}

/// 让窗口线程按当前字号 / 锁定状态重新排版
fn request_apply() {
    if let Some(hwnd) = *slot() {
        imp::request_apply(hwnd);
    }
}

fn request_repaint() {
    if let Some(hwnd) = *slot() {
        imp::request_repaint(hwnd);
    }
}

/// 打开桌面歌词窗口；已创建过就只显示
pub fn show() -> anyhow::Result<()> {
    let existing = *slot();
    let hwnd = match existing {
        Some(hwnd) => hwnd,
        None => match imp::create_window() {
            Ok(created) => {
                *slot() = Some(created);
                created
            }
            Err(error) => {
                return Err(error);
            }
        },
    };
    imp::show(hwnd);
    {
        let mut guard = state();
        guard.visible = true;
    }
    imp::request_apply(hwnd);
    Ok(())
}

/// 隐藏窗口；窗口与线程保留，下次打开不用重建
pub fn hide() -> anyhow::Result<()> {
    let slot_value = *slot();
    imp::hide(slot_value);
    {
        let mut guard = state();
        guard.visible = false;
        guard.hovered = false;
        guard.hovered_button = None;
    }
    Ok(())
}

/// 更新显示的一行歌词；没打开窗口时只记文本，打开后立即生效
pub fn set_line(line: &str) -> anyhow::Result<()> {
    let changed = {
        let mut guard = state();
        if guard.text == line {
            false
        } else {
            guard.text = line.to_string();
            true
        }
    };
    if changed {
        request_repaint();
    }
    Ok(())
}

/// 同步播放状态：工具栏的播放 / 暂停字形跟着变
pub fn set_playing(playing: bool) {
    let changed = {
        let mut guard = state();
        if guard.playing == playing {
            false
        } else {
            guard.playing = playing;
            true
        }
    };
    if changed {
        request_repaint();
    }
}

/// 设置字号（会夹到 `MIN_FONT_SIZE..=MAX_FONT_SIZE`）
pub fn set_font_size(size: i32) {
    let clamped = size.clamp(MIN_FONT_SIZE, MAX_FONT_SIZE);
    let changed = {
        let mut guard = state();
        if guard.font_size == clamped {
            false
        } else {
            guard.font_size = clamped;
            true
        }
    };
    if changed {
        request_apply();
    }
}

/// 锁定 = 整窗鼠标穿透；解锁恢复拖动与按钮
pub fn set_locked(locked: bool) {
    let changed = {
        let mut guard = state();
        if guard.locked == locked {
            false
        } else {
            guard.locked = locked;
            if locked {
                guard.hovered = false;
                guard.hovered_button = None;
                guard.pressed_button = None;
            }
            true
        }
    };
    if changed {
        request_apply();
    }
}

/// 当前字号
pub fn font_size() -> i32 {
    state().font_size
}

/// 当前是否锁定（鼠标穿透）
pub fn locked() -> bool {
    state().locked
}

#[cfg(windows)]
mod imp {
    use anyhow::{anyhow, Result};
    use std::ffi::c_void;
    use std::ptr::null_mut;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{
        BOOL, COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
    };
    use windows::Win32::Graphics::Gdi::{
        CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC,
        ScreenToClient, SelectObject, ValidateRect, AC_SRC_ALPHA, AC_SRC_OVER, BITMAPINFO,
        BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION, DIB_RGB_COLORS, HBITMAP, HGDIOBJ,
    };
    use windows::Win32::Graphics::GdiPlus::{
        FillModeAlternate, FlushIntentionSync, FontStyleBold, GdipAddPathArc, GdipClosePathFigure,
        GdipCreateBitmapFromScan0, GdipCreateFont, GdipCreateFontFamilyFromName, GdipCreatePath,
        GdipCreateSolidFill, GdipCreateStringFormat, GdipDeleteBrush, GdipDeleteFont,
        GdipDeleteFontFamily, GdipDeleteGraphics, GdipDeletePath, GdipDeleteStringFormat,
        GdipDisposeImage, GdipDrawString, GdipFillPath, GdipFlush, GdipGetImageGraphicsContext,
        GdipGraphicsClear, GdipSetSmoothingMode, GdipSetStringFormatAlign,
        GdipSetStringFormatFlags, GdipSetStringFormatLineAlign, GdipSetStringFormatTrimming,
        GdipSetTextRenderingHint, GdiplusShutdown, GdiplusStartup, GdiplusStartupInput, GpBitmap,
        GpBrush, GpFont, GpFontFamily, GpGraphics, GpImage, GpPath, GpSolidFill, GpStringFormat,
        RectF, SmoothingModeAntiAlias, StringAlignmentCenter, StringFormatFlagsNoWrap,
        StringTrimmingEllipsisCharacter, TextRenderingHintAntiAliasGridFit, UnitPixel,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Controls::WM_MOUSELEAVE;
    use windows::Win32::UI::HiDpi::{GetDpiForSystem, GetDpiForWindow};
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        ReleaseCapture, TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, FindWindowW, GetMessageW,
        GetSystemMetrics, GetWindowLongPtrW, GetWindowRect, LoadCursorW, PostMessageW,
        RegisterClassW, SendMessageW, SetCursor, SetWindowLongPtrW, SetWindowPos, ShowWindow,
        TranslateMessage, UpdateLayeredWindow, CS_HREDRAW, CS_VREDRAW, GWL_EXSTYLE, HTCAPTION,
        HTCLIENT, HTTRANSPARENT, HWND_TOPMOST, IDC_ARROW, MSG, SM_CXSCREEN, SM_CYSCREEN,
        SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SW_HIDE, SW_SHOWNA,
        ULW_ALPHA, WM_APP, WM_CLOSE, WM_DPICHANGED, WM_ERASEBKGND, WM_LBUTTONDOWN, WM_LBUTTONUP,
        WM_MOUSEMOVE, WM_NCHITTEST, WM_NCLBUTTONDOWN, WM_PAINT, WM_SETCURSOR, WNDCLASSW,
        WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT,
        WS_POPUP,
    };

    use super::{frame, snapshot, Button, Command, Frame, FONT_STEP, MAX_FONT_SIZE, MIN_FONT_SIZE};

    const WM_LYRIC: u32 = WM_APP + 1;
    const WM_APPLY: u32 = WM_APP + 2;
    const CLASS_NAME: &str = "LampPlayerDesktopLyric";

    /// 96 DPI 下的窗口宽度：够放一行长歌词，又不至于横跨半个屏幕
    const WIDTH_96: f32 = 760.0;
    /// 悬停背景：深灰、约 70% 不透明
    const BACKDROP: u32 = argb(180, 30, 30, 32);
    /// GDI+ 的 32 位预乘 ARGB 像素格式（`gdipluspixelformats.h` 的 PixelFormat32bppPARGB，
    /// windows crate 只导出了几个类别位，没有导出这个组合值）
    const PIXEL_FORMAT_32BPP_PARGB: i32 = 0x000E_200B;

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

    pub(super) fn request_repaint(hwnd: isize) {
        unsafe {
            let _ = PostMessageW(HWND(hwnd), WM_LYRIC, WPARAM(0), LPARAM(0));
        }
    }

    pub(super) fn request_apply(hwnd: isize) {
        unsafe {
            let _ = PostMessageW(HWND(hwnd), WM_APPLY, WPARAM(0), LPARAM(0));
        }
    }

    fn run(ready: std::sync::mpsc::Sender<Result<isize, String>>) {
        let mut token: usize = 0;
        let input = GdiplusStartupInput {
            GdiplusVersion: 1,
            DebugEventCallback: 0,
            SuppressBackgroundThread: BOOL(0),
            SuppressExternalCodecs: BOOL(0),
        };
        let status = unsafe { GdiplusStartup(&mut token, &input, null_mut()) };
        if status.0 != 0 {
            let _ = ready.send(Err(format!("初始化 GDI+ 失败: {}", status.0)));
            return;
        }

        unsafe {
            let instance = match GetModuleHandleW(PCWSTR::null()) {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = ready.send(Err(format!("取模块句柄失败: {error}")));
                    GdiplusShutdown(token);
                    return;
                }
            };
            let class = wide(CLASS_NAME);
            let class_ptr = PCWSTR(class.as_ptr());
            // 类里必须带光标：留空的话本窗口不会自己设光标，会一直沿用上一个窗口
            // 的光标——刚打开歌词时主窗口还在忙，系统给的是「启动中」转圈光标，
            // 移到歌词上就会一直转圈
            let cursor = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
            let wc = WNDCLASSW {
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(wnd_proc),
                hInstance: HINSTANCE(instance.0),
                hCursor: cursor,
                lpszClassName: class_ptr,
                ..Default::default()
            };
            if RegisterClassW(&wc) == 0 {
                let _ = ready.send(Err("注册窗口类失败".to_string()));
                GdiplusShutdown(token);
                return;
            }

            let dpi = GetDpiForSystem();
            let scale = if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 };
            let layout = Layout::new(scale, super::DEFAULT_FONT_SIZE);
            let title = wide("Lamp Player 桌面歌词");
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                class_ptr,
                PCWSTR(title.as_ptr()),
                WS_POPUP,
                0,
                0,
                layout.width,
                layout.height,
                None,
                None,
                HINSTANCE(instance.0),
                None,
            );
            if hwnd.0 == 0 {
                let _ = ready.send(Err("创建窗口失败".to_string()));
                GdiplusShutdown(token);
                return;
            }

            // 首次落在屏幕下方居中偏上；之后用户拖到哪算哪
            let screen_w = GetSystemMetrics(SM_CXSCREEN);
            let screen_h = GetSystemMetrics(SM_CYSCREEN);
            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                (screen_w - layout.width) / 2,
                screen_h - 260,
                layout.width,
                layout.height,
                SWP_NOACTIVATE,
            );
            let _ = ShowWindow(hwnd, SW_SHOWNA);
            apply(hwnd);
            let _ = ready.send(Ok(hwnd.0));

            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        unsafe { GdiplusShutdown(token) };
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match message {
            WM_PAINT => {
                unsafe {
                    let _ = ValidateRect(hwnd, None);
                }
                paint(hwnd);
                LRESULT(0)
            }
            // 自己铺底色，让系统再擦一次会闪
            WM_ERASEBKGND => LRESULT(1),
            WM_LYRIC => {
                paint(hwnd);
                LRESULT(0)
            }
            WM_APPLY => {
                apply(hwnd);
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                handle_mouse_move(hwnd, lparam);
                LRESULT(0)
            }
            WM_MOUSELEAVE => {
                {
                    let mut guard = super::state();
                    guard.hovered = false;
                    guard.hovered_button = None;
                    guard.pressed_button = None;
                }
                paint(hwnd);
                LRESULT(0)
            }
            // 换到另一块不同缩放的屏幕：按新 DPI 重排
            WM_DPICHANGED => {
                apply(hwnd);
                LRESULT(0)
            }
            // 光标固定用箭头：类光标已经设了，这里再兜一层，避免命中测试返回
            // 非 HTCLIENT 时 DefWindowProc 不设光标、把上一个窗口的「启动中」转圈留下
            WM_SETCURSOR => {
                if let Ok(cursor) = unsafe { LoadCursorW(None, IDC_ARROW) } {
                    unsafe {
                        SetCursor(cursor);
                    }
                }
                LRESULT(1)
            }
            WM_LBUTTONDOWN => {
                handle_button_down(hwnd, lparam);
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                handle_button_up(hwnd, lparam);
                LRESULT(0)
            }
            // 锁定后整窗穿透；没悬停时只有落在实心像素（字 / 按钮）上才算点到
            WM_NCHITTEST => {
                let locked = super::state().locked;
                if locked {
                    return LRESULT(HTTRANSPARENT as isize);
                }
                if super::state().hovered {
                    return LRESULT(HTCLIENT as isize);
                }
                let mut point = POINT {
                    x: loword(lparam),
                    y: hiword(lparam),
                };
                unsafe {
                    let _ = ScreenToClient(hwnd, &mut point);
                }
                if alpha_near(point.x, point.y) > 8 {
                    LRESULT(HTCLIENT as isize)
                } else {
                    LRESULT(HTTRANSPARENT as isize)
                }
            }
            WM_CLOSE => {
                unsafe {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                }
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
        }
    }

    fn handle_mouse_move(hwnd: HWND, lparam: LPARAM) {
        let dpi = unsafe { GetDpiForWindow(hwnd) };
        let scale = if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 };
        let layout = {
            let guard = super::state();
            Layout::new(scale, guard.font_size)
        };
        let x = loword(lparam) as f32;
        let y = hiword(lparam) as f32;
        let button = hit_button(&layout, x, y);

        let changed = {
            let mut guard = super::state();
            if guard.locked {
                false
            } else {
                let changed = !guard.hovered || guard.hovered_button != button;
                guard.hovered = true;
                guard.hovered_button = button;
                changed
            }
        };

        // 不登记 TME_LEAVE 就永远收不到 WM_MOUSELEAVE，背景会一直挂着
        let mut track = TRACKMOUSEEVENT {
            cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
            dwFlags: TME_LEAVE,
            hwndTrack: hwnd,
            dwHoverTime: 0,
        };
        unsafe {
            let _ = TrackMouseEvent(&mut track);
        }

        if changed {
            paint(hwnd);
        }
    }

    fn handle_button_down(hwnd: HWND, lparam: LPARAM) {
        let locked = super::state().locked;
        if locked {
            return;
        }
        let dpi = unsafe { GetDpiForWindow(hwnd) };
        let scale = if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 };
        let layout = {
            let guard = super::state();
            Layout::new(scale, guard.font_size)
        };
        let x = loword(lparam) as f32;
        let y = hiword(lparam) as f32;
        match hit_button(&layout, x, y) {
            Some(button) => {
                super::state().pressed_button = Some(button);
            }
            // 非按钮区域：整窗当标题栏，交给系统拖动
            None => unsafe {
                let _ = ReleaseCapture();
                SendMessageW(hwnd, WM_NCLBUTTONDOWN, WPARAM(HTCAPTION as usize), lparam);
            },
        }
    }

    fn handle_button_up(hwnd: HWND, lparam: LPARAM) {
        let pressed = super::state().pressed_button.take();
        let Some(pressed) = pressed else {
            return;
        };
        let dpi = unsafe { GetDpiForWindow(hwnd) };
        let scale = if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 };
        let layout = {
            let guard = super::state();
            Layout::new(scale, guard.font_size)
        };
        let x = loword(lparam) as f32;
        let y = hiword(lparam) as f32;
        if hit_button(&layout, x, y) == Some(pressed) {
            activate(hwnd, pressed);
        }
    }

    fn activate(hwnd: HWND, button: Button) {
        match button {
            Button::FontDown => change_font(hwnd, -FONT_STEP),
            Button::FontUp => change_font(hwnd, FONT_STEP),
            Button::Lock => toggle_lock(hwnd),
            Button::Previous => super::emit(Command::Previous),
            Button::PlayPause => super::emit(Command::PlayPause),
            Button::Next => super::emit(Command::Next),
            Button::Close => super::emit(Command::Close),
        }
    }

    fn change_font(hwnd: HWND, delta: i32) {
        let next = {
            let mut guard = super::state();
            let next = (guard.font_size + delta).clamp(MIN_FONT_SIZE, MAX_FONT_SIZE);
            if next == guard.font_size {
                return;
            }
            guard.font_size = next;
            next
        };
        super::emit(Command::FontSizeChanged(next));
        apply(hwnd);
    }

    fn toggle_lock(hwnd: HWND) {
        let locked = {
            let mut guard = super::state();
            guard.locked = !guard.locked;
            guard.hovered = false;
            guard.hovered_button = None;
            guard.pressed_button = None;
            guard.locked
        };
        super::emit(Command::LockChanged(locked));
        apply(hwnd);
    }

    /// 按当前字号与锁定状态调窗口大小 / 扩展样式，然后重绘
    fn apply(hwnd: HWND) {
        let (_, _, font_size, locked, _, _) = snapshot();
        let dpi = unsafe { GetDpiForWindow(hwnd) };
        let scale = if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 };
        let layout = Layout::new(scale, font_size);

        unsafe {
            let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
            let wanted = if locked {
                style | WS_EX_TRANSPARENT.0
            } else {
                style & !WS_EX_TRANSPARENT.0
            };
            if wanted != style {
                SetWindowLongPtrW(hwnd, GWL_EXSTYLE, wanted as isize);
            }

            let mut rect = RECT::default();
            let _ = GetWindowRect(hwnd, &mut rect);
            let width = rect.right - rect.left;
            let height = rect.bottom - rect.top;
            if width != layout.width || height != layout.height {
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    0,
                    0,
                    layout.width,
                    layout.height,
                    SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
                );
            }
        }
        paint(hwnd);
    }

    /// 整窗重绘：画到 32 位 DIB（预乘 alpha），再整块交给 `UpdateLayeredWindow`
    fn paint(hwnd: HWND) {
        let (text, playing, font_size, locked, hovered, hovered_button) = snapshot();
        let dpi = unsafe { GetDpiForWindow(hwnd) };
        let scale = if dpi == 0 { 1.0 } else { dpi as f32 / 96.0 };
        let layout = Layout::new(scale, font_size);
        let width = layout.width;
        let height = layout.height;
        if width <= 0 || height <= 0 {
            return;
        }

        let screen = unsafe { GetDC(None) };
        if screen.0 == 0 {
            return;
        }
        let mem = unsafe { CreateCompatibleDC(screen) };
        let header = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            // 负高度 = 自上而下，省掉逐行翻转
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let info = BITMAPINFO {
            bmiHeader: header,
            ..Default::default()
        };
        let mut bits: *mut c_void = null_mut();
        let dib: HBITMAP =
            match unsafe { CreateDIBSection(mem, &info, DIB_RGB_COLORS, &mut bits, None, 0) } {
                Ok(handle) if !bits.is_null() => handle,
                _ => {
                    unsafe {
                        let _ = DeleteDC(mem);
                        ReleaseDC(None, screen);
                    }
                    return;
                }
            };
        let old = unsafe { SelectObject(mem, HGDIOBJ(dib.0)) };

        let mut bitmap: *mut GpBitmap = null_mut();
        let mut graphics: *mut GpGraphics = null_mut();
        let created = unsafe {
            GdipCreateBitmapFromScan0(
                width,
                height,
                width * 4,
                PIXEL_FORMAT_32BPP_PARGB,
                Some(bits as *const u8),
                &mut bitmap,
            )
        };
        let ready = created.0 == 0
            && !bitmap.is_null()
            && unsafe { GdipGetImageGraphicsContext(bitmap as *mut GpImage, &mut graphics) }.0 == 0;
        if ready {
            draw(
                graphics,
                &layout,
                &text,
                playing,
                hovered && !locked,
                hovered_button,
            );
            unsafe {
                let _ = GdipFlush(graphics, FlushIntentionSync);
                let _ = GdipDeleteGraphics(graphics);
            }
        }

        // 记下 alpha：命中测试靠它区分「字」和「空白」
        {
            let mut alphas = vec![0u8; (width as usize) * (height as usize)];
            for (index, alpha) in alphas.iter_mut().enumerate() {
                *alpha = unsafe { *bits.cast::<u8>().add(index * 4 + 3) };
            }
            *frame() = Some(Frame {
                width,
                height,
                alpha: alphas,
            });
        }

        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        let size = SIZE {
            cx: width,
            cy: height,
        };
        let source = POINT { x: 0, y: 0 };
        unsafe {
            let _ = UpdateLayeredWindow(
                hwnd,
                screen,
                None,
                Some(&size),
                mem,
                Some(&source),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            );
            SelectObject(mem, old);
            if !bitmap.is_null() {
                let _ = GdipDisposeImage(bitmap as *mut GpImage);
            }
            let _ = DeleteObject(HGDIOBJ(dib.0));
            let _ = DeleteDC(mem);
            ReleaseDC(None, screen);
        }
    }

    fn draw(
        graphics: *mut GpGraphics,
        layout: &Layout,
        text: &str,
        playing: bool,
        chrome: bool,
        hovered_button: Option<Button>,
    ) {
        let ui = family("Microsoft YaHei UI").or_else(|| family("Segoe UI"));
        let icons = family("Segoe MDL2 Assets");

        unsafe {
            let _ = GdipGraphicsClear(graphics, 0x0000_0000);
            let _ = GdipSetSmoothingMode(graphics, SmoothingModeAntiAlias);
            let _ = GdipSetTextRenderingHint(graphics, TextRenderingHintAntiAliasGridFit);

            if chrome {
                fill_round_rect(
                    graphics,
                    BACKDROP,
                    RectF {
                        X: 0.0,
                        Y: 0.0,
                        Width: layout.width as f32,
                        Height: layout.height as f32,
                    },
                    layout.radius,
                );
                if let Some(button) = hovered_button {
                    if let Some((_, rect)) = layout.buttons.iter().find(|(item, _)| *item == button)
                    {
                        fill_round_rect(
                            graphics,
                            argb(52, 255, 255, 255),
                            *rect,
                            7.0 * layout.scale,
                        );
                    }
                }
            }

            // 歌词：先画一层下偏移的阴影，浅色壁纸上也读得清
            let (lyric, lyric_alpha) = if text.is_empty() {
                ("♪ 暂无歌词", 150u32)
            } else {
                (text, 255u32)
            };
            if let (Some(ui), Ok(format)) = (ui, make_format(true)) {
                let shadow = RectF {
                    X: layout.text.X,
                    Y: layout.text.Y + 2.0 * layout.scale,
                    Width: layout.text.Width,
                    Height: layout.text.Height,
                };
                draw_text(
                    graphics,
                    lyric,
                    ui,
                    layout.font_px,
                    argb(170, 0, 0, 0),
                    &shadow,
                    format,
                );
                draw_text(
                    graphics,
                    lyric,
                    ui,
                    layout.font_px,
                    argb(lyric_alpha, 245, 245, 245),
                    &layout.text,
                    format,
                );
                let _ = GdipDeleteStringFormat(format);
            }

            if chrome {
                if let Ok(format) = make_format(false) {
                    for (button, rect) in layout.buttons.iter() {
                        let (label, family) = match button {
                            Button::FontDown => ("A-", ui),
                            Button::FontUp => ("A+", ui),
                            Button::Previous => ("\u{E892}", icons),
                            Button::PlayPause => {
                                if playing {
                                    ("\u{E769}", icons)
                                } else {
                                    ("\u{E768}", icons)
                                }
                            }
                            Button::Next => ("\u{E893}", icons),
                            Button::Lock => ("\u{E72E}", icons),
                            Button::Close => ("\u{E8BB}", icons),
                        };
                        let Some(family) = family else {
                            continue;
                        };
                        let is_label = matches!(button, Button::FontDown | Button::FontUp);
                        let size = if is_label {
                            layout.button_size * 0.46
                        } else {
                            layout.button_size * 0.58
                        };
                        draw_text(
                            graphics,
                            label,
                            family,
                            size,
                            argb(240, 235, 235, 235),
                            rect,
                            format,
                        );
                    }
                    let _ = GdipDeleteStringFormat(format);
                }
            }
        }

        for handle in [ui, icons].into_iter().flatten() {
            unsafe {
                let _ = GdipDeleteFontFamily(handle);
            }
        }
    }

    unsafe fn draw_text(
        graphics: *mut GpGraphics,
        text: &str,
        family: *const GpFontFamily,
        size: f32,
        color: u32,
        rect: &RectF,
        format: *const GpStringFormat,
    ) {
        let mut font: *mut GpFont = null_mut();
        if unsafe { GdipCreateFont(family, size, FontStyleBold.0, UnitPixel, &mut font) }.0 != 0 {
            return;
        }
        let mut brush: *mut GpSolidFill = null_mut();
        if unsafe { GdipCreateSolidFill(color, &mut brush) }.0 == 0 {
            let mut utf16: Vec<u16> = text.encode_utf16().collect();
            unsafe {
                let _ = GdipDrawString(
                    graphics,
                    PCWSTR(utf16.as_mut_ptr()),
                    utf16.len() as i32,
                    font,
                    rect,
                    format,
                    brush as *const GpBrush,
                );
                let _ = GdipDeleteBrush(brush as *mut GpBrush);
            }
        }
        unsafe {
            let _ = GdipDeleteFont(font);
        }
    }

    unsafe fn fill_round_rect(graphics: *mut GpGraphics, color: u32, rect: RectF, radius: f32) {
        let mut path: *mut GpPath = null_mut();
        if unsafe { GdipCreatePath(FillModeAlternate, &mut path) }.0 != 0 {
            return;
        }
        let r = radius.min(rect.Width / 2.0).min(rect.Height / 2.0);
        let (x, y, w, h) = (rect.X, rect.Y, rect.Width, rect.Height);
        unsafe {
            let _ = GdipAddPathArc(path, x, y, 2.0 * r, 2.0 * r, 180.0, 90.0);
            let _ = GdipAddPathArc(path, x + w - 2.0 * r, y, 2.0 * r, 2.0 * r, 270.0, 90.0);
            let _ = GdipAddPathArc(
                path,
                x + w - 2.0 * r,
                y + h - 2.0 * r,
                2.0 * r,
                2.0 * r,
                0.0,
                90.0,
            );
            let _ = GdipAddPathArc(path, x, y + h - 2.0 * r, 2.0 * r, 2.0 * r, 90.0, 90.0);
            let _ = GdipClosePathFigure(path);
            let mut brush: *mut GpSolidFill = null_mut();
            if GdipCreateSolidFill(color, &mut brush).0 == 0 {
                let _ = GdipFillPath(graphics, brush as *mut GpBrush, path);
                let _ = GdipDeleteBrush(brush as *mut GpBrush);
            }
            let _ = GdipDeletePath(path);
        }
    }

    fn make_format(trim: bool) -> Result<*mut GpStringFormat, ()> {
        let mut format: *mut GpStringFormat = null_mut();
        unsafe {
            if GdipCreateStringFormat(0, 0, &mut format).0 != 0 || format.is_null() {
                return Err(());
            }
            let _ = GdipSetStringFormatAlign(format, StringAlignmentCenter);
            let _ = GdipSetStringFormatLineAlign(format, StringAlignmentCenter);
            let _ = GdipSetStringFormatFlags(format, StringFormatFlagsNoWrap.0);
            if trim {
                let _ = GdipSetStringFormatTrimming(format, StringTrimmingEllipsisCharacter);
            }
        }
        Ok(format)
    }

    fn family(name: &str) -> Option<*mut GpFontFamily> {
        let wide_name = wide(name);
        let mut handle: *mut GpFontFamily = null_mut();
        let status = unsafe {
            GdipCreateFontFamilyFromName(PCWSTR(wide_name.as_ptr()), null_mut(), &mut handle)
        };
        if status.0 == 0 && !handle.is_null() {
            Some(handle)
        } else {
            None
        }
    }

    /// 命中测试：取上一帧该点附近有没有实心像素（字是细笔画，允许 6px 容差）
    fn alpha_near(x: i32, y: i32) -> u8 {
        let guard = frame();
        let Some(frame) = guard.as_ref() else {
            return 0;
        };
        let mut best = 0;
        for dy in [-6, 0, 6] {
            for dx in [-6, 0, 6] {
                let px = x + dx;
                let py = y + dy;
                if px < 0 || py < 0 || px >= frame.width || py >= frame.height {
                    continue;
                }
                let alpha = frame.alpha[(py * frame.width + px) as usize];
                best = best.max(alpha);
            }
        }
        best
    }

    fn hit_button(layout: &Layout, x: f32, y: f32) -> Option<Button> {
        layout
            .buttons
            .iter()
            .find(|(_, rect)| {
                x >= rect.X && x <= rect.X + rect.Width && y >= rect.Y && y <= rect.Y + rect.Height
            })
            .map(|(button, _)| *button)
    }

    /// 窗口内所有可点区域的几何布局（96 DPI 为基准，按 dpi 缩放）
    struct Layout {
        scale: f32,
        width: i32,
        height: i32,
        radius: f32,
        font_px: f32,
        button_size: f32,
        buttons: Vec<(Button, RectF)>,
        text: RectF,
    }

    impl Layout {
        fn new(scale: f32, font_size: i32) -> Self {
            const ORDER: [Button; 7] = [
                Button::FontDown,
                Button::FontUp,
                Button::Previous,
                Button::PlayPause,
                Button::Next,
                Button::Lock,
                Button::Close,
            ];
            let width = (WIDTH_96 * scale).round() as i32;
            let pad = 14.0 * scale;
            let button_size = 28.0 * scale;
            let gap = 4.0 * scale;
            let group = 16.0 * scale;
            let top = 8.0 * scale;
            let font_px = font_size as f32 * scale;
            let text_height = (font_size as f32 * 1.45).max(38.0) * scale;
            let height =
                (top + button_size + 6.0 * scale + text_height + 8.0 * scale).round() as i32;

            let gaps = [gap, group, gap, gap, group, gap];
            let total = button_size * ORDER.len() as f32 + gaps.iter().sum::<f32>();
            let mut x = (width as f32 - total) / 2.0;
            let mut buttons = Vec::with_capacity(ORDER.len());
            for (index, button) in ORDER.iter().enumerate() {
                buttons.push((
                    *button,
                    RectF {
                        X: x,
                        Y: top,
                        Width: button_size,
                        Height: button_size,
                    },
                ));
                if let Some(gap) = gaps.get(index) {
                    x += button_size + gap;
                }
            }

            let text = RectF {
                X: pad,
                Y: top + button_size + 6.0 * scale,
                Width: width as f32 - 2.0 * pad,
                Height: text_height,
            };

            Self {
                scale,
                width,
                height,
                radius: 12.0 * scale,
                font_px,
                button_size,
                buttons,
                text,
            }
        }
    }

    const fn argb(alpha: u32, red: u32, green: u32, blue: u32) -> u32 {
        (alpha << 24) | (red << 16) | (green << 8) | blue
    }

    fn loword(value: LPARAM) -> i32 {
        (value.0 as i32 & 0xffff) as i16 as i32
    }

    fn hiword(value: LPARAM) -> i32 {
        ((value.0 as i32 >> 16) & 0xffff) as i16 as i32
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn buttons_stay_inside_the_window() {
            for scale in [1.0f32, 1.25, 1.5, 2.0] {
                let layout = Layout::new(scale, 27);
                for (_, rect) in &layout.buttons {
                    assert!(rect.X >= 0.0, "按钮左边界越界：{scale}");
                    assert!(rect.Y >= 0.0, "按钮上边界越界：{scale}");
                    assert!(
                        rect.X + rect.Width <= layout.width as f32 + 0.01,
                        "按钮右边界越界：{scale}"
                    );
                    assert!(
                        rect.Y + rect.Height <= layout.height as f32 + 0.01,
                        "按钮下边界越界：{scale}"
                    );
                }
                assert!(
                    layout.text.Y + layout.text.Height <= layout.height as f32 + 0.01,
                    "歌词行超出窗口：{scale}"
                );
            }
        }

        #[test]
        fn buttons_do_not_overlap() {
            let layout = Layout::new(1.0, 27);
            for pair in layout.buttons.windows(2) {
                assert!(
                    pair[0].1.X + pair[0].1.Width <= pair[1].1.X + 0.01,
                    "按钮重叠：{:?} / {:?}",
                    pair[0].0,
                    pair[1].0
                );
            }
        }

        #[test]
        fn taller_font_grows_the_window_without_widening_it() {
            let small = Layout::new(1.0, MIN_FONT_SIZE);
            let large = Layout::new(1.0, MAX_FONT_SIZE);
            assert!(large.height > small.height);
            assert_eq!(large.width, small.width);
        }

        #[test]
        fn buttons_are_in_the_expected_order() {
            let layout = Layout::new(1.0, 27);
            let order: Vec<Button> = layout.buttons.iter().map(|(button, _)| *button).collect();
            assert_eq!(
                order,
                vec![
                    Button::FontDown,
                    Button::FontUp,
                    Button::Previous,
                    Button::PlayPause,
                    Button::Next,
                    Button::Lock,
                    Button::Close,
                ]
            );
        }

        /// 真正跑一遍「DIB + GDI+ 位图 + 逐像素 alpha」这条链路。
        ///
        /// 这条链路不建窗口也能验证：GDI+ 若不肯往外部 scan0 里写、或者写出来
        /// 的 alpha 全是 0，窗口在桌面上就是全透明的——肉眼只能看到「什么都没
        /// 有」，很难判断是绘制失败还是没显示。这里直接读回 alpha 断言。
        fn render(text: &str, chrome: bool, playing: bool) -> (i32, i32, Vec<u8>) {
            let layout = Layout::new(1.0, 27);
            let width = layout.width;
            let height = layout.height;
            unsafe {
                let screen = GetDC(None);
                let mem = CreateCompatibleDC(screen);
                let header = BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: width,
                    biHeight: -height,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                };
                let info = BITMAPINFO {
                    bmiHeader: header,
                    ..Default::default()
                };
                let mut bits: *mut c_void = null_mut();
                let dib = CreateDIBSection(mem, &info, DIB_RGB_COLORS, &mut bits, None, 0)
                    .expect("CreateDIBSection");
                assert!(!bits.is_null());

                let mut bitmap: *mut GpBitmap = null_mut();
                let mut graphics: *mut GpGraphics = null_mut();
                assert_eq!(
                    GdipCreateBitmapFromScan0(
                        width,
                        height,
                        width * 4,
                        PIXEL_FORMAT_32BPP_PARGB,
                        Some(bits as *const u8),
                        &mut bitmap,
                    )
                    .0,
                    0,
                    "GDI+ 不接受外部 scan0"
                );
                assert_eq!(
                    GdipGetImageGraphicsContext(bitmap as *mut GpImage, &mut graphics).0,
                    0
                );
                draw(
                    graphics,
                    &layout,
                    text,
                    playing,
                    chrome,
                    Some(Button::PlayPause),
                );
                let _ = GdipFlush(graphics, FlushIntentionSync);
                let _ = GdipDeleteGraphics(graphics);
                let _ = GdipDisposeImage(bitmap as *mut GpImage);

                let mut alphas = vec![0u8; (width * height) as usize];
                for (index, alpha) in alphas.iter_mut().enumerate() {
                    *alpha = *bits.cast::<u8>().add(index * 4 + 3);
                }

                let _ = DeleteObject(HGDIOBJ(dib.0));
                let _ = DeleteDC(mem);
                ReleaseDC(None, screen);
                (width, height, alphas)
            }
        }

        fn alpha_at(frame: &(i32, i32, Vec<u8>), x: i32, y: i32) -> u8 {
            let (width, _, alphas) = frame;
            alphas[(y * width + x) as usize]
        }

        #[test]
        fn gdiplus_draws_opaque_backdrop_and_text() {
            let _guard = gdiplus();
            let frame = render("夜航", true, true);
            let (width, height, alphas) = &frame;

            // 圆角底：窗口顶部中间应是不透明的深灰
            assert!(
                alpha_at(&frame, width / 2, 4) >= 150,
                "悬停背景没画出来：alpha = {}",
                alpha_at(&frame, width / 2, 4)
            );
            // 四角在圆角之外，保持透明
            assert_eq!(alpha_at(&frame, 1, 1), 0, "圆角外不该有像素");
            let opaque = alphas.iter().filter(|alpha| **alpha > 0).count();
            assert!(opaque > 1000, "画出来的像素太少：{opaque}");
            assert!(*height > 60);
        }

        #[test]
        fn no_hover_leaves_the_window_transparent() {
            let _guard = gdiplus();
            let frame = render("夜航", false, false);
            let (width, height, alphas) = &frame;

            // 没悬停：整窗透明，只剩字的笔画
            assert_eq!(alpha_at(&frame, 2, 2), 0);
            assert_eq!(alpha_at(&frame, width / 2, 2), 0);
            let opaque = alphas.iter().filter(|alpha| **alpha > 0).count();
            assert!(opaque > 0, "歌词文字没画出来");
            // 字只占很小一块：远小于整窗
            assert!(
                opaque < (width * height / 4) as usize,
                "没悬停时不该铺满背景：{opaque}"
            );
        }

        /// GDI+ 是进程级单次初始化：多个用例共用一个 token，跑完不关
        fn gdiplus() -> std::sync::MutexGuard<'static, ()> {
            use std::sync::OnceLock;
            static GUARD: OnceLock<std::sync::Mutex<()>> = OnceLock::new();
            static INIT: OnceLock<()> = OnceLock::new();
            let guard = GUARD.get_or_init(|| std::sync::Mutex::new(()));
            let guard = guard
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            INIT.get_or_init(|| {
                let mut token = 0usize;
                let input = GdiplusStartupInput {
                    GdiplusVersion: 1,
                    DebugEventCallback: 0,
                    SuppressBackgroundThread: BOOL(0),
                    SuppressExternalCodecs: BOOL(0),
                };
                let status = unsafe { GdiplusStartup(&mut token, &input, null_mut()) };
                assert_eq!(status.0, 0, "GDI+ 初始化失败");
            });
            guard
        }
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

    pub(super) fn request_apply(_hwnd: isize) {}

    pub(super) fn request_repaint(_hwnd: isize) {}
}

//! 桌面歌词窗口的开关、内容更新与按钮命令回流。

use crate::desktop_lyrics;
use crate::frb_generated::StreamSink;
use anyhow::Result;

/// 桌面歌词窗口按钮发来的命令
///
/// 带值的变化（锁定 / 字号）不塞进命令里：FRB 给带字段的枚举生成 Dart 代码时
/// 需要 `freezed` 依赖，为一个布尔值不值得。收到命令后用
/// `desktop_lyrics_locked()` / `desktop_lyrics_font_size()` 读最新状态即可。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DesktopLyricsCommand {
    PlayPause,
    Previous,
    Next,
    Close,
    /// 锁定状态变了（true = 已锁定，鼠标穿透）
    LockToggled,
    /// 用户点了字号 +/-
    FontSizeChanged,
}

/// 当前平台是否支持桌面歌词（目前只有 Windows）
#[flutter_rust_bridge::frb(sync)]
pub fn desktop_lyrics_supported() -> bool {
    cfg!(windows)
}

/// 当前是否处于锁定（鼠标穿透）状态
#[flutter_rust_bridge::frb(sync)]
pub fn desktop_lyrics_locked() -> bool {
    desktop_lyrics::locked()
}

/// 当前字号（16–56，96 DPI 逻辑像素）
#[flutter_rust_bridge::frb(sync)]
pub fn desktop_lyrics_font_size() -> i32 {
    desktop_lyrics::font_size()
}

/// 订阅桌面歌词窗口的按钮事件流。重复调用会重复注册，Dart 侧只订阅一次。
pub fn desktop_lyrics_commands(sink: StreamSink<DesktopLyricsCommand>) {
    desktop_lyrics::listen(move |command| {
        let command = match command {
            desktop_lyrics::Command::PlayPause => DesktopLyricsCommand::PlayPause,
            desktop_lyrics::Command::Previous => DesktopLyricsCommand::Previous,
            desktop_lyrics::Command::Next => DesktopLyricsCommand::Next,
            desktop_lyrics::Command::Close => DesktopLyricsCommand::Close,
            desktop_lyrics::Command::LockChanged(_) => DesktopLyricsCommand::LockToggled,
            desktop_lyrics::Command::FontSizeChanged(_) => DesktopLyricsCommand::FontSizeChanged,
        };
        if let Err(error) = sink.add(command) {
            // 流已关闭（应用退出中）不是错误，静默即可
            eprintln!("桌面歌词事件推送失败: {error}");
        }
    });
}

/// 显示桌面歌词窗口；未创建时先创建
pub fn desktop_lyrics_show() -> Result<()> {
    desktop_lyrics::show()
}

/// 隐藏桌面歌词窗口（窗口与线程保留）
pub fn desktop_lyrics_hide() -> Result<()> {
    desktop_lyrics::hide()
}

/// 更新桌面歌词显示的那一行
pub fn desktop_lyrics_set_line(line: String) -> Result<()> {
    desktop_lyrics::set_line(&line)
}

/// 同步播放状态：工具栏的播放 / 暂停字形跟着变
pub fn desktop_lyrics_set_playing(playing: bool) {
    desktop_lyrics::set_playing(playing);
}

/// 设置字号（16–56，96 DPI 逻辑像素）
pub fn desktop_lyrics_set_font_size(size: i32) {
    desktop_lyrics::set_font_size(size);
}

/// 锁定（鼠标穿透）/ 解锁
pub fn desktop_lyrics_set_locked(locked: bool) {
    desktop_lyrics::set_locked(locked);
}

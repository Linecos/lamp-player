//! 桌面歌词窗口的开关与内容更新。

use anyhow::Result;

/// 当前平台是否支持桌面歌词（目前只有 Windows）
#[flutter_rust_bridge::frb(sync)]
pub fn desktop_lyrics_supported() -> bool {
    cfg!(windows)
}

/// 显示桌面歌词窗口；未创建时先创建
pub fn desktop_lyrics_show() -> Result<()> {
    crate::desktop_lyrics::show()
}

/// 隐藏桌面歌词窗口（窗口与线程保留）
pub fn desktop_lyrics_hide() -> Result<()> {
    crate::desktop_lyrics::hide()
}

/// 更新桌面歌词显示的那一行
pub fn desktop_lyrics_set_line(line: String) -> Result<()> {
    crate::desktop_lyrics::set_line(&line)
}

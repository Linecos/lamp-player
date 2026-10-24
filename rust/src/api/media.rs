//! 系统集成：Windows 系统媒体控制（SMTC）与单实例。
//!
//! 两个功能都是「有更好、没有也能用」：非 Windows 或系统不支持时返回错误 /
//! 安全默认值，调用方忽略即可，不能影响播放本身。
//!
//! - **SMTC**：让媒体键、耳机线控、任务栏缩略图按钮、音量浮层看到曲目并控制播放
//! - **单实例**：第二个进程直接退出并把已有窗口提到前台（独占输出只允许一个持有者）
//!
//! 平台实现见 `crate::media_platform`。

use crate::frb_generated::StreamSink;
use crate::media_platform;
use anyhow::Result;

/// 系统媒体键 / 任务栏按钮发来的命令
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaCommand {
    Play,
    Pause,
    Next,
    Previous,
    Stop,
}

/// SMTC 认识的三种播放状态
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaPlayState {
    Playing,
    Paused,
    Stopped,
}

/// 当前平台是否支持 SMTC（Dart 侧据此决定是否订阅事件）
#[flutter_rust_bridge::frb(sync)]
pub fn media_is_supported() -> bool {
    cfg!(windows)
}

/// 初始化 SMTC；幂等，失败可重试
pub fn media_init() -> Result<()> {
    media_platform::init()
}

/// 更新系统浮层里的曲目信息；`cover_path` 指向本地图片文件，读不到就只用文字
pub fn media_set_track(
    title: String,
    artist: String,
    album: String,
    cover_path: Option<String>,
) -> Result<()> {
    media_platform::set_track(&title, &artist, &album, cover_path.as_deref())
}

/// 同步播放状态（播放 / 暂停 / 停止）
pub fn media_set_state(state: MediaPlayState) -> Result<()> {
    let state = match state {
        MediaPlayState::Playing => media_platform::PlayState::Playing,
        MediaPlayState::Paused => media_platform::PlayState::Paused,
        MediaPlayState::Stopped => media_platform::PlayState::Stopped,
    };
    media_platform::set_state(state)
}

/// 清空曲目信息并停用 SMTC（退出前调用）
pub fn media_clear() -> Result<()> {
    media_platform::clear()
}

/// 订阅系统按钮事件流。重复调用会重复注册，Dart 侧只订阅一次。
pub fn media_commands(sink: StreamSink<MediaCommand>) {
    media_platform::listen(move |command| {
        let command = match command {
            media_platform::Command::Play => MediaCommand::Play,
            media_platform::Command::Pause => MediaCommand::Pause,
            media_platform::Command::Next => MediaCommand::Next,
            media_platform::Command::Previous => MediaCommand::Previous,
            media_platform::Command::Stop => MediaCommand::Stop,
        };
        if let Err(error) = sink.add(command) {
            // 流已关闭（应用退出中）不是错误，静默即可
            eprintln!("SMTC 事件推送失败: {error}");
        }
    });
}

/// 申请成为唯一实例；`false` 表示已有实例在运行
pub fn single_instance_acquire() -> Result<bool> {
    media_platform::acquire()
}

/// 通知已有实例把窗口亮出来（第二个进程调用完就可以退出）
pub fn single_instance_signal_existing() -> Result<bool> {
    media_platform::signal_existing()
}

/// 是否有另一个进程请求把窗口亮出来；首个实例每 500ms 轮询一次
#[flutter_rust_bridge::frb(sync)]
pub fn single_instance_take_activation() -> bool {
    media_platform::take_activation()
}

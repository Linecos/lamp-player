//! 系统集成：Windows 系统媒体控制（SMTC）与单实例。
//!
//! 两个功能都是「有更好、没有也能用」：非 Windows 或系统不支持时返回错误 /
//! 安全默认值，调用方忽略即可，不能影响播放本身。
//!
//! - **SMTC**：让媒体键、耳机线控、任务栏缩略图按钮、音量浮层看到曲目并控制播放
//! - **单实例**：第二个进程直接退出并把已有窗口提到前台（独占输出只允许一个持有者）
//!
//! 媒体键只走 SMTC 一条路，不做 `RegisterHotKey`：那会在空闲时全局独占、暂停后
//! 释放又会让播放键落不到本应用。
//!
//! 平台实现见 `crate::media_platform`。

use crate::frb_generated::StreamSink;
use crate::media_platform;
use anyhow::Result;

/// 系统媒体键 / 任务栏按钮发来的命令
///
/// 循环 / 随机拆成三个 / 两个不带载荷的分支：frb 的枚举一旦带字段，Dart 侧
/// 就要引入 freezed 生成 sealed class；这里值域本来就小，直接展开更省事。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaCommand {
    Play,
    Pause,
    Next,
    Previous,
    Stop,
    /// 系统浮层把循环切到「不循环」
    RepeatOff,
    /// 系统浮层把循环切到「列表循环」
    RepeatAll,
    /// 系统浮层把循环切到「单曲循环」
    RepeatOne,
    /// 系统浮层打开随机
    ShuffleOn,
    /// 系统浮层关闭随机
    ShuffleOff,
}

/// SMTC 认识的三种播放状态
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaPlayState {
    Playing,
    Paused,
    Stopped,
}

/// 循环模式（与界面的「顺序 / 列表循环 / 单曲循环」一一对应）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaRepeatMode {
    Off,
    All,
    One,
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

/// 同步循环 / 随机状态到系统浮层。
///
/// Windows 的循环、随机按钮只有在会话里报过这两个属性之后才会点亮并可点，
/// 所以播放模式一变（含启动恢复）就要同步一次。
pub fn media_set_play_mode(repeat: MediaRepeatMode, shuffle: bool) -> Result<()> {
    let repeat = match repeat {
        MediaRepeatMode::Off => media_platform::RepeatMode::Off,
        MediaRepeatMode::All => media_platform::RepeatMode::List,
        MediaRepeatMode::One => media_platform::RepeatMode::Track,
    };
    media_platform::set_play_mode(repeat, shuffle)
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
            media_platform::Command::Repeat(mode) => match mode {
                media_platform::RepeatMode::Off => MediaCommand::RepeatOff,
                media_platform::RepeatMode::List => MediaCommand::RepeatAll,
                media_platform::RepeatMode::Track => MediaCommand::RepeatOne,
            },
            media_platform::Command::Shuffle(true) => MediaCommand::ShuffleOn,
            media_platform::Command::Shuffle(false) => MediaCommand::ShuffleOff,
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

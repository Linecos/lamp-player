//! 播放引擎 API（BASS）。
//!
//! 只做参数校验与状态映射，BASS 相关实现见 [`crate::bass`]。
//! 接口契约见 `docs/API_CONTRACT.md`，签名已冻结。
use crate::bass;
use anyhow::Result;

/// 播放状态
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackState {
    /// 未加载任何曲目，或已停止
    Stopped,
    /// 正在播放
    Playing,
    /// 已暂停（可 `player_resume` 续播）
    Paused,
}

/// BASS 是否可用；DLL 缺失或初始化失败时为 `false`
#[flutter_rust_bridge::frb(sync)]
pub fn player_is_available() -> bool {
    bass::is_available()
}

/// 加载并播放指定文件；当前正在播放的曲目会被停止
pub fn player_play(path: String) -> Result<()> {
    bass::play(&path)
}

/// 暂停当前曲目
pub fn player_pause() -> Result<()> {
    bass::pause()
}

/// 从暂停处继续播放
pub fn player_resume() -> Result<()> {
    bass::resume()
}

/// 停止播放并释放当前曲目
pub fn player_stop() -> Result<()> {
    bass::stop()
}

/// 跳转到指定位置（秒）
///
/// # Errors
/// `position_secs` 为负、超出曲目时长，或当前没有加载曲目时返回错误。
pub fn player_seek(position_secs: f64) -> Result<()> {
    bass::seek(position_secs)
}

/// 设置音量，取值 `0.0..=1.0`（超出范围会被截断）
pub fn player_set_volume(volume: f64) -> Result<()> {
    bass::set_volume(volume)
}

/// 当前播放位置（秒）；未加载曲目时返回 `0.0`
pub fn player_position() -> Result<f64> {
    bass::position()
}

/// 当前曲目总时长（秒）；未加载曲目时返回 `0.0`
pub fn player_duration() -> Result<f64> {
    bass::duration()
}

/// 当前播放状态
#[flutter_rust_bridge::frb(sync)]
pub fn player_state() -> PlaybackState {
    match bass::state() {
        bass::State::Stopped => PlaybackState::Stopped,
        bass::State::Playing => PlaybackState::Playing,
        bass::State::Paused => PlaybackState::Paused,
    }
}

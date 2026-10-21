//! 播放引擎 API（BASS）。
//!
//! **状态：接口契约已冻结（v0.1），实现待补。**
//! 契约变更流程见 `docs/API_CONTRACT.md`；任务清单见 `docs/ROADMAP.md`（M2）。
//!
//! 实现要点（供接手的人参考）：
//! - BASS 是闭源 DLL，不入库：用 `libloading` 在运行时加载
//!   `third_party/bass/windows/x64/bass.dll`（`scripts/setup-bass.ps1` 下载）
//! - 所有 BASS 调用都在**同一个线程**里做；UI 侧禁止阻塞等待
//! - 引擎单例放 `rust/src/bass.rs`，本文件只做参数校验与状态映射
//! - `volume` 统一用 `0.0..=1.0` 的浮点，内部再换算成 BASS 的 `0..10000`

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

/// BASS 是否可用（DLL 缺失或加载失败时为 `false`，UI 据此降级提示）
///
/// 同步函数：只读一个状态位，UI 可在 `build` 里直接调用。
#[flutter_rust_bridge::frb(sync)]
pub fn player_is_available() -> bool {
    false // TODO(M2): 改为查询 bass 单例的加载状态
}

/// 加载并播放指定文件；当前正在播放的曲目会被停止。
pub fn player_play(path: String) -> Result<()> {
    let _ = path;
    anyhow::bail!("player_play 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 暂停当前曲目。
pub fn player_pause() -> Result<()> {
    anyhow::bail!("player_pause 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 从暂停处继续播放。
pub fn player_resume() -> Result<()> {
    anyhow::bail!("player_resume 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 停止播放并释放当前曲目。
pub fn player_stop() -> Result<()> {
    anyhow::bail!("player_stop 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 跳转到指定位置（秒）。
///
/// # Errors
/// `position_secs` 为负、超出曲目时长，或当前没有加载曲目时返回错误。
pub fn player_seek(position_secs: f64) -> Result<()> {
    let _ = position_secs;
    anyhow::bail!("player_seek 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 设置音量，取值 `0.0..=1.0`（超出范围会被截断）。
pub fn player_set_volume(volume: f64) -> Result<()> {
    let _ = volume;
    anyhow::bail!("player_set_volume 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 当前播放位置（秒）；未加载曲目时返回 `0.0`。
pub fn player_position() -> Result<f64> {
    anyhow::bail!("player_position 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 当前曲目总时长（秒）；未加载曲目时返回 `0.0`。
pub fn player_duration() -> Result<f64> {
    anyhow::bail!("player_duration 尚未实现（骨架存根，见 rust/src/api/player.rs）")
}

/// 当前播放状态。
///
/// 同步函数：只读内存状态，UI 可在 `build` 里直接调用。
#[flutter_rust_bridge::frb(sync)]
pub fn player_state() -> PlaybackState {
    PlaybackState::Stopped // TODO(M2): 映射 BASS_ACTIVE_* 状态
}

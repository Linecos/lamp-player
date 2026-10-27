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

/// 播放进度快照：位置、时长与状态一次取全
#[derive(Clone, Copy, Debug)]
pub struct PlayerProgress {
    /// 当前播放位置（秒）
    pub position_secs: f64,
    /// 曲目总时长（秒）
    pub duration_secs: f64,
    /// 同一时刻的播放状态
    pub state: PlaybackState,
}

/// 一次调用拿全进度、时长与状态；未加载曲目时位置与时长都是 `0.0`。
///
/// 界面每 500 ms 轮询用这个：分三次取会多出两次跨线程往返，而且可能落在
/// 换曲两侧，进度条会跳一下。
pub fn player_now() -> Result<PlayerProgress> {
    let progress = bass::snapshot()?;
    Ok(PlayerProgress {
        position_secs: progress.position,
        duration_secs: progress.duration,
        state: player_state(),
    })
}

/// 当前播放位置（秒）；未加载曲目时返回 `0.0`
pub fn player_position() -> Result<f64> {
    bass::position()
}

/// 当前曲目总时长（秒）；未加载曲目时返回 `0.0`
pub fn player_duration() -> Result<f64> {
    bass::duration()
}

/// 当前是否真的在用 WASAPI 独占输出
///
/// 请求独占但 DLL 缺失 / 设备被占用 / 设备不支持时会是 `false`。
/// 同步函数：只读一个状态位，UI 可在 `build` 里直接调用。
#[flutter_rust_bridge::frb(sync)]
pub fn player_is_exclusive() -> bool {
    bass::is_exclusive()
}

/// 切换独占 / 共享输出
///
/// 切换会重开当前曲目：保留播放位置与播放状态，正在出声时会短暂中断。
/// 独占不可用（DLL 缺失 / 设备被占 / 格式不支持）时**回落共享并返回成功**，
/// 具体原因见 `player_exclusive_note`。
pub fn player_set_exclusive(exclusive: bool) -> Result<()> {
    bass::set_exclusive(exclusive)
}

/// 设置 10 段均衡器；`gains` 为各段增益（dB，31Hz→16kHz），长度必须为 10
///
/// 关闭时摘掉全部 FX。共享模式挂在曲目流上，独占模式挂在混音流上，
/// 换曲 / 切换输出后自动重新应用。
pub fn player_set_equalizer(enabled: bool, gains: Vec<f32>) -> Result<()> {
    bass::set_eq(enabled, gains)
}

/// 当前输出的可读描述（模式 / 采样率 / 声道 / 缓冲），用于设置页展示
pub fn player_output_info() -> Result<String> {
    bass::output_info()
}

/// 关闭播放引擎并释放设备
///
/// 应用退出前调用。独占模式下设备由本进程持有，靠进程被回收再交还
/// 会让其它程序在这之前一直没声音。
pub fn player_shutdown() -> Result<()> {
    bass::shutdown()
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

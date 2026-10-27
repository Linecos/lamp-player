//! BASS 音频引擎的运行时加载与播放控制。
//!
//! 内部模块，只被 [`crate::api::player`] 调用，不导出给 Dart。
//!
//! - 所有 BASS 调用都在同一条引擎线程上串行执行（命令队列 + 回执通道）
//! - [`is_available`] / [`state`] 只读原子量，可在 UI 的 `build` 里直接调用
//! - 非 Windows 平台编译为空实现，保证 CI 的 Linux job 能通过

use anyhow::Result;

#[cfg(windows)]
mod api;
#[cfg(windows)]
mod wasapi;

/// 播放状态（与 `api::player::PlaybackState` 一一对应）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Stopped,
    Playing,
    Paused,
}

/// 一次调用同时拿到的播放进度。
///
/// 位置与时长分两次取时，两次之间可能跨过换曲：位置属于新曲、时长还是旧曲，
/// 进度条会跳一下；合并成一条命令也少一半跨线程往返。
#[derive(Clone, Copy, Debug, Default)]
pub struct Progress {
    pub position: f64,
    pub duration: f64,
}

/// 一个可选的输出设备（索引与 `BASS_GetDeviceInfo` 一致，`-1` 表示系统默认）
#[derive(Clone, Debug)]
pub struct Device {
    pub index: i32,
    pub name: String,
    pub is_default: bool,
}

/// BASS 是否可用（DLL 加载 + 初始化成功）
///
/// 首次调用会触发初始化并等待引擎就绪（约几十毫秒），之后只读原子量。
pub fn is_available() -> bool {
    imp::available()
}

/// 当前播放状态
pub fn state() -> State {
    imp::state()
}

/// 加载并播放指定文件，会先停止当前曲目
///
/// `replay_gain_db` 是曲目标签里的 ReplayGain 增益；0 表示不做响度归一。
pub fn play(path: &str, replay_gain_db: f64) -> Result<()> {
    imp::play(path, replay_gain_db)
}

/// 可用的输出设备（共享模式），系统默认设备排在最前
pub fn devices() -> Result<Vec<Device>> {
    imp::devices()
}

/// 切换共享输出设备；保留当前曲目、位置与播放状态
pub fn set_device(index: i32) -> Result<()> {
    imp::set_device(index)
}

/// 当前选中的设备索引；`-1` 表示系统默认
pub fn current_device() -> i32 {
    imp::current_device()
}

/// 换曲交叉淡变时长（毫秒）；0 关闭
pub fn set_crossfade(millis: u32) -> Result<()> {
    imp::set_crossfade(millis)
}

/// 暂停
pub fn pause() -> Result<()> {
    imp::pause()
}

/// 从暂停处继续
pub fn resume() -> Result<()> {
    imp::resume()
}

/// 停止并释放当前曲目
pub fn stop() -> Result<()> {
    imp::stop()
}

/// 跳转到指定位置（秒）
pub fn seek(position_secs: f64) -> Result<()> {
    imp::seek(position_secs)
}

/// 设置音量（0.0~1.0，越界截断）
pub fn set_volume(volume: f64) -> Result<()> {
    imp::set_volume(volume)
}

/// 当前位置与总时长（秒），未加载曲目时为 0.0。
///
/// 轮询用这个而不是分别调 `position` / `duration`：一次线程往返拿全，
/// 也不会出现「位置是新曲、时长还是旧曲」的错位。
pub fn snapshot() -> Result<Progress> {
    imp::snapshot()
}

/// 频谱段数：Dart 侧按帧长度自适应，这里只作为引擎与测试的约定
pub const SPECTRUM_BANDS: usize = 24;

/// 当前位置（秒），未加载曲目时为 0.0
pub fn position() -> Result<f64> {
    imp::position()
}

/// 当前输出的对数分频频谱（[`SPECTRUM_BANDS`] 段，0~1）；没在放歌时全 0
pub fn spectrum() -> Result<Vec<f32>> {
    imp::spectrum()
}

/// 总时长（秒），未加载曲目时为 0.0
pub fn duration() -> Result<f64> {
    imp::duration()
}

/// 当前是否真的在用 WASAPI 独占输出
///
/// 请求独占但 DLL 缺失 / 设备不支持时会是 `false`，界面据此提示原因。
pub fn is_exclusive() -> bool {
    imp::is_exclusive()
}

/// 切换独占 / 共享输出
///
/// 切换会重开当前曲目：保留播放位置与播放状态，正在出声时会短暂中断。
pub fn set_exclusive(exclusive: bool) -> Result<()> {
    imp::set_exclusive(exclusive)
}

/// 当前输出的可读描述（模式 / 采样率 / 声道 / 缓冲），失败时为原因
/// 设置 10 段均衡器（dB）；`enabled` 为 false 时摘掉全部 FX
pub fn set_eq(enabled: bool, gains: Vec<f32>) -> Result<()> {
    imp::set_eq(enabled, gains)
}

pub fn output_info() -> Result<String> {
    imp::output_info()
}

/// 关闭引擎线程并释放设备
///
/// 应用退出前调用：独占模式下设备由本进程持有，等进程被系统回收再交还
/// 会让别的程序在这之前一直没声音。未初始化时是空操作。
pub fn shutdown() -> Result<()> {
    imp::shutdown()
}

#[cfg(windows)]
#[cfg(windows)]
#[path = "bass/windows.rs"]
mod imp;

#[cfg(not(windows))]
#[path = "bass/portable.rs"]
mod imp;

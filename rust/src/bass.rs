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
pub fn play(path: &str) -> Result<()> {
    imp::play(path)
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

/// 当前位置（秒），未加载曲目时为 0.0
pub fn position() -> Result<f64> {
    imp::position()
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

//! 播放引擎 API（BASS）。
//!
//! 只做参数校验与状态映射，BASS 相关实现见 [`crate::bass`]。
//! 接口契约见 `docs/API_CONTRACT.md`，签名已冻结。
use crate::bass;
use crate::frb_generated::StreamSink;
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
///
/// `replay_gain_db` 是该曲目标签里的 ReplayGain 增益（dB），`0.0` 表示不做响度归一；
/// 由调用方按设置决定传标签值还是 0。
pub fn player_play(path: String, replay_gain_db: f64) -> Result<()> {
    bass::play(&path, replay_gain_db)
}

/// 应用起播后补算出的 ReplayGain 增益（dB），立即作用到当前输出。
///
/// 起播不能等增益：无标签曲目的现场分析要全曲解码，等它算完才 play，
/// 界面早已切歌、声音还停在上一首。所以 play 先带上已知值（标签或缓存），
/// 分析完成后再用这条把增益补进去。
pub fn player_set_replay_gain(gain_db: f64) -> Result<()> {
    bass::set_replay_gain(gain_db)
}

/// 分析整曲响度，返回 ReplayGain 建议增益（dB）
///
/// 曲目标签里没有 ReplayGain 时用这个现场补：按 ReplayGain 2.0 计算
/// （EBU R128 积分响度，目标 -18 LUFS），结果夹取 ±24 dB，全静音返回 0。
/// 全曲解码约需零点几秒到几秒，失败（文件损坏 / 格式不支持）直接报错。
pub fn player_analyze_replay_gain(path: String) -> Result<f64> {
    bass::analyze_gain(&path)
}

/// 可切换的输出设备
#[derive(Clone, Debug)]
pub struct PlayerDevice {
    /// `BASS_GetDeviceInfo` 的索引，切换时原样传回
    pub index: i32,
    pub name: String,
    /// 是否为当前选中的设备（默认设备也算）
    pub is_default: bool,
}

/// 可用的输出设备；`-1`（系统默认）由界面自己补一条，不在这里返回
pub fn player_devices() -> Result<Vec<PlayerDevice>> {
    Ok(bass::devices()?
        .into_iter()
        .map(|device| PlayerDevice {
            index: device.index,
            name: device.name,
            is_default: device.is_default,
        })
        .collect())
}

/// 切换输出设备（`-1` = 系统默认），保留当前曲目、位置与播放状态
pub fn player_set_device(index: i32) -> Result<()> {
    bass::set_device(index)
}

/// 当前选中的设备索引；`-1` 表示系统默认
#[flutter_rust_bridge::frb(sync)]
pub fn player_current_device() -> i32 {
    bass::current_device()
}

/// 换曲交叉淡变时长（秒）；`0` 关闭
///
/// 共享模式是真正的重叠交叉淡变；独占模式只有新曲淡入。
pub fn player_set_crossfade(seconds: f64) -> Result<()> {
    let millis = if seconds.is_finite() && seconds > 0.0 {
        (seconds * 1000.0).clamp(0.0, 20_000.0) as u32
    } else {
        0
    };
    bass::set_crossfade(millis)
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

/// 一次取一帧频谱（24 段，0~1），给不想开流的调用方 / 测试用。
pub fn player_spectrum() -> Result<Vec<f32>> {
    bass::spectrum()
}

/// 频谱流：约 30fps 往 Dart 推一帧「各频段幅度」。
///
/// 取数要走引擎线程（BASS 是单线程串行访问的），所以在**独立线程**里循环，
/// 本函数立刻返回。Dart 侧取消订阅后 `add` 失败，线程自己退出——不会留下
/// 常驻线程空转。
pub fn player_spectrum_stream(sink: StreamSink<Vec<f32>>) -> Result<()> {
    std::thread::Builder::new()
        .name("lamp-spectrum".to_string())
        .spawn(move || loop {
            // 引擎不可用（没声卡 / DLL 缺失）时推静默帧，界面不用区分错误态
            let frame = bass::spectrum().unwrap_or_else(|_| vec![0.0; crate::bass::SPECTRUM_BANDS]);
            if sink.add(frame).is_err() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(33));
        })?;
    Ok(())
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

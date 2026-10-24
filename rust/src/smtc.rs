//! Windows 系统媒体控制（SMTC）。
//!
//! 作用：让键盘媒体键、耳机线控、任务栏缩略图按钮、Windows 音量浮层都能
//! 看到并控制本应用正在播放的曲目。
//!
//! 实现方式是借用一个**静音的** [`MediaPlayer`] 拿到它的
//! `SystemMediaTransportControls`：真正的音频仍由 BASS 输出，所以先把
//! `CommandManager` 关掉，避免 Windows 去驱动这个空播放器。
//!
//! WinRT 要求在已初始化 COM 的线程上激活，而 `frb` 的调用落到线程池，
//! 因此 [`init`] 会先按 MTA 初始化 COM（重复调用无害）。

use anyhow::{anyhow, Result};
use std::sync::{Mutex, OnceLock};
use windows::core::HSTRING;
use windows::Foundation::TypedEventHandler;
use windows::Media::Playback::MediaPlayer;
use windows::Media::{
    MediaPlaybackStatus, MediaPlaybackType, SystemMediaTransportControls,
    SystemMediaTransportControlsButton, SystemMediaTransportControlsButtonPressedEventArgs,
};
use windows::Storage::Streams::{
    DataWriter, InMemoryRandomAccessStream, RandomAccessStreamReference,
};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

/// 系统发来的控制命令
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Play,
    Pause,
    Next,
    Previous,
    Stop,
}

/// 播放状态（只区分 SMTC 关心的三种）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayState {
    Playing,
    Paused,
    Stopped,
}

struct Session {
    /// 仅用于持有 SMTC 的宿主；不要让它播放任何媒体
    _player: MediaPlayer,
    smtc: SystemMediaTransportControls,
}

/// `None` 表示尚未初始化；初始化失败也会留在 `None`，下次调用重试
static SESSION: OnceLock<Mutex<Option<Session>>> = OnceLock::new();

fn session() -> &'static Mutex<Option<Session>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

fn lock() -> std::sync::MutexGuard<'static, Option<Session>> {
    session()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 初始化 SMTC；幂等，失败可重试。
///
/// 系统不支持（精简版 Windows、被策略禁用）时返回错误，调用方忽略即可，
/// 不影响播放本身。
pub fn init() -> Result<()> {
    if lock().is_some() {
        return Ok(());
    }
    // S_FALSE（已初始化过）也是成功
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
        .ok()
        .map_err(|error| anyhow!("COM 初始化失败: {error}"))?;

    let player = MediaPlayer::new().map_err(|error| anyhow!("创建 MediaPlayer 失败: {error}"))?;
    player
        .CommandManager()
        .map_err(|error| anyhow!("读取 CommandManager 失败: {error}"))?
        .SetIsEnabled(false)
        .map_err(|error| anyhow!("关闭 CommandManager 失败: {error}"))?;
    let smtc = player
        .SystemMediaTransportControls()
        .map_err(|error| anyhow!("读取 SMTC 失败: {error}"))?;

    smtc.SetIsEnabled(true)
        .map_err(|error| anyhow!("启用 SMTC 失败: {error}"))?;
    for (name, result) in [
        ("上一首", smtc.SetIsPreviousEnabled(true)),
        ("播放", smtc.SetIsPlayEnabled(true)),
        ("暂停", smtc.SetIsPauseEnabled(true)),
        ("下一首", smtc.SetIsNextEnabled(true)),
    ] {
        if let Err(error) = result {
            // 个别按钮不可用不影响其余功能
            eprintln!("SMTC: 启用{name}按钮失败: {error}");
        }
    }

    *lock() = Some(Session {
        _player: player,
        smtc,
    });
    Ok(())
}

/// 更新曲目信息；`cover` 为内嵌封面（原始图片字节），没有就沿用系统占位图
pub fn set_track(title: &str, artist: &str, album: &str, cover: Option<&[u8]>) -> Result<()> {
    let guard = lock();
    let session = guard.as_ref().ok_or_else(|| anyhow!("SMTC 未初始化"))?;

    let updater = session
        .smtc
        .DisplayUpdater()
        .map_err(|error| anyhow!("读取 DisplayUpdater 失败: {error}"))?;
    updater
        .SetType(MediaPlaybackType::Music)
        .map_err(|error| anyhow!("设置媒体类型失败: {error}"))?;

    let properties = updater
        .MusicProperties()
        .map_err(|error| anyhow!("读取 MusicProperties 失败: {error}"))?;
    properties
        .SetTitle(&HSTRING::from(title))
        .map_err(|error| anyhow!("设置标题失败: {error}"))?;
    properties
        .SetArtist(&HSTRING::from(artist))
        .map_err(|error| anyhow!("设置艺术家失败: {error}"))?;
    properties
        .SetAlbumTitle(&HSTRING::from(album))
        .map_err(|error| anyhow!("设置专辑失败: {error}"))?;

    if let Some(bytes) = cover {
        if let Ok(reference) = stream_reference(bytes) {
            let _ = updater.SetThumbnail(&reference);
        }
    }
    updater
        .Update()
        .map_err(|error| anyhow!("提交元数据失败: {error}"))?;
    let _ = session.smtc.SetIsEnabled(true);
    Ok(())
}

/// 把图片字节包成 WinRT 的随机访问流
fn stream_reference(bytes: &[u8]) -> Result<RandomAccessStreamReference> {
    let writer = DataWriter::new()?;
    writer.WriteBytes(bytes)?;
    let buffer = writer.DetachBuffer()?;

    let stream = InMemoryRandomAccessStream::new()?;
    stream.WriteAsync(&buffer)?.get()?;
    stream.FlushAsync()?.get()?;
    Ok(RandomAccessStreamReference::CreateFromStream(&stream)?)
}

/// 同步播放状态；播完/停止后 Windows 会把浮层收起来
pub fn set_state(state: PlayState) -> Result<()> {
    let guard = lock();
    let session = guard.as_ref().ok_or_else(|| anyhow!("SMTC 未初始化"))?;
    let status = match state {
        PlayState::Playing => MediaPlaybackStatus::Playing,
        PlayState::Paused => MediaPlaybackStatus::Paused,
        PlayState::Stopped => MediaPlaybackStatus::Stopped,
    };
    session
        .smtc
        .SetPlaybackStatus(status)
        .map_err(|error| anyhow!("设置播放状态失败: {error}"))?;
    Ok(())
}

/// 清空曲目信息并停用 SMTC（退出前调用）
pub fn clear() -> Result<()> {
    let guard = lock();
    let Some(session) = guard.as_ref() else {
        return Ok(());
    };
    if let Ok(updater) = session.smtc.DisplayUpdater() {
        let _ = updater.ClearAll();
        let _ = updater.Update();
    }
    let _ = session.smtc.SetIsEnabled(false);
    Ok(())
}

/// 订阅系统按钮事件。
///
/// 只注册一次：重复订阅会让每个媒体键触发多次。回调在 WinRT 线程上执行，
/// 实现方（`api::media`）负责把它送进 ff i 流。
pub fn listen<F>(on_command: F) -> Result<()>
where
    F: Fn(Command) + Send + Sync + 'static,
{
    let guard = lock();
    let session = guard.as_ref().ok_or_else(|| anyhow!("SMTC 未初始化"))?;

    session
        .smtc
        .ButtonPressed(&TypedEventHandler::<
            SystemMediaTransportControls,
            SystemMediaTransportControlsButtonPressedEventArgs,
        >::new(move |_, args| {
            let Some(args) = args.as_ref() else {
                return Ok(());
            };
            let command = match args.Button() {
                Ok(SystemMediaTransportControlsButton::Play) => Command::Play,
                Ok(SystemMediaTransportControlsButton::Pause) => Command::Pause,
                Ok(SystemMediaTransportControlsButton::Next) => Command::Next,
                Ok(SystemMediaTransportControlsButton::Previous) => Command::Previous,
                Ok(SystemMediaTransportControlsButton::Stop) => Command::Stop,
                // 快进/快退/录音等按钮本应用不处理
                _ => return Ok(()),
            };
            on_command(command);
            Ok(())
        }))
        .map_err(|error| anyhow!("注册按钮事件失败: {error}"))?;
    Ok(())
}

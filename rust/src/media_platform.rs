//! 系统集成的平台实现（SMTC / 单实例）。
//!
//! 放在 `api` 之外：`api/` 下的每个 `pub fn` 都会被 frb 当作导出接口，
//! 平台实现里的同名函数会造成重复绑定，所以实现层单独成模块。

/// 系统媒体键发来的命令（与 `api::media::MediaCommand` 一一对应）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Play,
    Pause,
    Next,
    Previous,
    Stop,
}

/// 播放状态（与 `api::media::MediaPlayState` 一一对应）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlayState {
    Playing,
    Paused,
    Stopped,
}

#[cfg(windows)]
mod imp {
    use super::{Command, PlayState};
    use crate::smtc;
    use anyhow::Result;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// 事件只注册一次：重复注册会让每个媒体键触发多次
    static LISTENING: AtomicBool = AtomicBool::new(false);

    pub fn init() -> Result<()> {
        smtc::init()
    }

    pub fn set_track(
        title: &str,
        artist: &str,
        album: &str,
        cover_path: Option<&str>,
    ) -> Result<()> {
        // 封面读不到（被清理 / 权限不足）时只显示文字，不报错
        let cover = cover_path.and_then(|path| std::fs::read(path).ok());
        smtc::set_track(title, artist, album, cover.as_deref())
    }

    pub fn set_state(state: PlayState) -> Result<()> {
        let state = match state {
            PlayState::Playing => smtc::PlayState::Playing,
            PlayState::Paused => smtc::PlayState::Paused,
            PlayState::Stopped => smtc::PlayState::Stopped,
        };
        smtc::set_state(state)
    }

    pub fn clear() -> Result<()> {
        smtc::clear()
    }

    pub fn listen<F>(on_command: F)
    where
        F: Fn(Command) + Send + Sync + 'static,
    {
        if LISTENING.swap(true, Ordering::SeqCst) {
            return;
        }
        let result = smtc::listen(move |command| on_command(command.into()));
        if let Err(error) = &result {
            // 注册失败允许下次重试
            LISTENING.store(false, Ordering::SeqCst);
            eprintln!("SMTC 事件注册失败: {error}");
        }
    }

    impl From<smtc::Command> for Command {
        fn from(command: smtc::Command) -> Self {
            match command {
                smtc::Command::Play => Command::Play,
                smtc::Command::Pause => Command::Pause,
                smtc::Command::Next => Command::Next,
                smtc::Command::Previous => Command::Previous,
                smtc::Command::Stop => Command::Stop,
            }
        }
    }

    pub fn acquire() -> Result<bool> {
        crate::single_instance::acquire()
    }

    pub fn signal_existing() -> Result<bool> {
        crate::single_instance::signal_existing()
    }

    pub fn take_activation() -> bool {
        crate::single_instance::take_activation()
    }
}

#[cfg(not(windows))]
mod imp {
    use super::{Command, PlayState};
    use anyhow::{bail, Result};

    pub fn init() -> Result<()> {
        bail!("当前平台不支持系统媒体控制")
    }

    pub fn set_track(
        _title: &str,
        _artist: &str,
        _album: &str,
        _cover_path: Option<&str>,
    ) -> Result<()> {
        bail!("当前平台不支持系统媒体控制")
    }

    pub fn set_state(_state: PlayState) -> Result<()> {
        bail!("当前平台不支持系统媒体控制")
    }

    pub fn clear() -> Result<()> {
        Ok(())
    }

    pub fn listen<F>(_on_command: F)
    where
        F: Fn(Command) + Send + Sync + 'static,
    {
    }

    pub fn acquire() -> Result<bool> {
        Ok(true)
    }

    pub fn signal_existing() -> Result<bool> {
        Ok(false)
    }

    pub fn take_activation() -> bool {
        false
    }
}

pub use imp::{
    acquire, clear, init, listen, set_state, set_track, signal_existing, take_activation,
};

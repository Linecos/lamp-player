//! 非 Windows 平台的空实现：保证 Linux CI 能编译、能跑测试。

use super::{Progress, State};
use anyhow::{bail, Result};

pub fn available() -> bool {
    false
}

pub fn state() -> State {
    State::Stopped
}

fn unsupported<T>() -> Result<T> {
    bail!("BASS 播放引擎仅支持 Windows")
}

pub fn play(_path: &str) -> Result<()> {
    unsupported()
}

pub fn pause() -> Result<()> {
    unsupported()
}

pub fn resume() -> Result<()> {
    unsupported()
}

pub fn stop() -> Result<()> {
    unsupported()
}

pub fn seek(_position_secs: f64) -> Result<()> {
    unsupported()
}

pub fn set_volume(_volume: f64) -> Result<()> {
    unsupported()
}

pub fn snapshot() -> Result<Progress> {
    unsupported()
}

pub fn position() -> Result<f64> {
    unsupported()
}

pub fn duration() -> Result<f64> {
    unsupported()
}

pub fn is_exclusive() -> bool {
    false
}

pub fn set_exclusive(_exclusive: bool) -> Result<()> {
    unsupported()
}

pub fn set_eq(_enabled: bool, _gains: Vec<f32>) -> Result<()> {
    unsupported()
}

pub fn output_info() -> Result<String> {
    Ok("当前平台没有 BASS 输出".to_string())
}

pub fn shutdown() -> Result<()> {
    Ok(())
}

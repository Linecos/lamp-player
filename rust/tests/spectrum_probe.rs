//! 诊断用：确认 `spectrum()` 在真实播放时能拿到非零能量。
//!
//! 单独成文件是为了拿到独立进程——别的测试文件会先初始化引擎，
//! 之后再改 `LAMP_BASS_DEVICE` 就不生效了。
//!
//! **默认跳过**：它会真的出声，也依赖一块能用的声卡（CI 的 windows job 没有）。
//! 需要时手动跑：
//!     LAMP_TEST_AUDIO=1 cargo test --test spectrum_probe -- --nocapture

use rust_lib_lamp_player::api::player::{
    player_is_available, player_play, player_spectrum, player_state, player_stop, PlaybackState,
};
use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

/// 1 kHz 正弦，幅度 0.3，避免太吵
fn write_sine(path: &PathBuf, secs: u32) {
    let sample_rate: u32 = 44100;
    let data_len = sample_rate * secs * 2;
    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    buf.extend_from_slice(&2u16.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    for n in 0..(sample_rate * secs) {
        let t = f64::from(n) / f64::from(sample_rate);
        let sample = 0.3 * (2.0 * std::f64::consts::PI * 1000.0 * t).sin();
        buf.extend_from_slice(&((sample * 32767.0) as i16).to_le_bytes());
    }
    fs::write(path, buf).expect("写入测试音频失败");
}

#[test]
fn spectrum_energy_probe() {
    if !cfg!(windows) {
        return;
    }
    if std::env::var("LAMP_TEST_AUDIO").as_deref() != Ok("1") {
        eprintln!("跳过：需要 LAMP_TEST_AUDIO=1（这条会真的出声）");
        return;
    }
    // 默认设备（-1）：no-sound 模式下 BASS 不做 mixing，FFT 取不到数据
    std::env::set_var("LAMP_BASS_DEVICE", "-1");

    if !player_is_available() {
        eprintln!("跳过：BASS 不可用");
        return;
    }

    let wav = std::env::temp_dir().join("lamp_spectrum_probe.wav");
    write_sine(&wav, 3);
    player_play(wav.to_string_lossy().to_string(), 0.0).expect("播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    let mut peak: f32 = 0.0;
    let mut frames = 0;
    for _ in 0..12 {
        thread::sleep(Duration::from_millis(80));
        match player_spectrum() {
            Ok(bands) => {
                frames += 1;
                let local = bands.iter().cloned().fold(0.0f32, f32::max);
                if local > peak {
                    peak = local;
                }
                eprintln!("第 {frames} 帧：{:?}", &bands[..bands.len().min(8)]);
            }
            Err(error) => eprintln!("取频谱失败：{error}"),
        }
    }

    let _ = player_stop();
    eprintln!("峰值 = {peak}");
    assert!(frames > 0, "一帧都没取到");
    assert!(peak > 0.02, "播放 1kHz 正弦时频谱应非零，实际峰值 {peak}");
}

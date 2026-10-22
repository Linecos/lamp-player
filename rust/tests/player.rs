//! 播放引擎集成测试：加载真实 bass.dll，走一遍播放链路。
//!
//! 用 `LAMP_BASS_DEVICE=0`（无输出设备）初始化，因此不需要声卡，也不会真的出声。

use rust_lib_lamp_player::api::player::{
    player_duration, player_is_available, player_pause, player_play, player_position,
    player_resume, player_seek, player_set_volume, player_state, player_stop, PlaybackState,
};
use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

/// 生成一个 1 秒静音 WAV，避免依赖外部音频文件
fn write_wav(path: &PathBuf, secs: u32) {
    let sample_rate: u32 = 44100;
    let bits: u16 = 16;
    let channels: u16 = 1;
    let data_len = sample_rate * secs * u32::from(bits / 8) * u32::from(channels);

    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&(sample_rate * u32::from(bits / 8) * u32::from(channels)).to_le_bytes());
    buf.extend_from_slice(&(channels * bits / 8).to_le_bytes());
    buf.extend_from_slice(&bits.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    buf.resize(44 + data_len as usize, 0);

    fs::write(path, buf).expect("写入测试音频失败");
}

#[test]
fn playback_chain() {
    if !cfg!(windows) {
        return;
    }
    std::env::set_var("LAMP_BASS_DEVICE", "0");

    if !player_is_available() {
        eprintln!("跳过：BASS 不可用（未下载 bass.dll？）");
        return;
    }

    let wav = std::env::temp_dir().join("lamp_player_test.wav");
    write_wav(&wav, 1);
    let path = wav.to_string_lossy().to_string();

    player_play(path).expect("播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    let duration = player_duration().expect("读取时长");
    assert!(
        (duration - 1.0).abs() < 0.1,
        "时长应约为 1 秒，实际 {duration}"
    );

    thread::sleep(Duration::from_millis(300));
    let position = player_position().expect("读取位置");
    assert!(position > 0.0, "播放 300ms 后位置应大于 0，实际 {position}");

    player_pause().expect("暂停应成功");
    assert_eq!(player_state(), PlaybackState::Paused);

    player_seek(0.5).expect("跳转应成功");
    let position = player_position().expect("跳转后读取位置");
    assert!(
        (position - 0.5).abs() < 0.2,
        "跳转后位置应约 0.5，实际 {position}"
    );

    player_resume().expect("继续播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    player_set_volume(2.0).expect("音量越界应被截断而不报错");
    player_set_volume(0.3).expect("设置音量");

    player_stop().expect("停止应成功");
    assert_eq!(player_state(), PlaybackState::Stopped);
    assert_eq!(player_position().expect("停止后位置"), 0.0);

    let _ = fs::remove_file(wav);
}

#[test]
fn pause_without_track_fails() {
    if !cfg!(windows) {
        return;
    }
    std::env::set_var("LAMP_BASS_DEVICE", "0");
    if !player_is_available() {
        return;
    }

    player_stop().expect("stop 幂等");
    assert!(player_pause().is_err(), "没有曲目时 pause 应报错");
    assert!(player_resume().is_err(), "没有曲目时 resume 应报错");
    assert!(player_seek(1.0).is_err(), "没有曲目时 seek 应报错");
    assert_eq!(player_duration().expect("空载时长"), 0.0);
}

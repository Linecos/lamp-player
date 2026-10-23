//! WASAPI 独占输出的集成测试：需要真实声卡。
//!
//! 无声卡 / 设备被别的进程独占时直接跳过，不把 CI 弄红。
//! 会短暂占用默认输出设备（100~500 ms），测试结束前一定切回共享输出。

use rust_lib_lamp_player::api::player::{
    player_duration, player_is_available, player_is_exclusive, player_output_info, player_pause,
    player_play, player_position, player_resume, player_seek, player_set_exclusive, player_state,
    player_stop, PlaybackState,
};
use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

/// 44.1 kHz 单声道 3 秒静音 WAV：设备多为 48 kHz，正好走一遍 bassmix 重采样
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
fn exclusive_output_chain() {
    if !cfg!(windows) {
        return;
    }
    // 空闲释放要等，测试里调短到 1 秒（必须在引擎线程启动前设置）
    std::env::set_var("LAMP_EXCLUSIVE_IDLE_SECS", "1");
    if !player_is_available() {
        eprintln!("跳过：BASS 不可用（未下载 bass.dll / 无声卡？）");
        return;
    }

    if let Err(error) = player_set_exclusive(true) {
        eprintln!("跳过：设备不支持独占输出（{error}）");
        return;
    }
    assert!(player_is_exclusive(), "切到独占后状态位应为 true");

    let info = player_output_info().expect("读取输出信息");
    eprintln!("独占输出：{info}");
    assert!(info.contains("WASAPI 独占"), "输出信息应说明独占：{info}");

    let wav = std::env::temp_dir().join("lamp_player_exclusive.wav");
    write_wav(&wav, 3);
    let path = wav.to_string_lossy().to_string();

    player_play(path.clone()).expect("独占模式下播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    let duration = player_duration().expect("读取时长");
    assert!(
        (duration - 3.0).abs() < 0.2,
        "时长应约为 3 秒，实际 {duration}"
    );

    thread::sleep(Duration::from_millis(400));
    let played = player_position().expect("读取位置");
    assert!(played > 0.0, "独占播放 400ms 后位置应大于 0，实际 {played}");

    // 暂停期间回调只写静音，不应继续拉流
    player_pause().expect("暂停应成功");
    assert_eq!(player_state(), PlaybackState::Paused);
    let at_pause = player_position().expect("暂停后读取位置");
    thread::sleep(Duration::from_millis(250));
    let after_pause = player_position().expect("暂停 250ms 后读取位置");
    assert!(
        (after_pause - at_pause).abs() < 0.15,
        "暂停期间位置不应前进：{at_pause} -> {after_pause}"
    );

    player_resume().expect("继续播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    player_seek(0.8).expect("独占模式下跳转应成功");
    let after_seek = player_position().expect("跳转后读取位置");
    assert!(
        (after_seek - 0.8).abs() < 0.25,
        "跳转后位置应约 0.8，实际 {after_seek}"
    );

    // 切回共享：曲目与播放状态都应保留
    player_set_exclusive(false).expect("切回共享应成功");
    assert!(!player_is_exclusive(), "切回共享后状态位应为 false");
    assert_eq!(
        player_state(),
        PlaybackState::Playing,
        "切换输出模式不应打断播放"
    );

    // 再切回独占，验证「停止即释放」与「空闲即释放」
    player_set_exclusive(true).expect("再次切到独占应成功");
    assert!(player_is_exclusive());

    // 停止要立刻把设备交还：独占下别的程序才放得出声
    player_stop().expect("停止应成功");
    assert_eq!(player_state(), PlaybackState::Stopped);
    assert!(!player_is_exclusive(), "停止后应释放独占设备，实际仍是独占");

    // 停止后重新播放应能重建会话（而不是一直失败）
    player_play(path.clone()).expect("释放设备后应能重新建立独占会话");
    assert_eq!(player_state(), PlaybackState::Playing);

    assert!(player_is_exclusive(), "重新播放后应再次占用设备");

    // 播完停在末态：空闲 1 秒后自动交还设备
    let short = std::env::temp_dir().join("lamp_player_exclusive_short.wav");
    write_wav(&short, 1);
    player_play(short.to_string_lossy().to_string()).expect("播放短音频");
    thread::sleep(Duration::from_millis(1400));
    assert_eq!(player_state(), PlaybackState::Stopped, "1 秒素材应已播完");
    assert!(
        player_is_exclusive(),
        "刚播完还没到空闲阈值，设备应仍在手上"
    );
    thread::sleep(Duration::from_millis(1200));
    assert!(!player_is_exclusive(), "空闲超过阈值后应把设备交还系统");

    let _ = fs::remove_file(wav);
    let _ = fs::remove_file(short);
}

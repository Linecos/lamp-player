//! 播放引擎集成测试：加载真实 bass.dll，走一遍播放链路。
//!
//! 用 `LAMP_BASS_DEVICE=0`（无输出设备）初始化，因此不需要声卡，也不会真的出声。

use rust_lib_lamp_player::api::player::{
    player_analyze_replay_gain, player_duration, player_is_available, player_pause, player_play,
    player_position, player_resume, player_seek, player_set_equalizer, player_set_volume,
    player_state, player_stop, PlaybackState,
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

/// 生成一个给定幅度的 1 kHz 正弦 WAV：满幅约 -3.7 LUFS
fn write_sine_wav(path: &PathBuf, secs: u32, amplitude: f64) {
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
    for n in 0..(sample_rate * secs) {
        let t = f64::from(n) / f64::from(sample_rate);
        let sample = amplitude * (2.0 * std::f64::consts::PI * 1000.0 * t).sin();
        buf.extend_from_slice(&((sample * 32767.0) as i16).to_le_bytes());
    }

    fs::write(path, buf).expect("写入测试音频失败");
}

/// NaN 会穿透 clamp 并下发到 BASS，让音量永久变哑，必须在入口拒掉。
#[test]
fn volume_rejects_non_finite_values() {
    if !player_is_available() {
        eprintln!("跳过：BASS 不可用");
        return;
    }
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let error = player_set_volume(value).expect_err("非有限音量应被拒绝");
        eprintln!("拒绝 {value}：{error}");
    }
}

/// 均衡器：段数必须为 10，增益必须是有限值；正常设置不应报错。
#[test]
fn equalizer_validates_input() {
    if !player_is_available() {
        eprintln!("跳过：BASS 不可用");
        return;
    }
    let error = player_set_equalizer(true, vec![0.0; 3]).expect_err("段数不足应报错");
    assert!(
        error.to_string().contains("10"),
        "错误信息应说明段数要求：{error}"
    );

    let mut gains = vec![0.0f32; 10];
    gains[0] = f32::NAN;
    let error = player_set_equalizer(true, gains).expect_err("NaN 增益应被拒绝");
    assert!(error.to_string().contains("非法"), "错误信息：{error}");

    player_set_equalizer(true, vec![0.0; 10]).expect("10 段全 0 应成功");
    player_set_equalizer(
        true,
        vec![6.0, 3.0, 0.0, -3.0, -6.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    )
    .expect("带增益应成功");
    player_set_equalizer(false, vec![0.0; 10]).expect("关闭应成功");
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

    player_play(path, 0.0).expect("播放应成功");
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

/// 响度分析：满幅正弦的增益应接近理论值 -14.3 dB（ReplayGain 2.0），
/// 幅度差 20 dB 的两首曲子增益也应差 20 dB。分析不依赖引擎线程与声卡。
#[test]
fn analyze_gain_matches_sine_loudness() {
    if !cfg!(windows) {
        return;
    }
    if !player_is_available() {
        eprintln!("跳过：BASS 不可用（未下载 bass.dll？）");
        return;
    }

    let temp = std::env::temp_dir();
    let loud = temp.join("lamp_player_loud.wav");
    let quiet = temp.join("lamp_player_quiet.wav");
    write_sine_wav(&loud, 2, 0.99);
    write_sine_wav(&quiet, 2, 0.099);

    let loud_gain =
        player_analyze_replay_gain(loud.to_string_lossy().to_string()).expect("分析满幅正弦");
    let quiet_gain =
        player_analyze_replay_gain(quiet.to_string_lossy().to_string()).expect("分析轻幅正弦");

    assert!(
        (-16.0..=-12.0).contains(&loud_gain),
        "满幅正弦增益应约 -14.3 dB，实际 {loud_gain}"
    );
    assert!(
        (quiet_gain - loud_gain - 20.0).abs() < 1.0,
        "幅度差 20 dB 增益也应差 20 dB，实际 {loud_gain} vs {quiet_gain}"
    );

    let _ = fs::remove_file(loud);
    let _ = fs::remove_file(quiet);
}

#[test]
fn analyze_gain_rejects_bad_input() {
    if !cfg!(windows) {
        return;
    }
    if !player_is_available() {
        return;
    }
    assert!(
        player_analyze_replay_gain(String::new()).is_err(),
        "空路径应报错"
    );
    assert!(
        player_analyze_replay_gain("Z:/不存在的曲目.wav".to_string()).is_err(),
        "不存在的文件应报错"
    );
}

/// 自然播完要立刻释放流（否则文件句柄被占住，删 / 改名、移出曲库删文件都会失败），
/// 但时长与位置仍保留末态，界面不会跳回 0:00。
///
/// 默认不跑：播放引擎是进程级单例，和同文件其它用例并行会互相踩状态。
/// 手动验证：`cargo test --test player -- --ignored --test-threads=1`
#[test]
#[ignore = "共享全局播放引擎，需 --test-threads=1 手动跑"]
fn finished_track_releases_stream_and_keeps_ended_position() {
    if !cfg!(windows) {
        return;
    }
    std::env::set_var("LAMP_BASS_DEVICE", "0");
    if !player_is_available() {
        eprintln!("跳过：BASS 不可用");
        return;
    }

    let wav = std::env::temp_dir().join("lamp_player_finished.wav");
    write_wav(&wav, 1);
    let path = wav.to_string_lossy().to_string();

    player_play(path, 0.0).expect("播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    let mut waited = 0;
    while waited < 3000 {
        thread::sleep(Duration::from_millis(100));
        waited += 100;
        if player_state() == PlaybackState::Stopped {
            break;
        }
    }

    assert_eq!(
        player_state(),
        PlaybackState::Stopped,
        "自然播完后状态应为 Stopped"
    );
    let duration = player_duration().expect("读取末态时长");
    let position = player_position().expect("读取末态位置");
    assert!(
        (duration - 1.0).abs() < 0.2,
        "末态时长应保留约 1 秒，实际 {duration}"
    );
    assert!(position > 0.8, "末态位置应停在结尾附近，实际 {position}");
    // 流已释放：此时 seek 会报「没有加载曲目」
    assert!(
        player_seek(0.5).is_err(),
        "播完后流应已释放（seek 应报错），否则文件句柄仍被占用"
    );

    let _ = fs::remove_file(wav);
}

//! WASAPI 独占输出的集成测试：需要真实声卡。
//!
//! 无声卡 / 设备被别的进程独占时直接跳过，不把 CI 弄红。
//! 会短暂占用默认输出设备（100~500 ms），测试结束前一定切回共享输出。
//!
//! **默认跳过**：独占会把正在出声的应用（游戏 / 音乐）从设备上踢下去，
//! 日常 `cargo test` 不该打扰别人听歌。专项验证时设 `LAMP_EXCLUSIVE_TEST=1`
//! 再跑：`LAMP_EXCLUSIVE_TEST=1 cargo test --test exclusive`

use rust_lib_lamp_player::api::player::{
    player_duration, player_is_available, player_is_exclusive, player_output_info, player_pause,
    player_play, player_position, player_resume, player_seek, player_set_exclusive,
    player_spectrum, player_state, player_stop, PlaybackState,
};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

/// 独占设备同一时间只能被一个测试占住：并行跑会互相把对方踢下设备，
/// 表现为 `player_is_exclusive()` 变成 false。用例之间串行一下。
static DEVICE: Mutex<()> = Mutex::new(());

/// 44.1 kHz 单声道 16 bit 静音 WAV：设备多为 48 kHz，正好走一遍 bassmix 重采样
fn write_wav(path: &PathBuf, secs: u32) {
    write_wav_ex(path, secs, 44_100, 1);
}

/// 指定采样率与声道的静音 WAV。
///
/// 真实音乐基本都是立体声：单声道可能绕过源流到混音流之间的声道映射，
/// 单独跑一条立体声用例才接近用户实际听到的那条路。
fn write_wav_ex(path: &PathBuf, secs: u32, sample_rate: u32, channels: u16) {
    let bits: u16 = 16;
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

/// 指定频率的正弦 WAV（立体声 16 bit）。
///
/// 频谱用例不能用静音素材：静音的 FFT 恒为 0，测不出「有没有频谱」。
/// 幅度压到 0.02（约 -34 dB），跑测试时基本听不见。
fn write_tone_wav(path: &PathBuf, secs: u32, freq: f32, amp: f32) {
    let sample_rate: u32 = 44_100;
    let channels: u16 = 2;
    let bits: u16 = 16;
    let frames = sample_rate * secs;
    let data_len = frames * u32::from(channels) * u32::from(bits / 8);

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
    let tau = std::f32::consts::PI * 2.0;
    for frame in 0..frames {
        let phase = tau * freq * frame as f32 / sample_rate as f32;
        let value = (amp * phase.sin() * f32::from(i16::MAX)) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&value.to_le_bytes());
        }
    }
    fs::write(path, buf).expect("写入测试音频失败");
}

#[test]
fn exclusive_output_chain() {
    if !cfg!(windows) {
        return;
    }
    let _device = DEVICE.lock().unwrap_or_else(|error| error.into_inner());
    // 默认跳过：独占几秒会让游戏 / 音乐当场没声（见文件头说明）
    if std::env::var("LAMP_EXCLUSIVE_TEST").as_deref() != Ok("1") {
        eprintln!("跳过：独占测试会短暂抢占声卡；专项验证时设 LAMP_EXCLUSIVE_TEST=1");
        return;
    }
    // 空闲释放要等，测试里调短到 1 秒（必须在引擎线程启动前设置）
    std::env::set_var("LAMP_EXCLUSIVE_IDLE_SECS", "2");
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
    // 立体声：单声道素材可能绕过一条声道映射，测不到真实音乐那条路
    write_wav_ex(&wav, 3, 44_100, 2);
    let path = wav.to_string_lossy().to_string();

    player_play(path.clone(), 0.0).expect("独占模式下播放应成功");
    assert_eq!(player_state(), PlaybackState::Playing);

    let duration = player_duration().expect("读取时长");
    assert!(
        (duration - 3.0).abs() < 0.2,
        "时长应约为 3 秒，实际 {duration}"
    );

    thread::sleep(Duration::from_millis(400));
    let played = player_position().expect("读取位置");
    assert!(played > 0.0, "独占播放 400ms 后位置应大于 0，实际 {played}");

    // 播放速率必须接近 1.0：44.1k 素材在 48k 设备上如果直接拉源流
    // （绕过 bassmix 重采样）会跑成 48/44.1 ≈ 1.088 倍速，音调也偏高。
    let rate_start = std::time::Instant::now();
    let pos_start = player_position().expect("读取起始位置");
    thread::sleep(Duration::from_millis(1200));
    let pos_end = player_position().expect("读取结束位置");
    let elapsed = rate_start.elapsed().as_secs_f64();
    let rate = (pos_end - pos_start) / elapsed;
    eprintln!("独占实测播放速率 {rate:.3}x（1.0 = 正常；1.088 = 按 48k 读 44.1k 素材）");
    assert!(
        (rate - 1.0).abs() < 0.05,
        "独占模式播放速率应接近 1.0，实际 {rate:.3}（源流未经过混音流重采样？）"
    );

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
    player_play(path.clone(), 0.0).expect("释放设备后应能重新建立独占会话");
    assert_eq!(player_state(), PlaybackState::Playing);

    assert!(player_is_exclusive(), "重新播放后应再次占用设备");

    // 播完停在末态：空闲 1 秒后自动交还设备
    let short = std::env::temp_dir().join("lamp_player_exclusive_short.wav");
    write_wav(&short, 1);
    player_play(short.to_string_lossy().to_string(), 0.0).expect("播放短音频");
    // 轮询等它播完：固定 sleep 在慢机器上会越过空闲阈值，造成假失败
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while player_state() != PlaybackState::Stopped && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(player_state(), PlaybackState::Stopped, "1 秒素材应已播完");
    assert!(
        player_is_exclusive(),
        "刚播完还没到空闲阈值，设备应仍在手上"
    );
    thread::sleep(Duration::from_millis(2600));
    assert!(!player_is_exclusive(), "空闲超过阈值后应把设备交还系统");

    let _ = fs::remove_file(wav);
    let _ = fs::remove_file(short);
}

/// 频谱不能把播放拖快。
///
/// 独占输出的 mixer 是解码流（`BASS_STREAM_DECODE`），`BASS_ChannelGetData`
/// 取 FFT 时会把采样一并取走、解码位置跟着前进；而 WASAPI 回调正是从同一条
/// 流里拉数据。两边一起拉 → 输出欠载：播放变快（每 33ms 偷 1024 采样）、
/// 还带电流声。共享输出没这问题：那时不建 mixer，频谱走的是普通播放流。
#[test]
fn spectrum_does_not_speed_up_playback() {
    if !cfg!(windows) {
        return;
    }
    let _device = DEVICE.lock().unwrap_or_else(|error| error.into_inner());
    if std::env::var("LAMP_EXCLUSIVE_TEST").as_deref() != Ok("1") {
        eprintln!("跳过：独占测试会短暂抢占声卡；专项验证时设 LAMP_EXCLUSIVE_TEST=1");
        return;
    }
    std::env::set_var("LAMP_EXCLUSIVE_IDLE_SECS", "2");
    if !player_is_available() {
        eprintln!("跳过：BASS 不可用（未下载 bass.dll / 无声卡？）");
        return;
    }
    if let Err(error) = player_set_exclusive(true) {
        eprintln!("跳过：设备不支持独占输出（{error}）");
        return;
    }

    let wav = std::env::temp_dir().join("lamp_player_spectrum.wav");
    write_tone_wav(&wav, 6, 440.0, 0.02);
    player_play(wav.to_string_lossy().to_string(), 0.0).expect("独占模式下播放应成功");
    thread::sleep(Duration::from_millis(300));

    // 2 秒里按引擎的推流节奏取频谱（33ms 一帧），同时看位置走了多少
    let started = std::time::Instant::now();
    let pos_start = player_position().expect("读取起始位置");
    let mut loudest = 0.0f32;
    for _ in 0..60 {
        if let Ok(bands) = player_spectrum() {
            for band in bands {
                if band > loudest {
                    loudest = band;
                }
            }
        }
        thread::sleep(Duration::from_millis(33));
    }
    let pos_end = player_position().expect("读取结束位置");
    let elapsed = started.elapsed().as_secs_f64();
    let rate = (pos_end - pos_start) / elapsed;
    eprintln!("取频谱时的独占播放速率 {rate:.3}x（1.0 = 正常）");

    assert!(
        (rate - 1.0).abs() < 0.08,
        "取频谱不能让播放变快，实际 {rate:.3}（频谱在消费解码流的数据？）"
    );
    // 独占下也要有波形：回调把 PCM 抄进了环形缓冲，频谱自己算 FFT。
    // 0.02 幅度的正弦经 `sqrt(peak * lift)` 后约 0.1，留足余量取 0.02
    eprintln!("频谱最响一段 {loudest:.3}");
    assert!(
        loudest > 0.02,
        "独占输出下频谱不应全为 0，实际最响 {loudest:.3}"
    );

    player_stop().expect("停止应成功");
    let _ = fs::remove_file(wav);
}

//! ReplayGain 标签写入：写进去的增益要能被 lofty 回读、被扫描入库读回。

use lofty::file::TaggedFileExt;
use rust_lib_lamp_player::api::{db, player, replaygain, scan};
use std::fs;
use std::path::{Path, PathBuf};

/// 生成 0.5 秒 8kHz 单声道 16bit 静音 WAV（lofty 能解析时长，初始无标签）
fn write_wav(path: &Path, secs: f64) {
    let sample_rate: u32 = 8000;
    let samples = (f64::from(sample_rate) * secs) as u32;
    let data_len = samples * 2;

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
    buf.resize(44 + data_len as usize, 0);
    fs::write(path, buf).expect("写入测试音频失败");
}

fn unique_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "lamp_rg_{tag}_{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).expect("创建临时目录");
    dir
}

/// 无标签的 WAV 也要能建标签写进去，并且按 "-7.23 dB" 的文本格式落盘。
#[test]
fn writes_track_gain_into_untagged_file() {
    let dir = unique_dir("write");
    let song = dir.join("无标签.wav");
    write_wav(&song, 0.5);
    let path = song.to_string_lossy().into_owned();

    replaygain::write_replay_gain(path.clone(), -7.234).expect("写入应成功");

    let tagged = lofty::read_from_path(&song).expect("读取测试音频");
    let tag = tagged.primary_tag().expect("写入后应存在标签");
    let raw = tag
        .get_string(lofty::tag::ItemKey::ReplayGainTrackGain)
        .expect("应读到 ReplayGain 增益");
    assert_eq!(raw, "-7.23 dB", "落盘格式应与扫描解析的口径一致");

    fs::remove_dir_all(&dir).ok();
}

/// 重复写入覆盖旧值；超出 ±24 dB 的离谱值要被夹回范围。
#[test]
fn overwrites_and_clamps_out_of_range_gain() {
    let dir = unique_dir("clamp");
    let song = dir.join("带增益.wav");
    write_wav(&song, 0.5);
    let path = song.to_string_lossy().into_owned();

    replaygain::write_replay_gain(path.clone(), -3.0).expect("首次写入");
    replaygain::write_replay_gain(path, 60.0).expect("覆盖写入");

    let tagged = lofty::read_from_path(&song).expect("读取测试音频");
    let tag = tagged.primary_tag().expect("应存在标签");
    let raw = tag
        .get_string(lofty::tag::ItemKey::ReplayGainTrackGain)
        .expect("应读到 ReplayGain 增益");
    assert_eq!(raw, "24.00 dB", "越界值应夹到 +24 dB");
    assert_eq!(
        tag.get_string(lofty::tag::ItemKey::ReplayGainTrackGain)
            .unwrap()
            .matches("dB")
            .count(),
        1,
        "只应有一条增益"
    );

    fs::remove_dir_all(&dir).ok();
}

/// 写入后重新扫描，曲库里的 `replay_gain` 要跟着变成新值。
#[test]
fn rescan_picks_up_written_gain() {
    let dir = unique_dir("rescan");
    let music = dir.join("music");
    fs::create_dir_all(&music).expect("创建音乐目录");
    let song = music.join("曲子.wav");
    write_wav(&song, 0.5);

    db::init_db(dir.join("library.db").to_string_lossy().into_owned()).expect("初始化曲库");
    let first = scan::scan_folder(music.to_string_lossy().into_owned()).expect("首次扫描");
    assert_eq!(first.upserted, 1);
    assert!(
        db::all_tracks().expect("读取曲库")[0].replay_gain.abs() < f64::EPSILON,
        "无标签时增益应为 0"
    );

    replaygain::write_replay_gain(song.to_string_lossy().into_owned(), -7.23).expect("写入增益");
    let second = scan::scan_folder(music.to_string_lossy().into_owned()).expect("再扫描");
    assert_eq!(second.upserted, 1, "改过标签的文件应重新解析入库");
    let gain = db::all_tracks().expect("读取曲库")[0].replay_gain;
    assert!(
        (gain + 7.23).abs() < 0.01,
        "重扫后增益应约为 -7.23，实际 {gain}"
    );

    db::close_db().expect("关闭曲库");
    fs::remove_dir_all(&dir).ok();
}

#[test]
fn rejects_bad_input() {
    assert!(
        replaygain::write_replay_gain(String::new(), 1.0).is_err(),
        "空路径应报错"
    );
    assert!(
        replaygain::write_replay_gain("Z:/不存在的曲目.wav".to_string(), 1.0).is_err(),
        "不存在的文件应报错"
    );
    let dir = unique_dir("nan");
    let song = dir.join("nan.wav");
    write_wav(&song, 0.2);
    assert!(
        replaygain::write_replay_gain(song.to_string_lossy().into_owned(), f64::NAN).is_err(),
        "NaN 增益应被拒绝"
    );
    fs::remove_dir_all(&dir).ok();
}

/// 真实解码链路：进程里从未初始过 BASS 时也要能分析。
///
/// 需要本机音频样本与 BASS DLL，CI 上没有，所以默认跳过：
///
/// ```text
/// LAMP_RG_SAMPLE="D:\music\a.flac" cargo test --test replaygain -- --ignored
/// ```
///
/// 盯的是两条曾经同时踩中的路径：引擎没起来时 `BASS_StreamCreateFile` 直接报
/// 错误 8「BASS_Init 尚未成功调用」；插件用裸文件名 + ANSI flags 注册则全部失败。
/// 二者叠加时，FLAC / OPUS / AAC / APE / WMA 一个都解不开。
#[test]
#[ignore = "需要 LAMP_RG_SAMPLE 指向真实音频文件（含 BASS 环境）"]
fn analyzes_real_file_without_engine() {
    let sample = std::env::var("LAMP_RG_SAMPLE").expect("需要 LAMP_RG_SAMPLE 环境变量");
    let gain = player::player_analyze_replay_gain(sample.clone())
        .unwrap_or_else(|error| panic!("{sample} 应能分析：{error}"));
    assert!(gain.abs() <= 24.0, "增益应夹在 ±24 dB 内，实际 {gain}");
    assert!(gain != 0.0, "非静音文件不应算出 0 dB");
}

//! 扫描链路测试：目录遍历 → 标签解析 → 入库 → 检索。
//!
//! 用例自己生成最小可解析的 WAV（无标签），所以不依赖仓库里带音频样本。

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rust_lib_lamp_player::api::{db, scan};
use rust_lib_lamp_player::scanner;

/// 生成一个 0.5 秒、8kHz、单声道 16bit 的静音 WAV（lofty 能解析时长，无标签）
fn write_wav(path: &Path, seconds: f32) {
    let sample_rate: u32 = 8_000;
    let channels: u16 = 1;
    let bits: u16 = 16;
    let block_align = channels * (bits / 8);
    let sample_count = (sample_rate as f32 * seconds) as u32;
    let data_len = sample_count * u32::from(block_align);

    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVE");
    bytes.extend_from_slice(b"fmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
    bytes.extend_from_slice(&channels.to_le_bytes());
    bytes.extend_from_slice(&sample_rate.to_le_bytes());
    bytes.extend_from_slice(&(sample_rate * u32::from(block_align)).to_le_bytes());
    bytes.extend_from_slice(&block_align.to_le_bytes());
    bytes.extend_from_slice(&bits.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    bytes.resize(44 + data_len as usize, 0);

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("创建测试目录");
    }
    fs::write(path, bytes).expect("写入 wav");
}

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "lamp_scan_{}_{}_{}",
        tag,
        std::process::id(),
        nanos
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("创建临时目录");
    dir
}

#[test]
fn collects_audio_recursively_and_ignores_other_files() {
    let root = unique_dir("collect");
    write_wav(&root.join("a.wav"), 0.5);
    write_wav(&root.join("sub").join("b.WAV"), 1.0); // 扩展名大小写不敏感
    fs::write(root.join("notes.txt"), b"not audio").unwrap();
    fs::write(root.join("sub").join("cover.jpg"), b"not audio").unwrap();

    let collected = scanner::collect_tracks(&root).expect("扫描应成功");

    assert_eq!(collected.scanned, 2, "只统计命中扩展名的文件");
    assert_eq!(collected.failed, 0);
    assert_eq!(collected.tracks.len(), 2);

    let mut titles: Vec<&str> = collected.tracks.iter().map(|t| t.title.as_str()).collect();
    titles.sort_unstable();
    assert_eq!(titles, vec!["a", "b"], "无标签时用文件名兜底");

    for track in &collected.tracks {
        assert!(track.path.ends_with(".wav") || track.path.ends_with(".WAV"));
        assert!(track.duration_secs > 0.4, "时长应被解析出来");
        assert!(track.added_at > 0);
        assert!(track.artist.is_none());
    }

    fs::remove_dir_all(&root).ok();
}

#[test]
fn missing_directory_is_an_error() {
    let missing = std::env::temp_dir().join("lamp_scan_definitely_missing_dir");
    assert!(scanner::collect_tracks(&missing).is_err());
}

#[test]
fn scan_folder_upserts_and_search_finds_tracks() {
    // 全局连接只能初始化一次，所以这里独占一个测试文件里的 DB 用例
    let root = unique_dir("pipeline");
    let db_path = root.join("library.lampdb");
    db::init_db(db_path.to_string_lossy().into_owned()).expect("初始化曲库");

    let music = root.join("music");
    write_wav(&music.join("本地音乐.wav"), 0.5);

    let report = scan::scan_folder(music.to_string_lossy().into_owned()).expect("扫描应成功");
    assert_eq!(report.scanned, 1);
    assert_eq!(report.upserted, 1);
    assert_eq!(report.failed, 0);
    assert!(report.elapsed_ms >= 0);

    let tracks = db::all_tracks().expect("读取曲库");
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].title, "本地音乐");

    // FTS5 对 CJK 不分词，只能前缀匹配：搜「本地」能命中
    let hits = db::search_tracks("本地".to_string(), 10).expect("检索");
    assert_eq!(hits.len(), 1, "中文前缀应命中");

    // 再扫一次不应产生重复记录
    let again = scan::scan_folder(music.to_string_lossy().into_owned()).expect("重复扫描");
    assert_eq!(again.upserted, 1);
    assert_eq!(db::all_tracks().expect("读取曲库").len(), 1);

    fs::remove_dir_all(&root).ok();
    for suffix in ["", "-wal", "-shm"] {
        fs::remove_file(format!("{}{}", db_path.display(), suffix)).ok();
    }
}

//! 歌词读取测试：`.lrc` 旁载优先、内嵌标签兜底、没有歌词时返回空结构。

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use rust_lib_lamp_player::api::lyrics::lyrics_load;

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "lamp_lyrics_{}_{}_{}",
            tag,
            std::process::id(),
            nanos
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("创建临时目录");
        Self(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// 44.1 kHz 单声道 0.2 秒静音 WAV
fn write_wav(path: &PathBuf) {
    let sample_rate: u32 = 44100;
    let bits: u16 = 16;
    let data_len = sample_rate / 5 * u32::from(bits / 8);
    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&(sample_rate * u32::from(bits / 8)).to_le_bytes());
    buf.extend_from_slice(&(bits / 8).to_le_bytes());
    buf.extend_from_slice(&bits.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    buf.resize(44 + data_len as usize, 0);
    fs::write(path, buf).expect("写入测试音频");
}

#[test]
fn sidecar_lrc_wins_over_embedded() {
    let dir = TempDir::new("sidecar");
    let song = dir.0.join("夜航.wav");
    write_wav(&song);
    fs::write(
        song.with_extension("lrc"),
        "[ti:夜航]\n[00:01.20]第一行\n[00:04.00]第二行\n",
    )
    .expect("写入 lrc");

    let lyrics = lyrics_load(song.to_string_lossy().into_owned()).expect("读取歌词");
    assert_eq!(lyrics.source, "sidecar");
    assert_eq!(lyrics.lines.len(), 2);
    assert_eq!(lyrics.lines[0].time_ms, 1200);
    assert_eq!(lyrics.lines[1].text, "第二行");
    assert!(lyrics.plain.is_empty());
}

#[test]
fn reads_embedded_unsynchronized_lyrics() {
    use lofty::config::WriteOptions;
    use lofty::prelude::{Accessor, ItemKey, TagExt};
    use lofty::tag::{Tag, TagType};

    let dir = TempDir::new("embedded");
    let song = dir.0.join("内嵌.wav");
    write_wav(&song);

    let mut tag = Tag::new(TagType::Id3v2);
    tag.set_title("内嵌".to_string());
    tag.insert_text(ItemKey::UnsyncLyrics, "第一段\n第二段".to_string());
    tag.save_to_path(&song, WriteOptions::default())
        .expect("写入内嵌歌词");

    let lyrics = lyrics_load(song.to_string_lossy().into_owned()).expect("读取歌词");
    assert_eq!(lyrics.source, "embedded");
    assert!(lyrics.lines.is_empty(), "无时间轴时应走 plain");
    assert_eq!(lyrics.plain, "第一段\n第二段");
}

#[test]
fn missing_lyrics_is_not_an_error() {
    let dir = TempDir::new("none");
    let song = dir.0.join("纯音乐.wav");
    write_wav(&song);

    let lyrics = lyrics_load(song.to_string_lossy().into_owned()).expect("没有歌词也应成功");
    assert_eq!(lyrics.source, "none");
    assert!(lyrics.lines.is_empty());
    assert!(lyrics.plain.is_empty());
}

#[test]
fn utf16_sidecar_is_decoded() {
    let dir = TempDir::new("utf16");
    let song = dir.0.join("gbk.wav");
    write_wav(&song);
    let mut bytes = vec![0xFF, 0xFE];
    for unit in "[00:02.00]中文歌词".encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    fs::write(song.with_extension("lrc"), bytes).expect("写入 utf16 lrc");

    let lyrics = lyrics_load(song.to_string_lossy().into_owned()).expect("读取歌词");
    assert_eq!(lyrics.lines.len(), 1);
    assert_eq!(lyrics.lines[0].text, "中文歌词");
}

#[test]
fn sidecar_with_inline_words_and_translation() {
    // 国内音乐软件导出的「原文 + 音译 + 翻译」三行结构
    let dir = TempDir::new("words");
    let song = dir.0.join("逐字.wav");
    write_wav(&song);
    fs::write(
        song.with_extension("lrc"),
        "[00:05.691]大[00:06.365]人[00:06.582]は\n\
         [00:05.691]o to na wa\n\
         [00:05.691]大人是啊\n\
         [00:09.019]次[00:09.500]の\n",
    )
    .expect("写入逐字 lrc");

    let lyrics = lyrics_load(song.to_string_lossy().into_owned()).expect("读取歌词");
    assert_eq!(lyrics.source, "sidecar");
    assert_eq!(lyrics.lines.len(), 2, "同时间戳的三行要合并成一行");
    let first = &lyrics.lines[0];
    assert_eq!(first.text, "大人は");
    assert_eq!(first.words.len(), 3);
    assert_eq!(first.words[2].time_ms, 6_582);
    assert_eq!(first.translation, "o to na wa\n大人是啊");
    assert_eq!(first.end_ms, 9_019);
    assert_eq!(lyrics.lines[1].words.len(), 2);
}

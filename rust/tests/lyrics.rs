//! 歌词读取测试：旁载 `.lrc` 与内嵌标签两种来源、优先级顺序、没有歌词时返回空结构。

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

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读取歌词");
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

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读取歌词");
    assert_eq!(lyrics.source, "embedded");
    assert!(lyrics.lines.is_empty(), "无时间轴时应走 plain");
    assert_eq!(lyrics.plain, "第一段\n第二段");
}

#[test]
fn missing_lyrics_is_not_an_error() {
    let dir = TempDir::new("none");
    let song = dir.0.join("纯音乐.wav");
    write_wav(&song);

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("没有歌词也应成功");
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

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读取歌词");
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

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读取歌词");
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

#[test]
fn sidecar_target_writes_the_lrc_file() {
    use rust_lib_lamp_player::api::lyrics::lyrics_save_raw;

    let dir = TempDir::new("save_sidecar");
    let song = dir.0.join("旁载.wav");
    write_wav(&song);

    let written = lyrics_save_raw(
        song.to_string_lossy().into_owned(),
        "[00:01.00]第一行\n".to_string(),
        "sidecar".to_string(),
    )
    .expect("写入旁载");
    assert_eq!(written, song.with_extension("lrc").to_string_lossy());

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读回");
    assert_eq!(lyrics.source, "sidecar");
    assert_eq!(lyrics.lines.len(), 1);
}

#[test]
fn embedded_target_writes_into_the_audio_file() {
    use rust_lib_lamp_player::api::lyrics::lyrics_save_raw;

    let dir = TempDir::new("save_embedded");
    let song = dir.0.join("内嵌写.wav");
    write_wav(&song);
    let lrc = song.with_extension("lrc");

    lyrics_save_raw(
        song.to_string_lossy().into_owned(),
        "[00:02.50]写进文件\n".to_string(),
        "embedded".to_string(),
    )
    .expect("写入内嵌");

    assert!(!lrc.exists(), "选了内嵌就不该再生成 .lrc");
    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读回");
    assert_eq!(lyrics.source, "embedded");
    assert_eq!(lyrics.lines.len(), 1);
    assert_eq!(lyrics.lines[0].time_ms, 2_500);
    assert_eq!(lyrics.lines[0].text, "写进文件");
}

#[test]
fn embedded_target_refreshes_an_existing_sidecar() {
    use rust_lib_lamp_player::api::lyrics::lyrics_save_raw;

    let dir = TempDir::new("embedded_sidecar");
    let song = dir.0.join("两边都有.wav");
    write_wav(&song);
    let lrc = song.with_extension("lrc");
    fs::write(&lrc, "[00:01.00]旧旁载\n").expect("写入旧 lrc");

    lyrics_save_raw(
        song.to_string_lossy().into_owned(),
        "[00:03.00]新的\n".to_string(),
        "embedded".to_string(),
    )
    .expect("写入内嵌");

    // 旁载优先：不刷新的话读出来还是「旧旁载」，等于这次保存白做
    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读回");
    assert_eq!(lyrics.source, "sidecar");
    assert_eq!(lyrics.lines[0].text, "新的");
    assert!(fs::read_to_string(&lrc).expect("读 lrc").contains("新的"));
}

/// 两边都有歌词：`embedded_first` 换顺序，内容跟着换
#[test]
fn embedded_first_flips_the_source_order() {
    use lofty::config::WriteOptions;
    use lofty::prelude::{ItemKey, TagExt};
    use lofty::tag::{Tag, TagType};

    let dir = TempDir::new("order");
    let song = dir.0.join("两边.wav");
    write_wav(&song);
    fs::write(song.with_extension("lrc"), "[00:01.00]旁载行\n").expect("写入 lrc");

    let mut tag = Tag::new(TagType::Id3v2);
    tag.insert_text(ItemKey::UnsyncLyrics, "内嵌段落".to_string());
    tag.save_to_path(&song, WriteOptions::default())
        .expect("写入内嵌");

    let sidecar_first = lyrics_load(song.to_string_lossy().into_owned(), false).expect("读取");
    assert_eq!(sidecar_first.source, "sidecar");
    assert_eq!(sidecar_first.lines[0].text, "旁载行");
    assert!(sidecar_first.plain.is_empty());

    let embedded_first = lyrics_load(song.to_string_lossy().into_owned(), true).expect("读取");
    assert_eq!(embedded_first.source, "embedded");
    assert!(embedded_first.lines.is_empty());
    assert_eq!(embedded_first.plain, "内嵌段落");
}

/// 先试的那一边没有能用的歌词时退给另一边，不会变成「没歌词」
#[test]
fn embedded_first_falls_back_to_sidecar_when_tag_is_empty() {
    let dir = TempDir::new("order_fallback");
    let song = dir.0.join("只有旁载.wav");
    write_wav(&song);
    fs::write(song.with_extension("lrc"), "[00:01.00]旁载行\n").expect("写入 lrc");

    let lyrics = lyrics_load(song.to_string_lossy().into_owned(), true).expect("读取");
    assert_eq!(lyrics.source, "sidecar");
    assert_eq!(lyrics.lines[0].text, "旁载行");
}

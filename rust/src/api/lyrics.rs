//! 歌词读取：同目录 `.lrc` 优先，其次音频内嵌标签。另提供编辑用的原文
//! 读写与「整体平移时间戳」。

use crate::lyrics as core;
use anyhow::Result;
use std::path::Path;

/// 一个逐字片段（时间标签之间的文本）
pub struct LyricWord {
    /// 起始时间（毫秒）
    pub time_ms: i64,
    pub text: String,
}

/// 一行带时间戳的歌词
pub struct LyricLine {
    /// 起始时间（毫秒）
    pub time_ms: i64,
    /// 结束时间（毫秒）
    pub end_ms: i64,
    pub text: String,
    /// 逐字时间轴；为空表示整行按行级时间轴处理
    pub words: Vec<LyricWord>,
    /// 同一时间戳的其余行（罗马音 / 翻译），`\n` 分隔
    pub translation: String,
}

/// 一次歌词读取的结果
pub struct TrackLyrics {
    /// 按时间升序；没有时间戳时为空
    pub lines: Vec<LyricLine>,
    /// 无时间轴的纯文本（内嵌歌词常见）
    pub plain: String,
    /// 来源：`sidecar` / `embedded` / `none`
    pub source: String,
}

/// 读取曲目歌词。
///
/// 没有歌词是正常情况（返回空结构，`source` 为 `none`），不报错；
/// 只有路径本身不可读时才返回错误。
pub fn lyrics_load(path: String) -> Result<TrackLyrics> {
    let lyrics = core::load(Path::new(&path))?;
    Ok(TrackLyrics {
        lines: lyrics
            .lines
            .into_iter()
            .map(|line| LyricLine {
                time_ms: line.time_ms,
                end_ms: line.end_ms,
                text: line.text,
                words: line
                    .words
                    .into_iter()
                    .map(|word| LyricWord {
                        time_ms: word.time_ms,
                        text: word.text,
                    })
                    .collect(),
                translation: line.translation,
            })
            .collect(),
        plain: lyrics.plain,
        source: lyrics.source,
    })
}

/// 编辑用的歌词原文。
pub struct RawLyrics {
    /// 原文（LRC / TTML 原样，没有歌词时为空字符串）
    pub text: String,
    /// 来源：`sidecar`（同名 `.lrc` / `.ttml`）/ `embedded`（音频标签）/ `none`
    pub source: String,
}

/// 读取歌词原文：旁载优先，其次内嵌。没有歌词返回空结构，不报错。
pub fn lyrics_read_raw(path: String) -> Result<RawLyrics> {
    match core::raw_text(Path::new(&path)) {
        Some((text, source)) => Ok(RawLyrics {
            text,
            source: source.to_string(),
        }),
        None => Ok(RawLyrics {
            text: String::new(),
            source: "none".to_string(),
        }),
    }
}

/// 整体平移歌词时间戳（单位毫秒，负数提前 / 正数延后），返回新文本。
///
/// 纯文本变换，不碰文件——界面先调它把新文本显示出来，用户确认后再
/// [`lyrics_save_raw`] 落盘，这样「快进多少」是看得见的。
pub fn lyrics_shift_raw(text: String, delta_ms: i64) -> String {
    core::shift_timestamps(&text, delta_ms)
}

/// 保存歌词原文为同名 `.lrc`（UTF-8），返回写入的文件路径。
///
/// 统一写旁载：改内嵌标签要重写整个音频文件，风险与代价都大得多。
/// 原本只有内嵌歌词的曲目，保存后也会有 `.lrc`——读取侧旁载优先，行为一致。
pub fn lyrics_save_raw(path: String, text: String) -> Result<String> {
    let written = core::write_sidecar(Path::new(&path), &text)?;
    Ok(written.to_string_lossy().into_owned())
}

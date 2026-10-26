//! 歌词读取：同目录 `.lrc` 优先，其次音频内嵌标签。

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

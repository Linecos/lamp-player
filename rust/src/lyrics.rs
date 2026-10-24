//! 歌词：优先读同目录同名 `.lrc`，其次读音频内嵌标签。
//!
//! 只做「拿到文本并解析时间轴」，不联网、不猜歌词。没有时间戳的纯文本歌词
//! 放在 `plain` 里，界面原样滚动显示。

use anyhow::Result;
use lofty::config::ParseOptions;
use lofty::file::TaggedFileExt;
use lofty::prelude::ItemKey;
use lofty::probe::Probe;
use std::path::Path;

/// 一行带时间戳的歌词
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LyricLine {
    /// 起始时间（毫秒）
    pub time_ms: i64,
    pub text: String,
}

/// 一次歌词读取的结果
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Lyrics {
    /// 按时间升序；没有时间戳时为空
    pub lines: Vec<LyricLine>,
    /// 无时间轴的纯文本（内嵌歌词常见）；有时间轴时通常为空
    pub plain: String,
    /// 来源：`sidecar` / `embedded` / `none`
    pub source: String,
}

impl Lyrics {
    fn empty() -> Self {
        Self {
            lines: Vec::new(),
            plain: String::new(),
            source: "none".to_string(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty() && self.plain.trim().is_empty()
    }
}

/// 读取歌词：[音频路径] 旁的 `.lrc` 优先，其次内嵌。
pub fn load(audio: &Path) -> Result<Lyrics> {
    if let Some(text) = read_sidecar(audio) {
        let mut lyrics = parse_lrc(&text);
        if !lyrics.is_empty() {
            lyrics.source = "sidecar".to_string();
            return Ok(lyrics);
        }
    }

    match read_embedded(audio) {
        Ok(Some(text)) => {
            let mut lyrics = parse_lrc(&text);
            if lyrics.is_empty() {
                // 没有时间戳：交给界面当纯文本显示
                lyrics.plain = text.trim().to_string();
            }
            lyrics.source = "embedded".to_string();
            Ok(lyrics)
        }
        // 解析失败（文件损坏/格式不支持）等同于没有歌词，不让调用方报错
        _ => Ok(Lyrics::empty()),
    }
}

/// 同目录同名 `.lrc`（大小写不敏感地尝试两种扩展名）
fn read_sidecar(audio: &Path) -> Option<String> {
    let lrc = audio.with_extension("lrc");
    if let Ok(text) = std::fs::read(&lrc) {
        return Some(decode_text(&text));
    }
    let upper = audio.with_extension("LRC");
    std::fs::read(upper).ok().map(|bytes| decode_text(&bytes))
}

/// LRC 常见 UTF-8；带 BOM 的 UTF-8 与 UTF-16 也顺手处理
fn decode_text(bytes: &[u8]) -> String {
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
        let little_endian = bytes[0] == 0xFF;
        let data = &bytes[2..];
        let units: Vec<u16> = data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| {
                if little_endian {
                    u16::from_le_bytes(*pair)
                } else {
                    u16::from_be_bytes(*pair)
                }
            })
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    }
}

fn read_embedded(audio: &Path) -> Result<Option<String>> {
    let tagged = Probe::open(audio)?.options(ParseOptions::new()).read()?;
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(None);
    };
    // 同步歌词优先，其次无时间轴歌词
    let text = tag
        .get_string(ItemKey::Lyrics)
        .or_else(|| tag.get_string(ItemKey::UnsyncLyrics))
        .map(str::to_string);
    Ok(text)
}

/// 解析 LRC：支持一行多个时间戳、`[mm:ss.xx]` / `[mm:ss:xx]`，忽略元数据标签
pub fn parse_lrc(text: &str) -> Lyrics {
    let mut lines: Vec<LyricLine> = Vec::new();
    let mut plain_lines: Vec<String> = Vec::new();
    let mut saw_timestamp = false;

    for raw in text.lines() {
        let mut rest = raw.trim();
        if rest.is_empty() {
            continue;
        }
        let mut stamps: Vec<i64> = Vec::new();
        while let Some(stripped) = rest.strip_prefix('[') {
            let Some(end) = stripped.find(']') else {
                break;
            };
            let inner = &stripped[..end];
            match parse_timestamp(inner) {
                Some(ms) => {
                    stamps.push(ms);
                    rest = &stripped[end + 1..];
                }
                // [ar:xxx] / [ti:xxx] 这类元数据：整行跳过
                None => {
                    if inner.contains(':')
                        && !inner.contains('.')
                        && inner
                            .chars()
                            .all(|c| c.is_ascii_alphabetic() || c == ':' || c.is_whitespace())
                    {
                        rest = "";
                    }
                    break;
                }
            }
        }

        let content = rest.trim().to_string();
        if stamps.is_empty() {
            if !content.is_empty() {
                plain_lines.push(content);
            }
            continue;
        }
        saw_timestamp = true;
        for ms in stamps {
            lines.push(LyricLine {
                time_ms: ms,
                text: content.clone(),
            });
        }
    }

    lines.sort_by_key(|line| line.time_ms);
    // 去掉连续重复的空行（很多 LRC 用空行当间奏）
    lines.dedup_by(|a, b| a.time_ms == b.time_ms && a.text == b.text);

    Lyrics {
        lines,
        plain: if saw_timestamp {
            String::new()
        } else {
            plain_lines.join("\n")
        },
        source: "none".to_string(),
    }
}

/// `mm:ss.xx` / `mm:ss:xx` / `mm:ss` → 毫秒；不是时间戳时返回 `None`
fn parse_timestamp(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    let (minutes, rest) = raw.split_once(':')?;
    let minutes: i64 = minutes.trim().parse().ok()?;

    // 秒与小数部分可能用 '.' 或 ':' 分隔
    let (seconds, fraction) = match rest.split_once('.') {
        Some((sec, frac)) => (sec, Some(frac)),
        None => match rest.split_once(':') {
            Some((sec, frac)) => (sec, Some(frac)),
            None => (rest, None),
        },
    };
    let seconds: i64 = seconds.trim().parse().ok()?;
    if seconds >= 60 && fraction.is_none() {
        // 没有小数时允许 `[mm:ss]`，秒数仍应 < 60；超出视为非法
        return None;
    }
    let millis = match fraction {
        Some(frac) => {
            let digits: String = frac.chars().take(3).collect();
            let value: i64 = digits.parse().ok()?;
            match digits.len() {
                0 => 0,
                1 => value * 100,
                2 => value * 10,
                _ => value,
            }
        }
        None => 0,
    };
    Some(minutes * 60_000 + seconds * 1000 + millis)
}

#[cfg(test)]
mod tests {
    use super::{parse_lrc, parse_timestamp};

    #[test]
    fn parses_basic_timestamps() {
        assert_eq!(parse_timestamp("01:02.34"), Some(62_340));
        assert_eq!(parse_timestamp("00:05"), Some(5_000));
        assert_eq!(parse_timestamp("02:03:45"), Some(123_450));
        assert_eq!(parse_timestamp("ar:歌手"), None);
    }

    #[test]
    fn parses_multiple_stamps_and_metadata() {
        let text = "[ti:夜航]\n[ar:林间电台]\n[00:01.00]第一行\n\
                    [00:03.50][00:10.00]副歌\n[00:05.20]\n";
        let lyrics = parse_lrc(text);
        assert_eq!(lyrics.lines.len(), 4);
        assert_eq!(lyrics.lines[0].time_ms, 1_000);
        assert_eq!(lyrics.lines[0].text, "第一行");
        assert_eq!(lyrics.lines[1].time_ms, 3_500);
        assert_eq!(lyrics.lines[2].time_ms, 5_200);
        assert_eq!(lyrics.lines[2].text, "", "间奏空行要保留成空文本");
        assert_eq!(lyrics.lines[3].time_ms, 10_000);
        assert!(lyrics.plain.is_empty());
    }

    #[test]
    fn falls_back_to_plain_text() {
        let lyrics = parse_lrc("第一段\n第二段\n");
        assert!(lyrics.lines.is_empty());
        assert_eq!(lyrics.plain, "第一段\n第二段");
    }

    #[test]
    fn decodes_utf16_sidecar() {
        // 带 BOM 的 UTF-16LE，Windows 记事本常见
        let mut bytes = vec![0xFF, 0xFE];
        for unit in "[00:01.00]你好".encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        let text = super::decode_text(&bytes);
        assert!(text.starts_with("[00:01.00]你好"));
    }
}

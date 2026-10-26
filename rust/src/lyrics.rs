//! 歌词：优先读同目录同名 `.lrc`，其次读音频内嵌标签。
//!
//! 只做「拿到文本并解析时间轴」，不联网、不猜歌词。没有时间戳的纯文本歌词
//! 放在 `plain` 里，界面原样滚动显示。
//!
//! 逐字歌词有两种常见写法，都按「行内时间标签」处理：
//!
//! ```text
//! [00:05.691]大[00:06.365]人[00:06.582]は        ← 方括号内联（网易云/QQ 导出的主流格式）
//! [00:05.691]<00:06.365>大<00:06.582>人        ← 尖括号（增强 LRC）
//! ```
//!
//! 同一起始时间的多行会被合并成一行歌词：带逐字标签的那行是正文，其余行
//! （罗马音、翻译）收进 `translation`。这是国内音乐软件导出「原文 + 音译 +
//! 翻译」三行歌词的标准结构。

use anyhow::Result;
use lofty::config::ParseOptions;
use lofty::file::TaggedFileExt;
use lofty::prelude::ItemKey;
use lofty::probe::Probe;
use std::path::Path;

/// 一个逐字片段（时间标签之间的文本）
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LyricWord {
    /// 起始时间（毫秒）
    pub time_ms: i64,
    pub text: String,
}

/// 一行带时间戳的歌词
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LyricLine {
    /// 起始时间（毫秒）
    pub time_ms: i64,
    /// 结束时间（毫秒）：下一行的起点，末行按最后一个字推算
    pub end_ms: i64,
    pub text: String,
    /// 逐字时间轴；不足两个片段时为空（整行按行级时间轴处理）
    pub words: Vec<LyricWord>,
    /// 同一时间戳的其余行（罗马音 / 翻译），`\n` 分隔，按文件顺序
    pub translation: String,
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
        let mut lyrics = parse(&text);
        if !lyrics.is_empty() {
            lyrics.source = "sidecar".to_string();
            return Ok(lyrics);
        }
    }

    match read_embedded(audio) {
        Ok(Some(text)) => {
            let mut lyrics = parse(&text);
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

/// LRC 常见 UTF-8；带 BOM 的 UTF-8 / UTF-16 与 GBK / GB18030 也顺手处理。
///
/// 中文 Windows 上「记事本 → 另存为 ANSI」得到的 `.lrc` 是 GBK。以前直接
/// `from_utf8_lossy` 会把整篇歌词变成替换字符，这里先严格校验 UTF-8，失败再按
/// GB18030 解码（GBK 是其子集，能覆盖绝大多数老歌词文件）。
fn decode_text(bytes: &[u8]) -> String {
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
        return String::from_utf16_lossy(&units);
    }

    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => {
            let (text, _, _) = encoding_rs::GB18030.decode(bytes);
            text.into_owned()
        }
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

/// 解析歌词：行级时间轴 + 行内逐字标签 + 同时间戳多行合并。
pub fn parse(text: &str) -> Lyrics {
    let offset = parse_offset(text);
    let mut raw_lines: Vec<RawLine> = Vec::new();
    let mut plain_lines: Vec<String> = Vec::new();

    for raw in text.lines() {
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        let (stamps, rest) = leading_stamps(raw);
        if stamps.is_empty() {
            // 没有时间戳：可能是纯文本歌词，也可能是 `[ar:xxx]` 之类的元数据。
            // 元数据行在 leading_stamps 里会被剥掉，这里只剩真正的文本行。
            if !rest.is_empty() {
                plain_lines.push(rest.to_string());
            }
            continue;
        }
        for stamp in stamps {
            let start = stamp + offset;
            let (line_text, words) = split_words(rest, start);
            raw_lines.push(RawLine {
                time_ms: start,
                text: line_text,
                words,
            });
        }
    }

    let lines = group_lines(raw_lines);

    Lyrics {
        plain: if lines.is_empty() {
            plain_lines.join("\n")
        } else {
            String::new()
        },
        lines,
        source: "none".to_string(),
    }
}

/// 一行尚未分组的原始歌词
struct RawLine {
    time_ms: i64,
    text: String,
    words: Vec<LyricWord>,
}

/// 剥掉行首连续的时间标签，返回（时间戳列表，剩余文本）
fn leading_stamps(raw: &str) -> (Vec<i64>, &str) {
    let mut stamps = Vec::new();
    let mut rest = raw;
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
            // `[ar:xxx]` / `[ti:xxx]` 这类元数据：整行丢弃
            None => {
                if is_metadata_tag(inner) {
                    rest = "";
                }
                break;
            }
        }
    }
    (stamps, rest)
}

/// `ar:歌手` / `offset:-500` 这类非时间标签
fn is_metadata_tag(inner: &str) -> bool {
    match inner.split_once(':') {
        Some((key, _)) => !key.is_empty() && key.chars().all(|c| c.is_ascii_alphabetic()),
        None => false,
    }
}

/// `[offset:+500]` → 毫秒偏移
fn parse_offset(text: &str) -> i64 {
    for raw in text.lines() {
        let raw = raw.trim();
        let Some(inner) = raw.strip_prefix('[').and_then(|s| s.strip_suffix(']')) else {
            continue;
        };
        let Some((key, value)) = inner.split_once(':') else {
            continue;
        };
        if key.eq_ignore_ascii_case("offset") {
            return value.trim().parse().unwrap_or(0);
        }
    }
    0
}

/// 把行内时间标签拆成逐字片段。
///
/// `content` 已经去掉了行首的行级时间戳；第一个片段沿用行起始时间。
/// 返回（去掉标签后的纯文本，逐字片段）。
fn split_words(content: &str, line_start: i64) -> (String, Vec<LyricWord>) {
    let mut text = String::new();
    let mut words: Vec<LyricWord> = Vec::new();
    let mut pending = line_start;
    let mut rest = content;

    loop {
        let Some((idx, ch)) = rest.char_indices().find(|(_, c)| *c == '[' || *c == '<') else {
            push_word(&mut words, &mut text, pending, rest);
            break;
        };
        let (before, after) = rest.split_at(idx);
        if !before.is_empty() {
            push_word(&mut words, &mut text, pending, before);
        }
        let close = if ch == '[' { ']' } else { '>' };
        let inner_start = ch.len_utf8();
        let Some(end) = after[inner_start..].find(close) else {
            // 没有闭合：当普通文本
            push_word(&mut words, &mut text, pending, after);
            break;
        };
        let inner = &after[inner_start..inner_start + end];
        let consumed = inner_start + end + close.len_utf8();
        match parse_timestamp(inner) {
            Some(ms) => {
                pending = ms;
                rest = &after[consumed..];
            }
            None => {
                // 非时间标签（`[ar:xx]`）：原样保留在文本里
                let keep = &after[..consumed];
                push_word(&mut words, &mut text, pending, keep);
                rest = &after[consumed..];
            }
        }
    }

    // 只有一个片段说明没有真正的逐字时间轴，按行级处理
    if words.len() < 2 {
        words.clear();
    }
    (text.trim().to_string(), words)
}

fn push_word(words: &mut Vec<LyricWord>, text: &mut String, time_ms: i64, segment: &str) {
    text.push_str(segment);
    if segment.trim().is_empty() {
        return;
    }
    words.push(LyricWord {
        time_ms,
        text: segment.to_string(),
    });
}

/// 把同一起始时间的行合并：带逐字标签的当正文，其余当译文。
fn group_lines(mut raw: Vec<RawLine>) -> Vec<LyricLine> {
    if raw.is_empty() {
        return Vec::new();
    }
    // sort_by_key 是稳定排序：同一时间戳保持文件里的原始顺序
    raw.sort_by_key(|line| line.time_ms);

    let mut groups: Vec<Vec<RawLine>> = Vec::new();
    for line in raw {
        match groups.last_mut() {
            Some(group) if group[0].time_ms == line.time_ms => group.push(line),
            _ => groups.push(vec![line]),
        }
    }

    let starts: Vec<i64> = groups.iter().map(|group| group[0].time_ms).collect();
    let mut lines = Vec::with_capacity(groups.len());

    for (index, group) in groups.into_iter().enumerate() {
        let mut main = 0usize;
        for (i, line) in group.iter().enumerate() {
            if line.words.len() > group[main].words.len() {
                main = i;
            }
        }
        // 都没有逐字时间轴时，取最长的一行当正文（通常是原文，译文更短）
        if group[main].words.is_empty() {
            for (i, line) in group.iter().enumerate() {
                if line.text.chars().count() > group[main].text.chars().count() {
                    main = i;
                }
            }
        }

        let chosen = &group[main];
        let mut extras: Vec<String> = Vec::new();
        for (i, line) in group.iter().enumerate() {
            if i == main {
                continue;
            }
            let text = line.text.trim();
            if text.is_empty() || text == chosen.text.trim() || extras.iter().any(|e| e == text) {
                continue;
            }
            extras.push(text.to_string());
        }

        let end_ms = match starts.get(index + 1) {
            Some(next) => *next,
            None => chosen
                .words
                .last()
                .map(|word| word.time_ms + 1_000)
                .unwrap_or(chosen.time_ms + 5_000),
        };

        lines.push(LyricLine {
            time_ms: chosen.time_ms,
            end_ms: end_ms.max(chosen.time_ms),
            text: chosen.text.trim().to_string(),
            words: chosen.words.clone(),
            translation: extras.join("\n"),
        });
    }

    lines
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
    use super::{parse, parse_timestamp};

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
        let lyrics = parse(text);
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
    fn parses_inline_word_timestamps() {
        let text = "[00:05.691]大[00:06.365]人[00:06.582]は[00:07.468]\n";
        let lyrics = parse(text);
        assert_eq!(lyrics.lines.len(), 1);
        let line = &lyrics.lines[0];
        assert_eq!(line.text, "大人は");
        assert_eq!(line.words.len(), 3);
        assert_eq!(line.words[0].time_ms, 5_691);
        assert_eq!(line.words[0].text, "大");
        assert_eq!(line.words[1].time_ms, 6_365);
        assert_eq!(line.words[2].time_ms, 6_582);
        assert_eq!(line.end_ms, 7_582, "末行按最后一个字 +1s 收尾");
    }

    #[test]
    fn merges_translation_lines_with_same_timestamp() {
        // 原文（逐字）/ 罗马音 / 翻译三行同一时间戳，是日文歌词的常见结构
        let text = "[00:05.691]大[00:06.365]人[00:06.582]は\n\
                    [00:05.691]o to na wa\n\
                    [00:05.691]大人是啊\n\
                    [00:09.019]次[00:09.500]の[00:09.800]行\n";
        let lyrics = parse(text);
        assert_eq!(lyrics.lines.len(), 2);
        assert_eq!(lyrics.lines[0].text, "大人は");
        assert_eq!(lyrics.lines[0].translation, "o to na wa\n大人是啊");
        assert_eq!(lyrics.lines[0].words.len(), 3);
        assert_eq!(lyrics.lines[0].end_ms, 9_019);
        assert_eq!(lyrics.lines[1].translation, "");
    }

    #[test]
    fn parses_angle_bracket_words() {
        let text = "[00:01.00]<00:01.00>Hel<00:01.50>lo\n";
        let lyrics = parse(text);
        assert_eq!(lyrics.lines[0].text, "Hello");
        assert_eq!(lyrics.lines[0].words.len(), 2);
        assert_eq!(lyrics.lines[0].words[1].time_ms, 1_500);
    }

    #[test]
    fn applies_offset_tag() {
        let text = "[offset:-500]\n[00:02.00]第一行\n";
        let lyrics = parse(text);
        assert_eq!(lyrics.lines[0].time_ms, 1_500);
    }

    #[test]
    fn single_word_is_not_treated_as_word_timing() {
        let text = "[00:01.00]整行歌词[00:02.00]\n";
        let lyrics = parse(text);
        assert_eq!(lyrics.lines[0].text, "整行歌词");
        assert!(lyrics.lines[0].words.is_empty());
    }

    #[test]
    fn falls_back_to_plain_text() {
        let lyrics = parse("第一段\n第二段\n");
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

    #[test]
    fn decodes_gbk_sidecar() {
        // 中文 Windows「另存为 ANSI」得到的 GBK 歌词
        let (bytes, _, _) = encoding_rs::GBK.encode("[00:01.00]你好，世界");
        assert_eq!(super::decode_text(&bytes), "[00:01.00]你好，世界");
    }

    #[test]
    fn decodes_utf8_with_bom() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice("[00:01.00]你好".as_bytes());
        assert_eq!(super::decode_text(&bytes), "[00:01.00]你好");
    }
}

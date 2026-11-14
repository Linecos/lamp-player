//! TTML 歌词解析（Apple Music 等平台导出的 `.ttml`）。
//!
//! 只处理歌词需要的那一小撮结构，不追求当通用 XML 解析器：
//!
//! ```xml
//! <tt><body><div>
//!   <p begin="00:00:12.345" end="00:00:15.000">
//!     <span begin="00:00:12.345" end="00:00:12.900">Hello</span>
//!     <span begin="00:00:12.900" end="00:00:13.400"> world</span>
//!   </p>
//!   <p begin="00:00:12.345" end="00:00:15.000" ttm:role="x-translation">你好世界</p>
//!   <p begin="00:00:16.000" end="00:00:18.000" ttm:role="x-bg">和声</p>
//! </div></body></tt>
//! ```
//!
//! - `<p>` 是一行，`begin` 取行级时间
//! - `<span begin>` 是行内的逐字片段，正好对应我们已有的 `LyricWord`
//! - `x-translation` 与正文同一时间戳，交给 [`crate::lyrics::group_lines`] 按
//!   「同时间戳合并」自然变成译文；`x-bg`（和声）当成普通行，重复的文本会被它去重
//! - 标签里认不出的属性一律忽略，遇到坏标签跳过而不是整篇失败

use crate::lyrics::{group_lines, LyricWord, Lyrics, RawLine};

/// 文本看起来是不是 TTML：根元素 `<tt` 或 XML 声明开头。
///
/// 只看开头一小段，避免把正文里偶然出现的 `<tt` 当成歌词格式。
pub(crate) fn looks_like_ttml(text: &str) -> bool {
    let head: String = text.chars().take(2048).collect();
    let head = head.trim_start();
    if head.starts_with("<?xml") && head.contains("<tt") {
        return true;
    }
    head.contains("<tt ") || head.contains("<tt>") || head.contains("<tt\n")
}

/// 解析 TTML 歌词。结构完全不认识时返回空结果（调用方按「没有歌词」处理）。
pub(crate) fn parse(text: &str) -> Lyrics {
    let mut raw: Vec<RawLine> = Vec::new();
    let mut scanner = Scanner::new(text);

    // 当前正在收的段落 / 片段
    let mut paragraph: Option<Paragraph> = None;
    let mut word: Option<Word> = None;

    while let Some(token) = scanner.next() {
        match token {
            Token::Start {
                name,
                attrs,
                self_closing,
            } => match name.as_str() {
                "p" => {
                    paragraph = Some(Paragraph::new(&attrs));
                    word = None;
                    if self_closing {
                        finish_paragraph(&mut paragraph, &mut raw);
                    }
                }
                "span" => {
                    if let Some(p) = paragraph.as_mut() {
                        word = Some(Word::new(&attrs));
                        if self_closing {
                            finish_word(&mut word, p);
                        }
                    }
                }
                "br" => {
                    if let Some(p) = paragraph.as_mut() {
                        p.text.push('\n');
                    }
                }
                _ => {}
            },
            Token::End { name } => match name.as_str() {
                "p" => {
                    if let Some(p) = paragraph.as_mut() {
                        finish_word(&mut word, p);
                    }
                    finish_paragraph(&mut paragraph, &mut raw);
                }
                "span" => {
                    if let Some(p) = paragraph.as_mut() {
                        finish_word(&mut word, p);
                    }
                }
                _ => {}
            },
            Token::Text(chunk) => {
                if let Some(p) = paragraph.as_mut() {
                    p.text.push_str(&chunk);
                    if let Some(w) = word.as_mut() {
                        w.text.push_str(&chunk);
                    }
                }
            }
            Token::Cdata(chunk) => {
                if let Some(p) = paragraph.as_mut() {
                    p.text.push_str(&chunk);
                    if let Some(w) = word.as_mut() {
                        w.text.push_str(&chunk);
                    }
                }
            }
        }
    }

    // 文档没闭合也把已经收到的那一行留下
    if let Some(p) = paragraph.as_mut() {
        finish_word(&mut word, p);
    }
    finish_paragraph(&mut paragraph, &mut raw);

    Lyrics {
        lines: group_lines(raw),
        plain: String::new(),
        source: "none".to_string(),
    }
}

/// 正在收集的一行
struct Paragraph {
    begin_ms: Option<i64>,
    text: String,
    words: Vec<LyricWord>,
}

impl Paragraph {
    fn new(attrs: &[Attr]) -> Self {
        Self {
            begin_ms: attr_time(attrs, "begin"),
            text: String::new(),
            words: Vec::new(),
        }
    }
}

/// 正在收集的逐字片段
struct Word {
    begin_ms: Option<i64>,
    text: String,
}

impl Word {
    fn new(attrs: &[Attr]) -> Self {
        Self {
            begin_ms: attr_time(attrs, "begin"),
            text: String::new(),
        }
    }
}

fn finish_word(word: &mut Option<Word>, paragraph: &mut Paragraph) {
    let Some(w) = word.take() else {
        return;
    };
    // 没有 begin 的片段没有时间信息，只是正文的一部分（已经在 paragraph.text 里）
    let Some(begin) = w.begin_ms else {
        return;
    };
    if w.text.trim().is_empty() {
        return;
    }
    paragraph.words.push(LyricWord {
        time_ms: begin,
        text: w.text,
    });
}

fn finish_paragraph(paragraph: &mut Option<Paragraph>, out: &mut Vec<RawLine>) {
    let Some(p) = paragraph.take() else {
        return;
    };
    let text = p.text.trim().to_string();
    let begin = p.begin_ms.unwrap_or(0);
    // 全是空白（缩进、换行）的段落不算一行
    if text.is_empty() {
        return;
    }
    let mut words = p.words;
    // 只有一个片段时没有逐字意义，按行级时间处理
    if words.len() < 2 {
        words.clear();
    }
    out.push(RawLine {
        time_ms: begin,
        text,
        words,
    });
}

// ---------------------------------------------------------------- XML 扫描

#[derive(Debug)]
struct Attr {
    /// 去掉命名空间前缀后的名字（`ttm:role` → `role`）
    name: String,
    value: String,
}

enum Token {
    Start {
        name: String,
        attrs: Vec<Attr>,
        self_closing: bool,
    },
    End {
        name: String,
    },
    Text(String),
    Cdata(String),
}

struct Scanner<'a> {
    rest: &'a str,
}

impl<'a> Scanner<'a> {
    fn new(text: &'a str) -> Self {
        Self { rest: text }
    }

    fn next(&mut self) -> Option<Token> {
        loop {
            // 后面没有标签了：剩下的全是正文（文档没闭合时就是这种）
            let Some(open) = self.rest.find('<') else {
                if self.rest.trim().is_empty() {
                    return None;
                }
                let text = std::mem::take(&mut self.rest);
                return Some(Token::Text(decode_entities(text)));
            };
            // 标签之前的文本
            if open > 0 {
                let text = &self.rest[..open];
                self.rest = &self.rest[open..];
                if text.trim().is_empty() {
                    // 标签之间的缩进 / 换行不参与正文
                    continue;
                }
                return Some(Token::Text(decode_entities(text)));
            }
            if self.rest.starts_with("<!--") {
                self.skip_until("-->");
                continue;
            }
            if self.rest.starts_with("<![CDATA[") {
                let body = &self.rest["<![CDATA[".len()..];
                match body.find("]]>") {
                    Some(end) => {
                        let raw = body[..end].to_string();
                        self.rest = &body[end + 3..];
                        return Some(Token::Cdata(raw));
                    }
                    None => {
                        self.rest = "";
                        return None;
                    }
                }
            }
            if self.rest.starts_with("<?") || self.rest.starts_with("<!") {
                self.skip_until(">");
                continue;
            }
            let close = self.rest.find('>')?;
            let inner = &self.rest[1..close];
            self.rest = &self.rest[close + 1..];

            if let Some(name) = inner.strip_prefix('/') {
                return Some(Token::End {
                    name: local_name(name.trim()),
                });
            }
            let self_closing = inner.ends_with('/');
            let body = inner.trim_end_matches('/');
            let (name, attrs) = split_tag(body);
            return Some(Token::Start {
                name,
                attrs: parse_attrs(attrs),
                self_closing,
            });
        }
    }

    fn skip_until(&mut self, needle: &str) {
        match self.rest.find(needle) {
            Some(end) => self.rest = &self.rest[end + needle.len()..],
            None => self.rest = "",
        }
    }
}

/// `p begin="..."` → (`p`, `begin="..."`)
fn split_tag(body: &str) -> (String, &str) {
    let body = body.trim_start();
    match body.find(|c: char| c.is_whitespace()) {
        Some(end) => (local_name(&body[..end]), &body[end..]),
        None => (local_name(body), ""),
    }
}

/// `ttm:role` → `role`；`p` 原样返回
fn local_name(name: &str) -> String {
    name.rsplit(':').next().unwrap_or(name).to_string()
}

fn parse_attrs(raw: &str) -> Vec<Attr> {
    let mut attrs = Vec::new();
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // 跳到属性名
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        let name_start = i;
        while i < bytes.len() && bytes[i] != b'=' && !bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if name_start == i {
            i += 1;
            continue;
        }
        let name = local_name(&raw[name_start..i]);
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'=' {
            continue;
        }
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        let quote = bytes[i];
        if quote != b'"' && quote != b'\'' {
            continue;
        }
        i += 1;
        let value_start = i;
        while i < bytes.len() && bytes[i] != quote {
            i += 1;
        }
        let value = decode_entities(&raw[value_start..i]);
        if i < bytes.len() {
            i += 1;
        }
        attrs.push(Attr { name, value });
    }
    attrs
}

fn attr_time(attrs: &[Attr], name: &str) -> Option<i64> {
    attrs
        .iter()
        .find(|attr| attr.name == name)
        .and_then(|attr| parse_time(&attr.value))
}

/// TTML 时间表达式 → 毫秒。
///
/// 认这几种：`hh:mm:ss.mmm`、`mm:ss.mmm`、`ss.mmm`、`12.5s`、`350ms`。
/// 帧（`hh:mm:ss:ff`）在歌词里几乎见不到，遇到就按「最后一段是秒」兜底。
fn parse_time(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let lower = raw.to_ascii_lowercase();
    if let Some(number) = lower.strip_suffix("ms") {
        return number.trim().parse::<f64>().ok().map(|v| v.round() as i64);
    }
    if let Some(number) = lower.strip_suffix('s') {
        return number
            .trim()
            .parse::<f64>()
            .ok()
            .map(|v| (v * 1000.0).round() as i64);
    }
    if raw.contains(':') {
        let parts: Vec<&str> = raw.split(':').collect();
        let (hours, minutes, seconds) = match parts.as_slice() {
            [h, m, s] => (
                h.parse::<f64>().ok()?,
                m.parse::<f64>().ok()?,
                s.parse::<f64>().ok()?,
            ),
            [m, s] => (0.0, m.parse::<f64>().ok()?, s.parse::<f64>().ok()?),
            _ => return None,
        };
        let total = hours * 3600.0 + minutes * 60.0 + seconds;
        return Some((total * 1000.0).round() as i64);
    }
    raw.parse::<f64>()
        .ok()
        .map(|seconds| (seconds * 1000.0).round() as i64)
}

/// 常见实体解码。TTML 里会出现 `&amp;` `&lt;` `&quot;` `&#39;` 这些。
fn decode_entities(raw: &str) -> String {
    if !raw.contains('&') {
        return raw.to_string();
    }
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(index) = rest.find('&') {
        out.push_str(&rest[..index]);
        let tail = &rest[index..];
        let Some(end) = tail.find(';').filter(|end| *end <= 10) else {
            out.push('&');
            rest = &tail[1..];
            continue;
        };
        let entity = &tail[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix('#')
                .and_then(|number| {
                    if let Some(hex) = number
                        .strip_prefix('x')
                        .or_else(|| number.strip_prefix('X'))
                    {
                        u32::from_str_radix(hex, 16).ok()
                    } else {
                        number.parse::<u32>().ok()
                    }
                })
                .and_then(char::from_u32),
        };
        match decoded {
            Some(ch) => out.push(ch),
            None => out.push_str(&tail[..=end]),
        }
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <head><metadata><ttm:title>测试</ttm:title></metadata></head>
  <body><div>
    <p begin="00:00:12.345" end="00:00:15.000"><span begin="00:00:12.345">Hello</span><span begin="00:00:13.000"> world</span></p>
    <p begin="00:00:12.345" end="00:00:15.000" ttm:role="x-translation">你好世界</p>
    <p begin="00:00:16.000" end="00:00:18.500">第二行 &amp; 符号</p>
  </div></body></tt>"#;

    #[test]
    fn parses_lines_words_and_translation() {
        let lyrics = parse(SAMPLE);
        assert_eq!(lyrics.lines.len(), 2, "译文应合并进同一行");

        let first = &lyrics.lines[0];
        assert_eq!(first.time_ms, 12_345);
        assert_eq!(first.text, "Hello world");
        assert_eq!(first.translation, "你好世界");
        assert_eq!(first.words.len(), 2, "两个 span 应成为逐字片段");
        assert_eq!(first.words[0].time_ms, 12_345);
        assert_eq!(first.words[1].time_ms, 13_000);

        let second = &lyrics.lines[1];
        assert_eq!(second.time_ms, 16_000);
        assert_eq!(second.text, "第二行 & 符号", "实体要解码");
        assert!(second.words.is_empty(), "没有 span 时按行级时间处理");
    }

    #[test]
    fn recognizes_mm_ss_and_suffix_times() {
        assert_eq!(parse_time("00:12.345"), Some(12_345));
        assert_eq!(parse_time("01:02:03.500"), Some(3_723_500));
        assert_eq!(parse_time("12.345"), Some(12_345));
        assert_eq!(parse_time("350ms"), Some(350));
        assert_eq!(parse_time("1.5s"), Some(1_500));
        assert_eq!(parse_time("abc"), None);
    }

    #[test]
    fn skips_whitespace_only_paragraphs_and_handles_bg_role() {
        let text = r#"<tt><body><div>
            <p begin="1.0">  </p>
            <p begin="2.0" ttm:role="x-bg">和声</p>
        </div></body></tt>"#;
        let lyrics = parse(text);
        assert_eq!(lyrics.lines.len(), 1);
        assert_eq!(lyrics.lines[0].text, "和声");
        assert_eq!(lyrics.lines[0].time_ms, 2_000);
    }

    #[test]
    fn single_span_falls_back_to_line_timing() {
        let text =
            r#"<tt><body><div><p begin="3.0"><span begin="3.0">整行</span></p></div></body></tt>"#;
        let lyrics = parse(text);
        assert_eq!(lyrics.lines.len(), 1);
        assert!(
            lyrics.lines[0].words.is_empty(),
            "只有一个片段时没有逐字意义"
        );
    }

    #[test]
    fn broken_xml_does_not_panic() {
        let lyrics = parse("<tt><body><div><p begin=\"1.0\">没闭合");
        assert_eq!(lyrics.lines.len(), 1);
        assert_eq!(lyrics.lines[0].text, "没闭合");
        assert!(parse("").lines.is_empty());
        assert!(parse("<!DOCTYPE tt><tt></tt>").lines.is_empty());
    }

    #[test]
    fn detects_ttml_by_root_element() {
        assert!(looks_like_ttml(SAMPLE));
        assert!(looks_like_ttml("<tt><body></body></tt>"));
        assert!(!looks_like_ttml("[00:12.34]普通歌词"));
        assert!(!looks_like_ttml("just text"));
    }
}

//! 目录扫描与标签解析。
//!
//! 这是**内部模块**，不经 frb 导出给 Dart；对外只通过 `api::scan::scan_folder`。
//! 单独成模块的目的：能脱离数据库直接测试「遍历 + 解析」这段纯逻辑。

use crate::api::model::Track;
use anyhow::{Context, Result};
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::Accessor;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;

/// 支持的音频扩展名（小写，不含点）
pub const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "m4a", "aac", "wma", "ape", "opus",
];

/// 一次目录遍历的原始结果（尚未入库）
pub struct Collected {
    /// 成功解析的曲目
    pub tracks: Vec<Track>,
    /// 命中扩展名的文件数（含解析失败的）
    pub scanned: usize,
    /// 解析失败被跳过的文件数
    pub failed: usize,
}

/// 递归收集目录下的音频文件并解析元数据。
///
/// 单个文件解析失败只计入 `failed`，不影响整体；目录不可用时返回错误。
pub fn collect_tracks(folder: &Path) -> Result<Collected> {
    if !folder.is_dir() {
        anyhow::bail!("目录不存在或不是目录: {}", folder.display());
    }

    let mut collected = Collected {
        tracks: Vec::new(),
        scanned: 0,
        failed: 0,
    };
    let added_at = now_secs();

    // 不跟随软链接，避免目录环导致无限遍历
    for entry in WalkDir::new(folder).follow_links(false) {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => {
                collected.failed += 1;
                continue;
            }
        };

        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        if !is_audio_file(path) {
            continue;
        }

        collected.scanned += 1;
        match read_track(path, added_at) {
            Ok(track) => collected.tracks.push(track),
            Err(_) => collected.failed += 1,
        }
    }

    Ok(collected)
}

/// 按扩展名判断是否是候选音频文件（不区分大小写）
pub fn is_audio_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            AUDIO_EXTENSIONS
                .iter()
                .any(|known| ext.eq_ignore_ascii_case(known))
        })
        .unwrap_or(false)
}

/// 解析单个文件；读不出标签时用文件名兜底，不产生错误。
///
/// 只有「文件打不开 / 格式不受支持」才返回错误。
fn read_track(path: &Path, added_at: i64) -> Result<Track> {
    let tagged = lofty::read_from_path(path)
        .with_context(|| format!("解析元数据失败: {}", path.display()))?;

    let duration_secs = tagged.properties().duration().as_secs_f64();

    // primary_tag 按容器的主标签类型取（如 FLAC → VorbisComment），取不到再退到第一个标签
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());

    let title = tag
        .and_then(|t| t.title())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| file_stem(path));

    let artist = tag
        .and_then(|t| t.artist())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let album = tag
        .and_then(|t| t.album())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let track_num = tag
        .and_then(|t| t.track())
        .and_then(|n| i32::try_from(n).ok());

    Ok(Track {
        path: path.to_string_lossy().into_owned(),
        title,
        artist,
        album,
        duration_secs,
        track_num,
        added_at,
    })
}

/// 文件名（去掉扩展名）作为标题兜底
fn file_stem(path: &Path) -> String {
    path.file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

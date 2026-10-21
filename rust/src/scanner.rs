//! 目录扫描与标签解析。
//!
//! 这是**内部模块**，不经 frb 导出给 Dart；对外只通过 `api::scan::scan_folder`。
//! 单独成模块的目的：能脱离数据库直接测试「遍历 + 解析」这段纯逻辑。

use crate::api::model::Track;
use anyhow::{Context, Result};
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::Accessor;
use std::collections::{HashMap, HashSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;

/// 支持的音频扩展名（小写，不含点）
pub const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "m4a", "aac", "wma", "ape", "opus",
];

/// 解析成功的一条曲目 + 文件指纹（增量扫描用）。
pub struct ScannedTrack {
    pub track: Track,
    /// 文件修改时间（Unix 纳秒）
    pub mtime_ns: i64,
    /// 文件大小（字节）
    pub size: i64,
}

/// 一次目录遍历的原始结果（尚未入库）
#[derive(Default)]
pub struct Collected {
    /// 新解析出来、需要入库的曲目
    pub tracks: Vec<ScannedTrack>,
    /// 遍历到的所有候选文件路径（含未变化、解析失败的，用于清理）
    pub seen: HashSet<String>,
    /// 命中扩展名的文件数（含未变化与解析失败的）
    pub scanned: usize,
    /// 因 mtime/size 未变而跳过的文件数
    pub unchanged: usize,
    /// 解析失败被跳过的文件数
    pub failed: usize,
    /// 遍历时读不到的条目数（权限、IO 错误等）
    pub walk_errors: usize,
}

/// 递归收集目录下的音频文件并解析元数据（全量，不做增量比对）。
pub fn collect_tracks(folder: &Path) -> Result<Collected> {
    collect_tracks_incremental(folder, &HashMap::new())
}

/// 递归收集目录下的音频文件并解析元数据。
///
/// `known` 是曲库里已有的文件指纹：mtime/size 都没变的文件跳过解析，只记入
/// `seen`；单个文件解析失败只计入 `failed`，不影响整体；目录不可用时返回错误。
pub fn collect_tracks_incremental(
    folder: &Path,
    known: &HashMap<String, (i64, i64)>,
) -> Result<Collected> {
    if !folder.is_dir() {
        anyhow::bail!("目录不存在或不是目录: {}", folder.display());
    }

    let mut collected = Collected::default();
    let added_at = now_secs();

    // 不跟随软链接，避免目录环导致无限遍历
    for entry in WalkDir::new(folder).follow_links(false) {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => {
                collected.walk_errors += 1;
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

        // 取不到 metadata 就无法判断是否变化，计入遍历错误并跳过
        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(_) => {
                collected.walk_errors += 1;
                continue;
            }
        };
        let (mtime_ns, size) = signature(&meta);

        let key = path.to_string_lossy().into_owned();
        collected.scanned += 1;
        collected.seen.insert(key.clone());

        if known.get(&key) == Some(&(mtime_ns, size)) {
            collected.unchanged += 1;
            continue;
        }

        match read_track_guarded(path, added_at, mtime_ns, size) {
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

/// 解析单个文件，把 panic 隔离在单个文件内。
///
/// lofty 解析损坏/恶意文件时理论上可能 panic；panic 穿过 FFI 会直接终止进程，
/// 所以这里兜一层，把它降级成 `failed`。
fn read_track_guarded(
    path: &Path,
    added_at: i64,
    mtime_ns: i64,
    size: i64,
) -> Result<ScannedTrack> {
    match catch_unwind(AssertUnwindSafe(|| {
        read_track(path, added_at, mtime_ns, size)
    })) {
        Ok(result) => result,
        Err(_) => anyhow::bail!("解析元数据时发生 panic: {}", path.display()),
    }
}

/// 解析单个文件；读不出标签时用文件名兜底，不产生错误。
///
/// 只有「文件打不开 / 格式不受支持」才返回错误。
fn read_track(path: &Path, added_at: i64, mtime_ns: i64, size: i64) -> Result<ScannedTrack> {
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

    Ok(ScannedTrack {
        track: Track {
            path: path.to_string_lossy().into_owned(),
            title,
            artist,
            album,
            duration_secs,
            track_num,
            added_at,
        },
        mtime_ns,
        size,
    })
}

/// 文件名（去掉扩展名）作为标题兜底
fn file_stem(path: &Path) -> String {
    path.file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

/// 取文件指纹：修改时间（纳秒）+ 大小；取不到修改时间时 mtime 记 0（下次必重新解析）。
fn signature(meta: &std::fs::Metadata) -> (i64, i64) {
    let mtime_ns = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX))
        .unwrap_or(0);
    let size = i64::try_from(meta.len()).unwrap_or(i64::MAX);
    (mtime_ns, size)
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

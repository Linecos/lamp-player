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
///
/// 注意：**不含 wma**。标签解析用的 lofty 不支持 ASF/WMA，把 wma 列进来
/// 只会让每个文件走一遍注定失败的解析（`failed` 虚高且不产生记录）。
/// 若将来要支持 wma，需要另配 ASF 解析方案再加入。
pub const AUDIO_EXTENSIONS: &[&str] = &["mp3", "flac", "wav", "ogg", "m4a", "aac", "ape", "opus"];

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
    /// 遍历到的所有候选文件路径 key（归一化后，用于清理比对）
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
///
/// 指纹与 `seen` 的 key 都经过 [`path_key`] 归一化（Windows 下大小写/斜杠等价），
/// 因此调用方传入的 `known` 必须同样用 [`path_key`] 归一化过 key。
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

        let key = path_key(&path.to_string_lossy());
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

/// 路径归一化 key：同一文件在库里的不同写法要能对上号。
///
/// Windows 文件系统不区分大小写，`/` 与 `\` 等价，所以 `E:\Music`、
/// `e:\music`、`E:/Music` 是同一批文件；不归一化的话增量指纹全部 miss、
/// 清理比对不上，还会因 `path UNIQUE` 是区分大小写而产生重复记录。
/// 其它平台路径本就严格区分，原样返回。
///
/// 曲库侧取指纹（`file_signatures`）与清理（`prune_tracks_under`）使用同一口径。
#[must_use]
pub(crate) fn path_key(path: &str) -> String {
    path_key_with(path, cfg!(windows))
}

/// [`path_key`] 的可测试版本：`windows` 由调用方传入，
/// 这样在任意平台上都能验证两种归一化规则。
fn path_key_with(path: &str, windows: bool) -> String {
    if windows {
        path.replace('/', "\\").to_lowercase()
    } else {
        path.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::path_key_with;

    #[test]
    fn path_key_normalizes_only_on_windows() {
        assert_eq!(path_key_with("E:/Music/A.mp3", true), "e:\\music\\a.mp3");
        assert_eq!(path_key_with("/Music/A.mp3", false), "/Music/A.mp3");
    }
}

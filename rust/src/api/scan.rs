//! 目录扫描：遍历音频文件、解析元数据、写入曲库。
//!
//! 纯遍历/解析逻辑在 `crate::scanner`，这里只负责串起「扫描 → 入库 → 清理」并统计。
//! 契约见 `docs/API_CONTRACT.md`。

use crate::api::db;
use crate::scanner;
use anyhow::{Context, Result};
use std::time::Instant;

/// 单次扫描的统计结果
pub struct ScanReport {
    /// 遍历到的候选音频文件数（含未变化与解析失败的）
    pub scanned: i32,
    /// 因 mtime/size 未变而跳过解析的文件数
    pub unchanged: i32,
    /// 新入库或更新的曲目数
    pub upserted: i32,
    /// 解析失败被跳过的文件数
    pub failed: i32,
    /// 遍历时读不到的条目数（权限、IO 错误等）
    pub walk_errors: i32,
    /// 本次清理掉的「文件已不存在」记录数
    pub pruned: i32,
    /// 本次扫描耗时（毫秒）
    pub elapsed_ms: i64,
}

/// 扫描目录（递归子目录），解析元数据后写入曲库，返回统计。
///
/// 入口先把目录路径 canonicalize（解析出磁盘上的真实大小写与反斜杠写法），
/// 避免调用方传 `E:\Music` 与 `e:/music` 之类仅大小写/分隔符差异的字符串时，
/// 存库路径口径不一致导致增量指纹失效、清理失配、产生重复记录。
///
/// 已存在的曲目按 `path` 更新，不会产生重复记录；mtime 和大小都没变的文件
/// 直接跳过解析（`unchanged`）。扫描结束后会清理该目录下磁盘上已不存在的记录；
/// 遍历过程中出现权限/IO 错误时跳过清理，避免误删读不到的文件。
///
/// 单个文件解析失败只计入 `failed`，不影响其它文件入库。
///
/// # Errors
/// 目录不存在、无读取权限，或曲库未初始化（未调用 `init_db`）时返回错误。
pub fn scan_folder(folder: String) -> Result<ScanReport> {
    let started = Instant::now();

    // 先取存量指纹：曲库未初始化时这里就会报错，符合契约
    let known = db::file_signatures()?;

    // 归一化入口目录；目录不存在时 canonicalize 就会报错（保留原始字符串便于定位）
    let folder =
        dunce::canonicalize(&folder).with_context(|| format!("目录不存在或无权访问: {folder}"))?;
    let covers_dir = db::covers_dir()?;
    let collected = scanner::collect_tracks_incremental(&folder, &known, Some(&covers_dir))?;

    let upserted = db::upsert_scanned(&collected.tracks)
        .with_context(|| format!("扫描结果写入曲库失败: {}", folder.display()))?;

    let pruned = if collected.walk_errors == 0 {
        db::prune_tracks_under(&folder, &collected.seen)
            .with_context(|| format!("清理曲库失败: {}", folder.display()))?
    } else {
        0
    };

    // 封面缓存清理是尽力而为：失败不应让一次成功的扫描报错
    let _ = db::prune_unused_covers();

    Ok(ScanReport {
        scanned: to_i32(collected.scanned),
        unchanged: to_i32(collected.unchanged),
        upserted,
        failed: to_i32(collected.failed),
        walk_errors: to_i32(collected.walk_errors),
        pruned,
        elapsed_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX),
    })
}

/// 计数用，超出 i32 范围时饱和而不是回绕
fn to_i32(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

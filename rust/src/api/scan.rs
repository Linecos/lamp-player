//! 目录扫描：遍历音频文件、解析元数据、写入曲库。
//!
//! 纯遍历/解析逻辑在 `crate::scanner`，这里只负责串起「扫描 → 入库」并统计。
//! 契约见 `docs/API_CONTRACT.md`。

use crate::api::db;
use crate::scanner::{self, Collected};
use anyhow::{Context, Result};
use std::path::PathBuf;
use std::time::Instant;

/// 单次扫描的统计结果
pub struct ScanReport {
    /// 遍历到的候选音频文件数
    pub scanned: i32,
    /// 新入库或更新的曲目数
    pub upserted: i32,
    /// 解析失败被跳过的文件数
    pub failed: i32,
    /// 本次扫描耗时（毫秒）
    pub elapsed_ms: i64,
}

/// 扫描目录（递归子目录），解析元数据后写入曲库，返回统计。
///
/// 已存在的曲目按 `path` 更新，不会产生重复记录；
/// 单个文件解析失败只计入 `failed`，不影响其它文件入库。
///
/// # Errors
/// 目录不存在、无读取权限，或曲库未初始化（未调用 `init_db`）时返回错误。
pub fn scan_folder(folder: String) -> Result<ScanReport> {
    let started = Instant::now();
    let folder = PathBuf::from(folder);

    let Collected {
        tracks,
        scanned,
        failed,
    } = scanner::collect_tracks(&folder)?;

    let upserted = db::upsert_tracks(tracks)
        .with_context(|| format!("扫描结果写入曲库失败: {}", folder.display()))?;

    Ok(ScanReport {
        scanned: to_i32(scanned),
        upserted,
        failed: to_i32(failed),
        elapsed_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX),
    })
}

/// 计数用，超出 i32 范围时饱和而不是回绕
fn to_i32(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

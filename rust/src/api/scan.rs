//! 目录扫描与元数据解析。
//!
//! **状态：接口契约已冻结（v0.1），实现待补。**
//! 契约变更流程见 `docs/API_CONTRACT.md`；任务清单见 `docs/ROADMAP.md`（M1）。
//!
//! 实现要点（供接手的人参考）：
//! - 用 `walkdir` 递归遍历目录，按扩展名过滤（不区分大小写）：
//!   `mp3 flac wav ogg m4a aac wma ape opus`
//! - 用 `lofty` 读取标签：`title` / `artist` / `album` / `duration` / `track_num`；
//!   缺标题时用文件名（不含扩展名）兜底
//! - 结果交给 [`crate::api::db::upsert_tracks`] 批量入库（按 `path` 去重）
//! - 大目录扫描耗时较长：调用方应放到异步任务里，进度上报留待后续用
//!   `StreamSink` 追加（届时属于**新增**接口，不改动本文件已冻结的签名）

use anyhow::Result;

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
/// 已存在的曲目按 `path` 更新，不会产生重复记录。
///
/// # Errors
/// 目录不存在、无读取权限或数据库未初始化（未调用 `init_db`）时返回错误。
pub fn scan_folder(folder: String) -> Result<ScanReport> {
    // TODO(M1): 实现扫描逻辑（负责人：Linecos）
    let _ = folder;
    anyhow::bail!("scan_folder 尚未实现（骨架存根，见 rust/src/api/scan.rs）")
}

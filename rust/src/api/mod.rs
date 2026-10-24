//! 对 Dart 暴露的 API 层：这里是 Flutter ↔ Rust 的唯一接口面。
//!
//! 新增/修改导出函数后必须重新生成绑定：
//! `flutter_rust_bridge_codegen generate`
//!
//! 各模块职责：
//! - [`model`]：跨语言数据模型（`Track`、`Playlist` 等）
//! - [`db`]：曲库持久化（SQLite + FTS5）
//! - [`collections`]：歌单 / 收藏 / 播放历史
//! - [`scan`]：目录扫描与元数据解析
//! - [`player`]：BASS 播放引擎
//! - [`lyrics`]：歌词读取（`.lrc` / 内嵌标签）
//! - [`media`]：系统媒体控制（SMTC）与单实例
//! - [`simple`]：桥接自检函数（`greet`），用于确认 FFI 正常

pub mod collections;
pub mod db;
pub mod lyrics;
pub mod media;
pub mod model;
pub mod player;
pub mod scan;
pub mod simple;

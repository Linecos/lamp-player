//! 对 Dart 暴露的 API 层：这里是 Flutter ↔ Rust 的唯一接口面。
//!
//! 新增/修改导出函数后必须重新生成绑定：
//! `flutter_rust_bridge_codegen generate`
//!
//! 各模块职责：
//! - [`model`]：跨语言数据模型（`Track`、`Playlist` 等）
//! - [`db`]：曲库持久化（SQLite + FTS5）
//! - [`cover_override`]：自定义艺术家 / 专辑封面
//! - [`collections`]：歌单 / 收藏 / 播放历史
//! - [`scan`]：目录扫描与元数据解析
//! - [`player`]：BASS 播放引擎
//! - [`replaygain`]：ReplayGain 标签写入（多选「计算 ReplayGain」）
//! - [`metadata`]：标签元数据读写（右键「修改元数据」）
//! - [`lyrics`]：歌词读取（`.lrc` / 内嵌标签）与编辑保存
//! - [`media`]：系统媒体控制（SMTC）与单实例
//! - [`appearance`]：系统强调色（动态取色）
//! - [`simple`]：桥接自检函数（`greet`），用于确认 FFI 正常

pub mod appearance;
pub mod collections;
pub mod cover_override;
pub mod db;
pub mod desktop_lyrics;
pub mod lyrics;
pub mod media;
pub mod metadata;
pub mod model;
pub mod player;
pub mod replaygain;
pub mod scan;
pub mod simple;

//! Lamp Player 的 Rust 核心。
//!
//! 结构：
//! - [`api`]：唯一对 Dart 暴露的接口面（db / scan / player / model）
//! - `bass`：BASS 动态加载封装（不经 frb 导出，仅被 `api` 调用）
//! - `frb_generated`：flutter_rust_bridge 生成代码，**禁止手改**
//!
//! 约定：对外函数返回 `anyhow::Result<T>`，库代码不 panic；
//! 新增导出函数后必须重跑 `flutter_rust_bridge_codegen generate`。
//! 详见仓库根目录的 `docs/ARCHITECTURE.md` 与 `docs/API_CONTRACT.md`。
pub mod api;
mod frb_generated;

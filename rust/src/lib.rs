//! Lamp Player 的 Rust 核心。
//!
//! 结构：
//! - [`api`]：唯一对 Dart 暴露的接口面（db / scan / player / model / media）
//! - [`scanner`]：目录遍历与标签解析（内部模块，供 `api::scan` 调用）
//! - [`lyrics`]：歌词读取与 LRC 解析（内部模块，供 `api::lyrics` 调用）
//! - `bass`：BASS 动态加载封装（内部模块，仅被 `api::player` 调用）
//! - `smtc` / `single_instance`：Windows 系统集成（内部模块，仅被 `api::media` 调用）
//! - `frb_generated`：flutter_rust_bridge 生成代码，**禁止手改**
//!
//! 约定：对外函数返回 `anyhow::Result<T>`，库代码不 panic；
//! 新增导出函数后必须重跑 `flutter_rust_bridge_codegen generate`。
//! 详见仓库根目录的 `docs/ARCHITECTURE.md` 与 `docs/API_CONTRACT.md`。
pub mod api;
pub mod bass;
mod frb_generated;
pub mod lyrics;
pub mod media_platform;
pub mod scanner;
#[cfg(windows)]
pub mod single_instance;
#[cfg(windows)]
pub mod smtc;

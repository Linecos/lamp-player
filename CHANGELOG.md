# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- Rust API 契约冻结：`db::*`、`scan::scan_folder`、`player::*`，签名见 `docs/API_CONTRACT.md`（`player::*` 仍为存根）
- 扫描实现：`scan_folder` 支持 9 种扩展名、递归子目录、不跟随软链接；`lofty` 读标签、无标签用文件名兜底；整批单事务入库，单文件解析失败只计入 `failed` 不中断
- 内部模块 `rust/src/scanner.rs`（遍历 + 标签解析，可脱离数据库测试）与 `rust/tests/scan.rs`（遍历过滤、缺失目录、扫描→入库→中文前缀检索全链路）
- Dart 应用外壳：`LampApp` + 主题（Material 3，随系统深浅色）+ 路由表
- 曲库页占位实现，纯 Dart 环境可渲染
- 协作设施：`CONTRIBUTING.md`、Issue 模板、CODEOWNERS、PR 模板、路线图与接口契约文档
- 一键脚本：`scripts/bootstrap.ps1`（环境准备）、`scripts/check.ps1`（本地全套检查）、`scripts/setup-labels.ps1`（标签初始化）

### 变更

- `rust/Cargo.toml` 的 `crate-type` 增加 `rlib`，让 Rust 集成测试能链接本 crate（Flutter 构建不受影响）
- `main.dart` 精简为「初始化桥接 + 挂载 `LampApp`」，去掉 frb 模板残留注释
- `analysis_options.yaml`：排除生成代码、启用单引号与 `unawaited_futures`
- CI：新增 `dart format` 检查；`cargo clippy -D warnings` 转为阻塞；缓存 codegen 二进制

### 修复

- `db::upsert_tracks` 失败时不回滚事务，可能留下半批数据（现改为失败即回滚）
- 曲库连接获取不再 panic（未初始化 / 锁中毒时返回错误）
- `db::prune_missing_tracks` 返回值类型不匹配（`usize` → `i32`）

## [0.1.0] - 2026-10-21

> 首个骨架版本，尚未打 git tag；发布流程见 docs/ROADMAP.md 的 M3。

### 新增

- Flutter + Rust（flutter_rust_bridge v2）+ BASS 的项目骨架，仅支持 Windows 桌面端
- SQLite 曲库（`rusqlite` bundled，启用 FTS5 全文检索，含同步触发器与中文前缀检索验证）
- BASS 2.4 SDK 自动下载脚本（闭源库不入库）


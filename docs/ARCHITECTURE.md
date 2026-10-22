# 架构说明

> 改架构相关的决定时请同步更新本文档。接口签名以 [API_CONTRACT.md](API_CONTRACT.md) 为准。

## 1. 分层

```
┌──────────────────────────────────────────┐
│ Flutter / Dart                           │
│   app/     应用外壳：主题、路由            │
│   features/ 页面（曲库、播放、设置）       │
│   common/  通用组件与工具（无业务依赖）    │
└───────────────┬──────────────────────────┘
                │ flutter_rust_bridge v2（类型安全 FFI，异步）
┌───────────────▼──────────────────────────┐
│ Rust 核心（rust/src）                     │
│   api/    对 Dart 暴露的唯一接口面         │
│     db     曲库持久化（SQLite + FTS5）     │
│     collections 歌单 / 收藏 / 播放历史     │
│     scan   扫描入库（统计 + 写库）         │
│     player 播放控制（状态与参数校验）      │
│   scanner.rs 遍历与标签解析（内部模块）    │
│   bass.rs    BASS 动态加载与调用封装       │
└───────────────┬──────────────────────────┘
                │ libloading 运行时加载
┌───────────────▼──────────────────────────┐
│ bass.dll（闭源，third_party，不入库）      │
└──────────────────────────────────────────┘
```

**边界原则**

- Dart 不直接碰 SQLite / 文件系统 / BASS，一切走 `rust/src/api`。
- `api/` 之外的 Rust 模块（如 `bass.rs`）不导出给 Dart，只被 `api/` 调用。
- 跨语言数据结构放 `api/model.rs`，改字段等于改契约，按 [API_CONTRACT.md](API_CONTRACT.md) 的流程走。

## 2. 目录职责

| 路径 | 职责 | 备注 |
|---|---|---|
| `lib/main.dart` | 入口：初始化桥接、挂载 `LampApp` | 不写业务逻辑 |
| `lib/src/app/` | 应用外壳、路由表（`routes.dart`） | 新增页面在这里登记 |
| `lib/src/theme/` | 全局主题（Material 3，seed 色） | 页面内禁止写死颜色 |
| `lib/src/features/<模块>/` | 页面与页面内状态 | 一个目录一个功能域 |
| `lib/src/common/` | 与业务无关的组件、格式化工具 | 必须可被任意页复用 |
| `lib/src/rust/` | **生成代码**，禁止手改 | `flutter_rust_bridge_codegen generate` |
| `rust/src/api/` | 对 Dart 的接口面 | 每个模块一个文件 |
| `rust/src/scanner.rs` | 目录遍历 + 标签解析（walkdir + lofty） | 内部模块，不经 frb 导出，便于脱离数据库测试 |
| `rust/src/bass.rs` | BASS 单例、符号表、状态查询 | 平台相关代码加 `cfg` |
| `rust/tests/` | 集成级 Rust 测试 | 需要真实依赖（如 bundled FTS5）的用例 |
| `scripts/` | 环境与检查脚本 | 保持可重复执行（幂等） |
| `third_party/` | 第三方二进制（BASS） | gitignore，脚本下载 |
| `windows/` | Windows 宿主工程 | 把 `bass.dll` 及 add-on 拷进 bundle 的 install 规则在这里 |

## 3. 主要数据流

**启动**

```
main() → RustLib.init()（失败则显示 LampStartupErrorApp，避免白屏）
      → LampApp → LibraryPage → 调 db.init_db(路径)（路径由 Dart 侧 path_provider 决定）
```

**扫描入库**

```
Dart: scanFolder(folder)
  → Rust: 读出存量文件指纹（path → mtime/size）
  → walkdir 遍历 → 未变化的文件跳过 → lofty 解析标签 → 组装 Track
  → db.upsert_scanned（单事务，按 path 去重，写入文件指纹）
  → 清理该目录下本次没看到的记录（有遍历错误时跳过）
  → 返回 ScanReport { scanned, unchanged, upserted, failed, walk_errors, pruned, elapsed_ms }
Dart: 用 all_tracks() 刷新列表
```

**列表与搜索**

```
Dart: allTracks()                  → 按 artist/album/track_num 排序
Dart: searchTracks(query, limit)   → FTS5 前缀匹配（CJK 不分词，故统一加 *）
```

**播放**

```
Dart: playerPlay(path) → Rust: 停旧曲 → BASS_StreamCreateFile → BASS_ChannelPlay
Dart: 轮询 playerPosition()/playerState() 更新进度条（M2 先用轮询，后续可换事件流）
```

## 4. 关键设计决策

| 决策 | 原因 |
|---|---|
| BASS 用 `libloading` 运行时加载 | 免链接 `.lib`，绕开工具链格式问题；DLL 缺失时可降级而不是启动失败 |
| BASS 调用收敛到专用线程 | frb 的 async 函数跑在线程池，线程不固定；BASS 的初始化和通道操作要求同线程 |
| BASS DLL 优先从 exe 同级目录加载 | 构建时由 CMake 拷入，开发态再从 `third_party` 回退，避免发布版找不到 DLL |
| SQLite 用 `rusqlite` bundled | 自带编译的 SQLite 保证 FTS5 可用，不依赖系统库 |
| 曲库结构带 `PRAGMA user_version` | 加字段时能升级老库并重建索引，`CREATE TABLE IF NOT EXISTS` 做不到 |
| 歌单 / 收藏 / 历史用外键 `ON DELETE CASCADE` | 曲目被扫描清理后，相关条目自动消失，避免 UI 拿到悬空路径；连接级 `PRAGMA foreign_keys = ON` |
| FTS5 用外部内容表 + 三个触发器 | 曲目表与索引表自动同步，无需手写索引维护 |
| 搜索统一前缀匹配 + bm25 排序 | FTS5 默认分词器对 CJK 整段切一个 token，必须 `xxx*`；中期可换 trigram 分词器支持中间词 |
| 搜索词按短语包引号 | 用户输入里的 `-`、`+`、`:`、引号等不能变成 FTS5 查询语法 |
| 扫描按 mtime + 大小增量 | 万级曲库重复扫描不必重读全部文件；扫描后顺带清理已删除记录 |
| 单一 `Mutex<Option<Database>>` | 曲库操作量不大，串行化最省心；所有 db 函数统一走 `db::with_conn()`，`close_db` 后还能换路径 |
| 锁内不做磁盘 IO | `prune_missing_tracks` 先取 id、锁外 stat、再单事务删除，避免卡住其它查询 |
| 错误用 `anyhow::Result` 跨语言 | frb 会把 `Err` 转成 Dart 异常，UI 侧统一 catch 后提示 |
| 单文件解析包 `catch_unwind` | panic 穿过 FFI 会 abort 进程；损坏文件只应算一个 `failed` |
| 生成代码不入 lint、不手改 | 避免 codegen 与手工修改互相覆盖；CI 有专门一致性校验 |

## 5. 加一个功能的典型路径

以「按目录增量扫描」为例：

1. **Rust**：在 `rust/src/api/scan.rs` 实现函数（签名已冻结，若必须改签名先看 API_CONTRACT 的流程）。
2. **重新生成**：`flutter_rust_bridge_codegen generate`（会更新 `lib/src/rust/**` 与 `rust/src/frb_generated.rs`）。
3. **Dart**：在 `lib/src/features/...` 里调用生成的函数，处理 loading / 空态 / 失败。
4. **测试**：纯逻辑进 `test/`，需要原生库的进 `integration_test/`。
5. **本地全检**：`.\scripts\check.ps1`，然后按 PR 模板提交。

## 6. 状态管理

当前**不引入第三方状态管理**：页面内部用 `StatefulWidget` + `setState`，
跨页面共享的播放器状态在 M2 定方案（届时补本文档）。请勿单独引入 provider / riverpod /
bloc 等依赖 —— 需要时先开 issue 讨论后由 owner 统一加。

## 7. 测试分层

| 层 | 位置 | 运行环境 | 覆盖什么 |
|---|---|---|---|
| Dart 单元 / widget | `test/` | 纯 Dart，无原生库 | 组件渲染、格式化逻辑、状态流转 |
| Rust 集成 | `rust/tests/` | `cargo test` | SQLite/FTS5、扫描解析等真实依赖 |
| 端到端 | `integration_test/` | Windows 桌面 + 真实原生库 | 桥接自检、关键交互 |

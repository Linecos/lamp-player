# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- 音乐目录管理：设置页列出已添加的目录（持久化到 `shared_preferences`，大小写不敏感去重），支持逐个「重新扫描」与「从列表移除」；移除只删记录，不删除已入库曲目
- 自绘标题栏（无边框窗口）：隐藏系统标题栏，改为应用内的 36px 拖动区 + 最小化 / 最大化 / 关闭按钮，双击标题区切换最大化；底色与页面一致、不画分隔线（新增依赖 `window_manager`）
- 添加音乐目录：设置页与空曲库页面均可选择文件夹，调用 `scanFolder` 增量入库并显示扫描统计（新增 `file_selector` 依赖）
- 播放成功后写入播放历史，历史页面接入后可直接展示；历史写入失败不影响播放
- 启动时初始化曲库：`path_provider` 取应用支持目录 → `initDb`（新增依赖 `path` / `path_provider`）；曲库打不开时走启动兜底页并注明失败环节（`LampStartupErrorApp` 支持自定义标题）
- `lib/src/features/library/library_db.dart`：曲库路径解析带目录注入口，目标目录不存在自动创建；`test/features/library_db_test.dart` 覆盖纯 Dart 部分
- 曲库存储扩展：新增歌单 / 收藏 / 播放历史接口（`api::collections`）与 `Playlist` 模型；schema 升至 v2，曲目被清理时外键级联删除相关条目
- Dart `LibraryRepository` 增加歌单 / 收藏 / 历史方法，`FakeLibraryRepository` 提供同语义的内存实现
- Rust API 契约冻结：`db::*`、`scan::scan_folder`、`player::*`，签名见 `docs/API_CONTRACT.md`
- 扫描实现：`scan_folder` 支持 8 种扩展名、递归子目录、不跟随软链接；`lofty` 读标签、无标签用文件名兜底；整批单事务入库，单文件解析失败只计入 `failed` 不中断
- 扫描增量：记录 mtime/大小指纹，未变化文件跳过解析；扫描后清理该目录下已删除的记录（`ScanReport.unchanged` / `walk_errors` / `pruned`）
- `db::close_db`：释放曲库连接，支持切换库路径；`init_db` 带结构版本（`PRAGMA user_version`）与老库自动升级 + FTS 重建
- `rust/tests/db.rs`：upsert 去重、FTS 触发器同步、搜索容错、prune、路径切换、老库迁移
- 内部模块 `rust/src/scanner.rs`（遍历 + 标签解析，可脱离数据库测试）与 `rust/tests/scan.rs`（遍历过滤、缺失目录、扫描→入库→中文前缀检索、增量与清理）
- Dart 应用外壳：`LampApp` + 主题（Material 3，初始跟随系统，可在设置页切换）+ 路由表；桥接初始化失败时显示 `LampStartupErrorApp` 而不是白屏
- 设置页主题切换：跟随系统 / 浅色 / 深色，选择立即生效并写入 `shared_preferences`，重启后保留（PR #5；新增依赖 `shared_preferences`）
- 曲库页占位实现，纯 Dart 环境可渲染
- 协作设施：`CONTRIBUTING.md`、Issue 模板、CODEOWNERS、PR 模板、路线图与接口契约文档
- 一键脚本：`scripts/bootstrap.ps1`（环境准备）、`scripts/check.ps1`（本地全套检查）、`scripts/setup-labels.ps1`（标签初始化）
- CI：Windows 任务增加真实原生库的 `integration_test`

### 变更

- 界面横向基线与间距统一：顶栏由居中改为左对齐（与内容同为 16px 基线）、侧边栏图标列统一到 24px（列表与折叠按钮、品牌文字对齐）、播放条左右边距 12 → 16
- `rust/Cargo.toml` 的 `crate-type` 增加 `rlib`，让 Rust 集成测试能链接本 crate（Flutter 构建不受影响）
- `main.dart` 精简为「初始化桥接 + 挂载 `LampApp`」，去掉 frb 模板残留注释
- `analysis_options.yaml`：排除生成代码、启用单引号与 `unawaited_futures`
- CI：新增 `dart format` 检查；`cargo clippy -D warnings` 转为阻塞；缓存 codegen 二进制
- BASS 运行时：`setup-bass.ps1` 下载并校验官方 add-on（flac/opus/ape/wma），构建时由 CMake 把 DLL 拷进 bundle
- Windows 应用身份与窗口标题改为 `Lamp Player`（`path_provider` 的数据目录名随之确定）
- 移除未使用的 `dirs` 依赖

### 修复

- 中文字体走系统随机回退（Windows 上可能落到宋体/等线），导致汉字字形异形、同一段落字重忽粗忽细；现默认字体改为 **微软雅黑 Light**，并配中文字体回退链（雅黑 UI / 雅黑 / Segoe UI）
- 进度轮询任意一次异常就永久停止，进度条冻住但音乐继续播；现改为连续 3 次失败才停，期间继续重试
- 播完后进度条仍可拖动：seek 在已停止的流上会成功、UI 跟着变，但播放键从头重播，等于白拖；现停止态禁用滑块并在 `_onSeekEnd` 兜底
- 音量拖动每个事件都发一次 FFI 命令（`PlayerBar` 注释约定由页面节流，但页面没做）；现按 80ms 窗口合并，静音仍立即生效
- 设置页把 `upserted`（入库 + 更新）显示为「新增 X 首」，重扫改标签会误报；文案改为「入库 X 首」
- 集成测试 `initLibrary()` 未传目录，会打开 `%APPDATA%` 里的真实用户曲库；现改用临时目录并在结束时关闭连接
- `library_rail.dart` 顶部注释仍写着「详情页是占位、设置页只读、等 shared_preferences」，与实际不符
- 扫描合并历史路径时旧 `tracks` 行被直接删除，外键级联清空收藏 / 歌单 / 历史；现先迁移用户数据（歌单与收藏去重、历史合并播放次数）再删旧行
- 自然播完后按播放会走 `resume`，BASS 从流末尾继续而无法重播；现在检测到 `stopped` 时重新加载曲目
- 非 Windows 上扫描清理恒不生效：目录前缀写死 `\`，与 `path_key` 的 `/` 口径不一致（ubuntu CI 的 `cargo test` 会失败）
- 历史库里正斜杠或非 ASCII 大小写的路径无法与 canonicalize 后的路径合并（`COLLATE NOCASE` 只处理 ASCII、也不认分隔符），会残留重复记录；现按归一化 key 每批一次对账，顺带去掉了「每首歌一次全表扫描」
- `canonicalize` 会解析 junction/软链接：升级后首次扫描建议清库重扫，旧链接路径的记录不会自动迁移
- 扫描器声明支持 `wma`，但标签解析库 lofty 不支持 ASF/WMA，`.wma` 永远解析失败、不入库；现从候选扩展名中移除（契约文档同步）
- 路径比较区分大小写：`E:\Music` 与 `e:/music` 指同一目录时，增量指纹全部 miss、清理失配、`path UNIQUE` 不命中产生重复记录；现扫描入口 canonicalize 目录 + 路径 key 大小写无关归一化，并兼容历史大小写孪生行
- `.gitignore` 漏了 SQLite WAL 的 sidecar 文件（`*.lampdb-wal` / `*.lampdb-shm`）
- `db::upsert_tracks` 失败时不回滚事务，可能留下半批数据（现改为失败即回滚）
- 曲库连接获取不再 panic（未初始化 / 锁中毒时返回错误）
- `db::prune_missing_tracks` 返回值类型不匹配（`usize` → `i32`）
- 搜索含空串、`-`、`+`、`:`、引号等字符时 FTS5 直接报语法错误；现按词包成短语做前缀匹配，并按 bm25 排序
- `init_db` 忽略重复初始化结果，切换路径时会静默继续写旧库
- `upsert` / `prune` 改用 `transaction()`；prune 的磁盘检查移出全局锁
- 单个文件解析时底层库 panic 会终止进程；现按文件隔离为 `failed`
- Windows 构建产物缺少 `bass.dll`；`setup-bass.ps1` 不装 add-on，导致 flac/opus/ape/wma 无法播放（AAC/M4A 在 Windows 上走系统 codec）
- `check.ps1` 只设 `no_proxy` 不清代理变量，本机开着代理时 `flutter test` 失败
- 测试在曲库连接未关闭时删除临时目录（Windows 上失败且泄漏文件）

## [0.1.0] - 2026-10-21

> 首个骨架版本，尚未打 git tag；发布流程见 docs/ROADMAP.md 的 M3。

### 新增

- Flutter + Rust（flutter_rust_bridge v2）+ BASS 的项目骨架，仅支持 Windows 桌面端
- SQLite 曲库（`rusqlite` bundled，启用 FTS5 全文检索，含同步触发器与中文前缀检索验证）
- BASS 2.4 SDK 自动下载脚本（闭源库不入库）


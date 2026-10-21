# 路线图

> 想参与就挑一个任务，在对应 issue 里说一句「我来做」，避免两个人撞车。
> 标 **[入门]** 的任务不涉及核心链路，适合第一次提 PR。
> 状态：`待认领` / `进行中` / `已完成`。

## 当前阶段

项目处于 **M0 骨架完成、M1 进行中**：桥接、曲库 SQLite+FTS5、CI、协作设施已就位；
扫描与播放是存根，界面只有壳。

## M1 · 曲库闭环（扫描 → 入库 → 列表 → 搜索）

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| 实现 `scan::scan_folder`（walkdir 遍历 + lofty 标签 + 批量入库） | Rust `api/scan.rs` + `scanner.rs` | 中 | 已完成（`rust/tests/scan.rs` 覆盖） |
| 扫描增量（mtime + 大小）与扫描后清理已删除记录 | Rust `scanner.rs` + `api/db.rs` | 中 | 已完成（`ScanReport.unchanged` / `pruned`） |
| 启动时初始化曲库（取应用支持目录 → `init_db`） | Dart + 构建（需加 `path_provider`） | 中 | 已完成（`library_db.dart`，失败走启动兜底页） |
| 添加音乐目录（`file_selector`）+ 扫描中提示 | Dart `features/settings` | 中 | 待认领 |
| 曲库列表页（虚拟滚动，万级曲目不卡） | Dart `features/library` | 中 | 待认领 |
| 搜索框接 `search_tracks`，输入防抖 300ms | Dart `features/library` | 小 | 待认领 |
| `db` 单元测试：upsert 去重/更新、FTS 触发器同步、prune、迁移 | Rust `rust/tests/` | 小 | 已完成（`rust/tests/db.rs`） |
| 时长/文件大小格式化工具 + 单测 | Dart `common/` + `test/` | 小 | **[入门]** 待认领 |

## M2 · 出声与播放控制

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| `bass.rs`：libloading 加载 DLL、符号表、初始化/释放 | Rust | 大 | 待认领 |
| `player.rs` 实现（play/pause/resume/stop/seek/volume/position） | Rust `api/player.rs` | 中 | 待认领 |
| CMake 把 `bass.dll` 与 add-on 拷到 exe 目录 | `windows/` + 构建 | 小 | 已完成（install 规则，缺 DLL 时构建告警） |
| 播放条：播放/暂停、曲名、进度显示 | Dart `features/player` | 中 | 待认领 |
| 进度拖动、音量滑块（接 `player_seek` / `player_set_volume`） | Dart `features/player` | 小 | **[入门]** 待认领 |
| 设置页 + 深浅色主题切换（`shared_preferences` 持久化） | Dart `features/settings` | 中 | 待认领 |
| 空态 / 加载 / 错误重试通用组件 | Dart `common/widgets/` | 小 | **[入门]** 待认领 |

## M3 · 打磨与发布

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| 深色/浅色主题在真实曲库下走查 | Dart `theme/` + 页面 | 小 | 待认领 |
| 万级曲库扫描与列表性能压测，出数据 | 全体 | 中 | 待认领 |
| Windows release 构建实测 + 打包 zip（含 bass.dll 与许可说明） | 构建 | 中 | 待认领 |
| 打 tag + 发布 workflow（`v*` 触发，产物挂 Release） | CI | 中 | 待认领 |
| README 补截图 / GIF | 文档 | 小 | **[入门]** 待认领 |

## 模块归属

| 模块 | 文件域 | 负责人 |
|---|---|---|
| 曲库 / 数据模型 / 扫描 | `rust/src/api/{db,model,scan}.rs`、`docs/API_CONTRACT.md` | [@Linecos](https://github.com/Linecos) |
| 播放引擎（BASS） | `rust/src/bass.rs`、`rust/src/api/player.rs`、`windows/CMakeLists.txt` | [@qiya7698](https://github.com/qiya7698) |
| 主界面 | `lib/src/app/`、`lib/src/theme/`、`lib/src/features/` | [@starry688](https://github.com/starry688) |
| 设置页 / 通用组件 | `lib/src/features/settings/`、`lib/src/common/`、`test/` | [@yjxnb1](https://github.com/yjxnb1) |

> 归属只表示「优先由谁 review / 谁在写」，任何人提 PR 都欢迎。
> 想改别人负责的文件，先在 issue 里打个招呼即可。

## 完成定义（DoD）

一个任务算完成，需要同时满足：

1. CI 四项全绿（analyze/test、cargo、Windows 构建、frb 一致性）；
2. 本地 `flutter run -d windows` 实际验证过行为；
3. 新增逻辑有测试（分层见 [ARCHITECTURE.md](ARCHITECTURE.md#7-测试分层)）；
4. 动了接口就同步更新 [API_CONTRACT.md](API_CONTRACT.md) 与 `CHANGELOG.md`；
5. 按 PR 模板填写，一个 PR 只做一个主题。

## 如何认领

1. 在 issue 下留言「我来做这个」，owner 会把 issue 指派给你并加 `进行中` 标签；
2. 从 main 拉分支：`git checkout -b feat/xxx`；
3. 卡住了随时在 issue 里问，不要硬憋 —— 提前暴露问题比延期好。

没有对应 issue 的任务，直接按上面表单新建一个 issue 说明要做什么也可以。

# 路线图

> 想参与就挑一个任务，在对应 issue 里说一句「我来做」，避免两个人撞车。
> 标 `good first issue` 的任务不涉及核心链路，适合第一次提 PR。
> 状态：`待认领` / `进行中` / `已完成`（表内文字，不是 GitHub 标签）。

## 当前阶段

**M1 曲库闭环、M2 播放链路已完成，M3 打磨进行中**：桥接、扫描、SQLite + FTS5、BASS 播放、
主界面与搜索早已就位；此后逐项落地了元数据写回、自定义封面、音质分档、独占输出、
ReplayGain、均衡器、换曲淡变、频谱、SMTC、托盘与单实例、增强 LRC 歌词与桌面歌词、
听歌统计、界面字体、检查更新。本地已能打出便携 zip 与 Inno 安装包，**剩下的主要是
发布流水线（tag → 产物挂 Release）与文档截图**。逐项见下面各表与 `CHANGELOG.md`。

## M1 · 曲库闭环（扫描 → 入库 → 列表 → 搜索）

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| 实现 `scan::scan_folder`（walkdir 遍历 + lofty 标签 + 批量入库） | Rust `api/scan.rs` + `scanner.rs` | 中 | 已完成（`rust/tests/scan.rs` 覆盖） |
| 扫描增量（mtime + 大小）与扫描后清理已删除记录 | Rust `scanner.rs` + `api/db.rs` | 中 | 已完成（`ScanReport.unchanged` / `pruned`） |
| 启动时初始化曲库（取应用支持目录 → `init_db`） | Dart + 构建（需加 `path_provider`） | 中 | 已完成（`library_db.dart`，失败走启动兜底页） |
| 添加音乐目录（`file_selector`）+ 扫描中提示 | Dart `features/settings` | 中 | 已完成（设置页 / 空态入口 + 扫描统计） |
| 曲库列表页（虚拟滚动，万级曲目不卡） | Dart `features/library` | 中 | 已完成（PR #4，五种排序） |
| 搜索框接 `search_tracks`，输入防抖 300ms | Dart `features/library` | 小 | 已完成（PR #4） |
| 艺术家 / 专辑聚合视图 | Dart `features/library` | 中 | 已完成（PR #4） |
| `db` 单元测试：upsert 去重/更新、FTS 触发器同步、prune、迁移 | Rust `rust/tests/` | 小 | 已完成（`rust/tests/db.rs`） |
| 时长/文件大小格式化工具 + 单测 | Dart `common/` + `test/` | 小 | 已完成（`common/formatters` + `test/common/formatters_test.dart`） |
| 歌单 / 收藏 / 播放历史存储接口 | Rust `api/collections.rs` + `model.rs` | 中 | 已完成（schema v2，契约 v0.3） |
| 歌单 / 历史 / 收藏页面接入存储接口 | Dart `features/library` | 中 | 已完成（含播放全部、右键加入歌单） |

## M2 · 出声与播放控制

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| `bass.rs`：libloading 加载 DLL、符号表、初始化/释放 | Rust | 大 | 已完成（PR #3） |
| `player.rs` 实现（play/pause/resume/stop/seek/volume/position） | Rust `api/player.rs` | 中 | 已完成（PR #3） |
| CMake 把 `bass.dll` 与 add-on 拷到 exe 目录 | `windows/` + 构建 | 小 | 已完成（install 规则，缺 DLL 时构建告警） |
| 播放条：播放/暂停、曲名、进度显示 | Dart `features/player` | 中 | 已完成（PR #4，只读进度） |
| 播放成功后记录历史 + 自然播完自动下一首 | Dart `features/library` | 小 | 已完成（`PlaybackQueue` 接管切歌） |
| 播放队列：顺序 / 随机 / 列表循环 / 单曲循环、上一首历史、队列面板 | Dart `features/player` | 中 | 已完成（`playback_queue.dart` + `queue_dialog.dart`） |
| 播放全部（曲库 / 搜索 / 收藏 / 历史 / 歌单 / 艺术家 / 专辑） | Dart `features/library` | 小 | 已完成 |
| 快捷键（空格 / Ctrl+方向键 / Ctrl+M / Ctrl+F / Ctrl+L / Esc / 媒体键） | Dart `features/library` | 小 | 已完成（搜索框内不劫持输入） |
| 定位正在播放（音乐 / 收藏 / 历史 / 歌单列表，行短暂高亮） | Dart `features/library` | 小 | 已完成（`TrackListView.controller` + `TrackListView.rowExtent`） |
| 会话恢复（音量、上次曲目与进度、循环 / 随机、分区、侧栏、窗口尺寸） | Dart `app/` + `features/library` | 中 | 已完成（`shared_preferences`） |
| 专辑封面：提取内嵌图、按内容哈希缓存、列表 / 播放条展示 | Rust `scanner.rs` + Dart `common/widgets` | 中 | 已完成（schema v3，`covers/` 缓存） |
| 进度拖动、音量滑块（接 `player_seek` / `player_set_volume`） | Dart `features/player` | 小 | 已完成（进度拖动 + 音量滑块的合并节流） |
| 主题切换（跟随系统 / 浅色 / 深色，`shared_preferences` 持久化） | Dart `features/settings` | 小 | 已完成（PR #5） |
| 设置页其余交互（默认音量等） | Dart `features/settings` | 中 | 待认领 |
| 听歌统计：累计时长、播放次数排行、每日热力图（含 `play_sessions` 表） | Dart `features/settings` + Rust `api/collections.rs` | 中 | 已完成（issue #14，schema v4） |
| 空态 / 加载 / 错误重试通用组件 | Dart `common/widgets/` | 小 | 已完成（`common/widgets` + `test/common/widgets_test.dart`） |

**M2 之后追加（逐项落地，均已进 `CHANGELOG.md`）**

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| 独占输出：`BASS_WASAPI_Init` + bassmix（不重采样，掉线回落共享） | Rust `bass/wasapi.rs` + Dart `features/library` | 大 | 已完成（`scripts/setup-bass-output.ps1`） |
| 换曲淡变（0/1/2/4/6/8 秒，共享为真交叉淡变） | Rust `bass/windows.rs` | 中 | 已完成 |
| 10 段均衡器 + 预设（设置页与播放页共用弹窗） | Rust `bass` + Dart `features/player/equalizer.dart` | 中 | 已完成 |
| 频谱：引擎线程 FFT → 24 段分频 → frb 流 | Rust `bass/fft.rs` + Dart `features/player/spectrum_*` | 大 | 已完成（独占走回调抄样本自算） |
| ReplayGain：读标签 + 现场分析（-23/-18/-14 LUFS、采样/真峰值） | Rust `api/replaygain.rs` + Dart `common/audio/replay_gain.dart` | 大 | 已完成（schema v11 存测量值） |
| 元数据写回（12 字段 + 封面嵌入文件） | Rust `api/metadata.rs` + Dart `track_metadata_pane` | 中 | 已完成 |
| 自定义封面（艺术家 / 专辑 / 歌单，按内容哈希去重） | Rust `api/cover_override.rs` | 中 | 已完成（schema v9） |
| 音质分档（码率 / 采样率 / 位深 → 四档 + 环形图 + 档位子页） | Rust `scanner` + Dart `common/audio/audio_quality.dart` | 中 | 已完成（schema v10） |
| 增强 LRC 歌词：逐字、翻译、对齐、桌面对照窗口 | Rust `lyrics.rs` / `lyrics_ttml.rs` / `api/desktop_lyrics.rs` + Dart `features/player` | 大 | 已完成 |
| SMTC 播放模式同步（循环 / 随机按钮） | Rust `api/media.rs` + Dart `smtc_bridge` | 中 | 已完成（契约 v0.19） |
| 单实例 + 托盘（隐藏到托盘继续播放） | Rust `single_instance.rs` + Dart `app/tray_controller` | 中 | 已完成 |
| 听歌统计子页面（累计时长、排行、热力图） | Dart `features/settings/listening_stats_view` | 中 | 已完成（schema v4） |
| 歌单 M3U / M3U8 导入导出 | Dart `features/library/playlist_io.dart` | 小 | 已完成 |
| 多选批量（播放 / 入队 / 收藏 / 入歌单 / 隐藏 / ReplayGain） | Dart `features/library/sections/selection_section` | 中 | 已完成 |
| 界面字体与歌词字体（读本机字体，弹窗挑选） | Rust `api/fonts.rs` + `system_fonts.rs`，Dart `common/text/` | 中 | 已完成（契约 v0.23） |
| 睡眠定时 / 检查更新 / 平滑滚轮 | Dart `features/player/sleep_timer`、`app/update_check.dart`、`common/scroll` | 小 | 已完成 |

## M3 · 打磨与发布

| 任务 | 负责模块 | 难度 | 状态 |
|---|---|---|---|
| 深色/浅色主题在真实曲库下走查 | Dart `theme/` + 页面 | 小 | 待认领 |
| 万级曲库扫描与列表性能压测，出数据 | 全体 | 中 | 已完成（`docs/PERF.md`「复测（2026-11-19）」，复跑入口 `rust/examples/perf_probe.rs` / `tool/track_list_bench.dart`） |
| Windows release 构建实测 + 打包 zip（含 bass.dll 与许可说明） | 构建 | 中 | 已完成（`scripts/package.ps1`：便携 zip + Inno 安装包，中文语言包随仓库） |
| 全局媒体键（`RegisterHotKey`，SMTC 会话被抢时兜底） | Rust `global_hotkeys` + Dart `features/player` | 中 | **已撤回**：空闲时会独占别的播放器的键，暂停后释放又让播放键落不到本应用；媒体键统一交给 SMTC，热键代码已删除 |
| 打 tag + 发布 workflow（`v*` 触发，产物挂 Release） | CI | 中 | 待认领 |
| README 补截图 / GIF | 文档 | 小 | 进行中：浅色 / 深色四组截图已有，缺音乐库分区、音质环、播放页歌词；标 `good first issue` |

## 模块归属

| 模块 | 文件域 | 负责人 |
|---|---|---|
| 曲库 / 数据模型 / 扫描 / 元数据 | `rust/src/api/{db,model,scan,collections,metadata,cover_override}.rs`、`docs/API_CONTRACT.md` | [@Linecos](https://github.com/Linecos) |
| 播放引擎（BASS） | `rust/src/bass/`、`rust/src/api/player.rs`、`windows/CMakeLists.txt` | [@qiya7698](https://github.com/qiya7698) |
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

1. 在 issue 下留言「我来做这个」，owner 会把 issue 指派给你，并按 `enhancement` / `rust` / `flutter`
   这类标签标出所属模块（没有 `进行中` 标签，认领以指派为准）；
2. 从 main 拉分支：`git checkout -b feat/xxx`；
3. 卡住了随时在 issue 里问，不要硬憋 —— 提前暴露问题比延期好。

没有对应 issue 的任务，直接按上面表单新建一个 issue 说明要做什么也可以。

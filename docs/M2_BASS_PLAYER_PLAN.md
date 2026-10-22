# M2 播放引擎（BASS）实施计划

范围：`rust/src/bass.rs`（新建）、`rust/src/api/player.rs`、`windows/CMakeLists.txt`
契约：`docs/API_CONTRACT.md` v0.3 **不改签名**

## 现状

`player.rs` 10 个函数全是存根，`bass.rs` 不存在；BASS DLL 已由 `windows/CMakeLists.txt`
的 install 规则自动拷进 bundle。
依赖已就绪：`libloading`、`third_party/bass/windows/`（`x64/` 下已有 bass.dll + 5 个插件）。

## 关键决策

| 项 | 结论 |
|---|---|
| 线程 | 专用引擎线程 + mpsc 命令队列。frb 的 async 跑在共享 worker 池，`Mutex` 只保证互斥不保证同线程 |
| 状态读取 | `player_state` / `player_is_available` 是 sync 函数，只读 `AtomicU8` / `AtomicBool`，不进队列 |
| 文件路径 | `encode_utf16()` + `BASS_UNICODE`。BASS 默认按 ANSI 解析，中文路径会失败 |
| 音量 | `BASS_ATTRIB_VOL` 本身就是 `f32` 0~1，直接透传；**换曲后重置为 1.0，需重放** |
| 平台 | BASS 相关代码全部 `#[cfg(windows)]`，CI 的 rust job 跑在 ubuntu |
| 测试 | `BASS_Init` 传 `device = 0`（无输出），CI 上没有声卡 |

## PR 拆分

| # | 内容 | 体量 |
|---|---|---|
| 1 | ~~CMake 拷 `x64\*.dll`~~（已完成）+ `bass.rs` 加载 DLL/插件 + `is_available` 接真值 | S |
| 2 | 引擎线程 + 命令队列 + play/pause/resume/stop | M |
| 3 | position / duration / seek / volume + 边界 | M |
| 4 | 纯逻辑单测 + `integration_test` 播 1 秒 wav | S |
| 5 | 错误码翻译（`BASS_ErrorGetCode` → 可读文案） | S |

## 待对齐：格式覆盖

扫描支持 8 种格式（不含 wma：`lofty` 不支持 ASF，`.wma` 会被直接忽略）。
基础 `bass.dll` 只解 mp3 / ogg / wav / aiff；flac / opus / ape / wma 由
`scripts/setup-bass.ps1` 安装，m4a / aac 需要 `scripts/setup-bass-plugins.ps1`
额外补 `bass_aac.dll`。

需 @Linecos 确认：

- M2 是否直接启用全部插件（建议启用，成本已沉没）；
- wma 可以播放但扫描不入库，是否需要给 wma 加「按文件名入库」的兜底；
- 是否要在 `Track` 上加 `playable` 标记 —— 属于改模型，走契约流程，不在本计划内。

## 风险

| 风险 | 应对 |
|---|---|
| 中文路径解码失败 | UTF-16 + `BASS_UNICODE`，验收必须用中文名文件 |
| 单个插件缺失拖垮引擎 | 逐个 `BASS_PluginLoad`，失败的记录后继续 |
| release 漏拷 DLL | `windows/CMakeLists.txt` 的 `install(FILES ...)` 规则，Debug/Release 都覆盖 |

## 参考实现

[ZeroBit-Player](https://github.com/Empty-57/ZeroBit-Player)（同为 Flutter + Rust + FRB + BASS）。

**插件机制**：`BASS_PluginLoad(utf16_path, BASS_UNICODE)` 逐个注册 addon，之后
`BASS_StreamCreateFile` 自动识别格式，解码逻辑零改动，DLL 放 exe 同级目录。

**别照抄**：任一插件缺失就 `?` 抛出，导致整个引擎不可用；DLL 靠手动拷到
Debug/Profile/Release 三个目录；BASS 调用没有线程收敛。

**值得抄**：`StreamSink` 推状态与进度替代轮询；切歌用世代号（`AtomicU64`）比对、
回调里不加锁；音量用 `BASS_ChannelSlideAttribute` 淡入淡出；独立错误码翻译表。

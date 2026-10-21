# M2 播放引擎（BASS）实施计划 —— @qiya7698

> 范围：`rust/src/bass.rs`（新建）、`rust/src/api/player.rs`、`windows/runner/CMakeLists.txt`
> 契约：`docs/API_CONTRACT.md` v0.1 **不改签名**；内部实现细节自由
> 状态基线：main @ `9e7faa8`，`player.rs` 全部为存根，`bass.rs` 不存在，`bass.dll` 已在 `third_party/`

---

## 1. 现状盘点

| 项 | 现状 |
|---|---|
| `rust/src/api/player.rs` | 10 个函数全是存根，`is_available()` 硬编码 `false`，其余直接 `bail!` |
| `rust/src/bass.rs` | **不存在**（`lib.rs` 文档注释里提到了，但没 `pub mod bass;`） |
| `libloading` | 已在 `Cargo.toml`（0.9.0），依赖就绪 |
| `third_party/bass/windows/` | `x64/bass.dll` / `x86/bass.dll` / `bass.h` 已就位（`setup-bass.ps1` 已跑通） |
| `windows/runner/CMakeLists.txt` | **没有** 拷 DLL 的 POST_BUILD，`flutter run` 时 exe 目录没有 `bass.dll` |
| 测试 | `rust/tests/` 有 fts5/scan，没有 player；`integration_test/` 只有桥接自检 |

**结论**：从 0 到 1，必须先解决"DLL 能加载"和"线程模型"，这两个定不下来后面全是返工。

---

## 2. 核心设计决策（先定，再写代码）

### 2.1 线程模型：专用引擎线程 + 命令队列

`player.rs` 的注释要求"所有 BASS 调用都在同一个线程里做"，但 frb 的 `async` 函数跑在**共享 worker 线程池**上，同一函数可能落在不同线程，`Mutex` 只能保证互斥、不保证同线程。

采用**单线程 owner + mpsc**：

```rust
enum Cmd {
    Play(String), Pause, Resume, Stop,
    Seek(f64), SetVolume(f64),
    Position(Reply<f64>), Duration(Reply<f64>),
}
```

- `std::sync::mpsc::channel` + 每条命令自带 `Sender<Result<T>>` 作为回执通道，**不引入新依赖**。
- 引擎线程用 `recv_timeout(Duration::from_millis(200))` 做主循环：
  - `Ok(cmd)` → 处理并回执；
  - `Err(Timeout)` → 执行一次 `tick()`（刷新状态），顺手解决"曲目自然播完"的检测，**不需要额外定时器线程**；
  - `Err(Disconnected)` → `BASS_Free()` 后退出。

### 2.2 两个 `sync` 函数绝不能碰 BASS

`player_is_available()` / `player_state()` 会在 `build()` 里被调用，一旦走队列就阻塞 UI。用原子量：

```rust
static AVAILABLE: AtomicBool;          // DLL 加载 + BASS_Init 成功
static STATE:     AtomicU8;            // 0=Stopped 1=Playing 2=Paused
```

引擎线程每次处理完命令、每次 `tick()` 都写 `STATE`；`sync` 函数只读原子量，零开销。

### 2.3 中文路径必须走 UTF-16

BASS 2.4 的 `BASS_StreamCreateFile` 默认按 **ANSI** 解析 `file` 参数，中文/日文路径会直接失败。
必须 `path.encode_utf16().chain(std::iter::once(0)).collect::<Vec<u16>>()` 并传 `BASS_UNICODE`（`0x80000000`）。
**这是最容易漏、且只在中文环境下暴露的坑。**

### 2.4 音量不要再"换算成 0..10000"

`player.rs` 现有注释写"内部再换算成 BASS 的 `0..10000`"，这是错的：
`BASS_ChannelSetAttribute(h, BASS_ATTRIB_VOL, v)` 的 `v` 本身就是 **`f32`，0.0~1.0（>1 为放大）**。
实现时直接透传，并顺手把这条注释改对（注释不属于契约，不需要走契约流程）。

另外：音量是 **per-channel** 属性，**换曲后会自动回到 1.0**，引擎必须缓存 `current_volume` 并在每次 `StreamCreateFile` 后重新 `SetVolume`。

### 2.5 时长单位换算

- `BASS_ChannelGetLength(h, BASS_POS_BYTE)` → `BASS_ChannelBytes2Seconds(h, len)` = 总时长
- `BASS_ChannelGetPosition(h, BASS_POS_BYTE)` → `BASS_ChannelBytes2Seconds` = 当前进度
- `BASS_ChannelSetPosition(h, BASS_ChannelSeconds2Bytes(h, secs), BASS_POS_BYTE)` = seek
- 建流时加 `BASS_STREAM_PRESCAN`：本地文件 IO 快，换来 MP3(VBR) 时长与 seek 准确。若发现大文件打开变慢，再按格式关掉。

### 2.6 状态语义映射

| BASS_ACTIVE_* | PlaybackState |
|---|---|
| `PLAYING` / `STALLED` | `Playing` |
| `PAUSED` / `PAUSED_DEVICE` | `Paused` |
| `STOPPED` | `Stopped` |

`player_stop` 契约是"停止**并释放**"→ `ChannelStop` + `StreamFree` + `hstream = 0`。
`player_play` 契约是"先停旧曲"→ 同样先 `stop_free()` 再建流。

### 2.7 CI 在 Ubuntu 上跑，`bass.rs` 必须 `cfg` 隔离

`ci.yml` 的 `rust` job 是 `ubuntu-latest`。所有 Windows 相关代码包在 `#[cfg(windows)]`，
非 Windows 分支提供"永远 `false` / `bail!("BASS 仅支持 Windows")" 的桩，保证 `cargo check --all-targets`、`clippy -D warnings`、`cargo test` 在 Linux 全绿。

---

## 3. PR 拆分（按依赖顺序，每个 PR 单一主题）

### PR1 · `feat(player): 加载 bass.dll 并暴露真实可用性` 【S】

- `windows/runner/CMakeLists.txt`：POST_BUILD 拷 `bass.dll` 到 `$<TARGET_FILE_DIR:${BINARY_NAME}>`（Debug/Release 都覆盖，源文件不存在时**不报错**，只是跳过）。
- 新建 `rust/src/bass.rs`：`libloading` 加载 + 符号表 + `BASS_Init(device, 44100, 0, null, null)` + `BASS_Free`；`once_cell::sync::Lazy` 单例。
- `rust/src/lib.rs`：加 `pub mod bass;`（改一行，PR 里 @Linecos 打个招呼）。
- `player_is_available()` 返回真实值。
- **验收**：`flutter run -d windows` 后 `playerIsAvailable() == true`；手动删掉 exe 旁的 `bass.dll` 应返回 `false` 且不崩。

### PR2 · `feat(player): 引擎线程与播放控制` 【M】

- 引擎线程 + 命令队列 + `STATE` 原子量（2.1 / 2.2）。
- 实现 `play / pause / resume / stop`（含 UTF-16 路径、`current_volume` 重放、错误码翻译）。
- `player_state()` 接原子量。
- **验收**：能连续播两首不同格式的歌；暂停后 `playerState()` 为 `Paused`；播完自动回到 `Stopped`（靠 `tick()`）。

### PR3 · `feat(player): 进度、时长、跳转与音量` 【M】

- `player_position / player_duration / player_seek / player_set_volume`。
- 边界：未加载返回 `0.0`；`seek` 负数或超时长报错（契约 6 写明）；音量 `clamp(0.0, 1.0)` 后透传。
- **验收**：拖动进度条跳转后 `position` 立即变化；音量 0 静音、1 最大、越界不报错。

### PR4 · `test(player): 播放引擎测试与无设备兜底` 【S】

- 纯逻辑抽函数单测：音量 clamp、状态映射、秒↔字节换算（不依赖 DLL，Ubuntu CI 可跑）。
- `rust/tests/player_smoke.rs`：`player_is_available()` 为 false 时直接 return（CI 跳过），本地可真跑。
- `integration_test/player_test.dart`：用 `assets` 里 1 秒静音 wav，断言 `duration > 0`、播放 300ms 后 `position > 0`、`pause → Paused`。
- **CI 无音频设备的处理**：`BASS_Init` 的 `device` 传 **`0`** 表示"无输出设备"，本地/CI 都能初始化成功；生产仍传 `-1`（默认设备）。用编译期或环境变量切换，不要写死。

### PR5 · `chore(player): 插件加载与格式覆盖` 【S，需先和 Linecos 对齐】

见第 4 节。插件 DLL 已由 `scripts/setup-bass-plugins.ps1` 备好，本 PR 负责在 `bass.rs` 里逐个 `BASS_PluginLoad`（失败不中断）。最小实现：`StreamCreateFile` 失败时按 `BASS_ErrorGetCode()` 给出中文可读错误（"文件不存在" / "该格式暂不支持" / "解码器初始化失败"）。

---

## 4. 必须先对齐的一个范围问题（最高风险）

扫描层支持的扩展名见 `rust/src/scanner.rs:15` 的 `AUDIO_EXTENSIONS`
（`mp3 flac wav ogg m4a aac wma ape opus`，**9 种**），但 `bass24.zip` 里的基础 `bass.dll` 只能解 **MP3 / OGG / WAV / AIFF**，即扫描清单里只有 **3/9** 开箱可播：

- **FLAC** → 需 `bassflac.dll`
- **OPUS** → 需 `bassopus.dll`
- **M4A / AAC** → 需 `bass_aac.dll`（Windows 上也可用 `basswma`/MF）
- **APE** → 需 `bassape.dll`
- **WMA** → 需 `basswma.dll`

也就是说：**扫得进曲库的 9 种格式里，有 6 种（FLAC/OPUS/M4A/AAC/APE/WMA）现在放不出声**。三个选项：

| 方案 | 代价 | 建议 |
|---|---|---|
| A. 只支持基础格式，播不了就提示 | 0 成本，但体验缺口明显 | **先做 A 保底**（PR5） |
| B. 补 `bassflac` + `bassopus` 两个插件 | 改 `setup-bass.ps1` 下载清单 + CMake 多拷 2 个 DLL + 许可证说明 | **M3 前做 B**（覆盖 FLAC/OPUS 这两类最常见）；**同栈的 ZeroBit-Player 已验证可行，见附录 A** |
| C. 换解码器（symphonia） | 偏离"BASS 播放引擎"的项目定位 | 不做 |

**动作**：在 issue 里 @Linecos 拍板 A→B 的节奏；同时提一句"扫描是否要在 `Track` 上标记 `playable`"——那属于改模型，得走 `API_CONTRACT.md` 的流程，别自己动。

> **方案 B 的工具已就绪**：`scripts/setup-bass-plugins.ps1`（幂等、单插件失败不中断、按 9 种格式逐个核对），
> 一次下载 `bassflac` / `bassopus` / `bass_aac` / `bassape` / `basswma` 五个插件到
> `third_party/bass/windows/{x64,x86}/`。跑完九种格式全部为「可播放」。

---

## 5. 风险清单

| 风险 | 影响 | 应对 |
|---|---|---|
| 中文路径解码失败 | 用户库里大量中文文件名放不出 | 2.3，UTF-16 + `BASS_UNICODE`，必须有中文路径的真实用例验证 |
| CI（Ubuntu）编不过 | PR 直接红 | 2.7，全部 `#[cfg(windows)]` |
| CI（Windows）无声卡 → `BASS_Init` 失败 | 集成测试挂 | `device = 0` 无设备模式 |
| `clippy -D warnings` 卡 `dead_code` | 符号表字段"未使用" | 符号表字段全部实际用到，或用 `#[allow(dead_code)]` 并写明原因 |
| DLL 只在开发目录、release 漏拷 | 发布版无声 | CMake `if(EXISTS)` + 两种配置都拷；M3 打包时再核一次 |
| 退出时未 `BASS_Free` | 设备占用、偶发爆音 | 引擎线程 `Disconnected` 分支释放；必要时注册 `atexit` |
| 32/64 位 DLL 混用 | 加载失败且报错含糊 | 只拷 `x64/`；错误信息里带上"位数不匹配"提示 |
| BASS 授权 | 商业分发违规 | README/关于页注明 un4seen 的免费使用条款（M3 打包时处理） |

---

## 6. 与队友的接口（不用改契约，但要提前打招呼）

| 对象 | 需要他们知道的 |
|---|---|
| **starry688**（播放条） | 进度/状态用**轮询**：建议 300ms 一次 `playerPosition()` + `playerState()`（`playerState` 是 sync，可直接在 build 里读）；`playerPlay` 可能抛异常，必须 catch 后提示；`playerIsAvailable()==false` 时禁用播放按钮并给降级文案 |
| **yjxnb1**（音量滑块） | `playerSetVolume` 只收 `0.0~1.0`，越界自动截断不报错；拖动时**节流 60~100ms**，别每帧调 FFI；音量是"应用音量"，不是系统音量 |
| **Linecos**（owner） | ① 第 4 节格式范围拍板；② "播完自动下一首"若要做，属于**新增**接口（事件流 `StreamSink` 或 `player_play_next`），走契约流程，M2 不做；③ PR1 改 `lib.rs` 一行 |

---

## 7. 完成定义自查（对着 ROADMAP 的 DoD）

- [ ] `.\scripts\check.ps1` 四项全绿（analyze / test / fmt / clippy）
- [ ] `flutter run -d windows` 实机验证：播 mp3、播中文路径文件、暂停续播、拖进度、调音量、播完回 Stopped
- [ ] 新增逻辑有测试（PR4）
- [ ] 未改签名 → 不需要动 `API_CONTRACT.md`；只改 `player.rs` 注释
- [ ] PR 模板填写，一 PR 一主题

---

## 附录 A · 参考实现拆解：ZeroBit-Player 怎么支持多格式

参考仓库：`E:/study/git demo\ZeroBit-Player`（同为 Flutter + Rust + FRB + BASS + Windows）

### A.1 机制：BASS 插件架构 + `BASS_PluginLoad`

BASS 本体只解码 MP3 / OGG / WAV / AIFF，其余格式全部由**独立的 addon DLL** 提供。
只要在 `BASS_Init` 之后把插件加载进来，之后 `BASS_StreamCreateFile` 就**自动识别**这些格式，
**解码/播放业务代码一行都不用改**。这是 BASS 最有价值的设计。

他的实现（`rust/src/api/bass.rs`）：

```rust
const PLUGIN_NAME: [&str; 8] = [
    "bassflac.dll", "bassmidi.dll", "basswv.dll", "bassopus.dll",
    "bassdsd.dll", "bassalac.dll", "basswebm.dll", "bassape.dll",
];
const BASS_DLL_DIR: &str = "BASSDLL";

// 位于 BassApi::load() 内，紧接 BASS_Init 之后（第 458-468 行）
for i in PLUGIN_NAME {
    let addons_path = parent.join(BASS_DLL_DIR).join(i);   // <exe目录>/BASSDLL/xxx.dll
    let path: Vec<u16> = OsStr::new(&addons_path)
        .encode_wide().chain(iter::once(0)).collect();
    let r = (self.plugin_load)(path.as_ptr() as *const _, BASS_UNICODE);
    self.or_err_(r as i32)?;                                 // ← 这里有问题，见 A.3
}
```

`parent` 来自 `env::current_exe()`，即**可执行文件同级目录**下的 `BASSDLL/` 子目录。

### A.2 格式 → 插件对照（他能播 / 不能播）

| 格式 | 需要的 DLL | ZeroBit |
|---|---|---|
| mp3 / ogg / wav / aiff | 内置，无需插件 | ✅ |
| flac | `bassflac.dll` | ✅ |
| opus | `bassopus.dll` | ✅ |
| ape | `bassape.dll` | ✅ |
| alac / m4a(ALAC) | `bassalac.dll` | ✅ |
| wavpack | `basswv.dll` | ✅ |
| dsd (dff/dsf) | `bassdsd.dll` | ✅ |
| midi | `bassmidi.dll` | ✅ |
| webm | `basswebm.dll` | ✅ |
| **aac / m4a(AAC)** | `bass_aac.dll` | ❌ **没装** |
| **wma** | `basswma.dll` | ❌ **没装** |

> 注意：他**也没解决 AAC 和 WMA**。`bassalac` 只管 Apple Lossless，`m4a` 里的 AAC 编解码仍然放不出来。
> 他的文档自己也承认："若某格式能扫描但无法播放，优先检查文件是否损坏、是否为不支持的编码变体。"
> —— 和我们遇到的是**同一个问题**，不是我们独有的坑。

### A.3 他做得不好的三件事（别照抄）

1. **插件缺失 = 引擎直接不可用**
   `or_err_(r as i32)?` 在任何一个 `BASS_PluginLoad` 返回 0 时直接把错误抛出 `load()`，
   整个播放引擎初始化失败。用户少放一个 DLL，全曲库都没声音。
   → **我们应该**：逐个加载，失败的只记日志/记入能力表，继续加载下一个。

2. **DLL 全靠手动拷**
   他的 `docs/dev/build.md` 要求用户到 `Debug`、`Profile`、`Release` **三个目录各建一次 `BASSDLL/` 并手动拷 11 个 DLL**，仓库里不放任何 DLL 也没有 CMake 步骤。
   → **我们**有 `windows/runner/CMakeLists.txt` 这个位置，做 POST_BUILD 自动拷贝，一次到位。

3. **BASS 调用没有线程收敛**
   他用 `static BASS_API: Lazy<Mutex<Option<BassApi>>>`，由 frb 的 worker 线程直接加锁调用。
   能跑（BASS 本身线程安全），但违反我们 `player.rs` 注释里"所有 BASS 调用在同一线程"的约定。
   → **我们**按计划 2.1 的命令队列走；若要简化，得先在 issue 里跟 Linecos 把注释改掉。

### A.4 他做得好的五件事（值得抄）

| 点 | 做法 | 对我们的价值 |
|---|---|---|
| **事件流替代轮询** | frb `StreamSink<u32>` 推状态（0 停止/1 播放/2 暂停/3 自然结束）、`StreamSink<f64>` 推进度 | 契约 6 说"M2 先轮询、后续换事件流"——这就是标准答案；`StreamSink` 在 frb 2.x 已验证可行 |
| **世代号防串台** | `STREAM_GENERATION: AtomicU64`，切歌自增；`on_end_sync` 回调只比对世代号，**刻意不加锁**避免阻塞 BASS 播放线程 | 解决"上一首的结束回调把下一首也停了"的经典竞态，我们 PR2 就该有 |
| **音量淡入淡出** | `BASS_ChannelSlideAttribute(BASS_ATTRIB_VOL, ..., 500ms)` | 暂停/播放/切歌不爆音，成本极低 |
| **音量读回校验** | 用 `BASS_ChannelGetAttribute` 读实际值，而不是只维护自己的变量 | 避免状态漂移（我们 PR3 用得上） |
| **错误码翻译表** | 独立 `bass_errs.rs`，`get_err_info(code)` | 我们 PR5 的可读错误文案直接对标 |

### A.5 他额外做的高级功能（M3 可选）

- **`basswasapi` 独占输出**：`WASEXCLUSIVE` 开关 + `BASS_WASAPI_Init(..., buffer=0.05s, ...)`，绕开系统重采样、延迟更低。
- **`bass_fx` 变速变调**：`BASS_FX_TempoCreate` + `BASS_FXSetParameters`，进度 tick 也跟着倍速调整（`BASE_TICK / speed`）。
- **10 段 EQ**：80Hz~16kHz，`BASS_ChannelSetFX` 挂 DX8 效果 + `BASS_FXSetParameters`。
- **ReplayGain**：`REPLAYGAIN_SCALE` 做响度归一，切专辑不炸耳朵。
- **静音跳过**：`BASS_ChannelGetData` 分析首尾静音，命中则提前触发切歌（`current_end_sec`）。
- **SMTC 系统媒体控制**：`windows` crate 的 `Media_Playback` 特性，接 Windows 媒体键、任务栏浮层、曲名封面。桌面播放器基本算及格线功能。

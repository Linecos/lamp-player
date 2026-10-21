# 接口契约（Rust ↔ Dart）

> **当前版本：v0.1（2026-10-21 冻结）**
>
> 本文档是 Flutter 与 Rust 之间的唯一约定。签名与本文不一致的 PR 不会合并。

## 1. 改动契约的流程

1. 先开 issue 说明为什么要改（新增字段？改单位？改返回类型？）。
2. owner 确认后，在**同一个 PR** 里同时完成：
   - 改 `rust/src/api/**`；
   - 跑 `flutter_rust_bridge_codegen generate`，提交生成结果；
   - 更新本文档与 `CHANGELOG.md`。
3. 破坏性改动（删字段、改语义）需要给出 Dart 侧的迁移说明。

**纯新增**（加一个函数、加一个有默认值的字段）只需照上面前两步做，不算破坏性改动。

## 2. 通用约定

| 约定 | 说明 |
|---|---|
| 命名 | Rust `snake_case` → Dart `camelCase`（`player_seek` → `playerSeek`） |
| 错误 | Rust 返回 `anyhow::Result<T>`，Dart 侧得到 `Future` 抛异常；UI 必须 catch |
| 时间 | 一律**秒**（`double` / `f64`），不传毫秒；时间戳用 `i64` 秒 |
| 音量 | `0.0..=1.0`，超出范围由实现截断，不报错 |
| 路径 | 绝对路径，`String`（Windows 反斜杠不做转换） |
| 大数据 | 列表一律整包返回，暂不分页；`search_tracks` 用 `limit` 限制 |

## 3. 数据模型

### `Track`（`rust/src/api/model.rs`）

| Rust 字段 | Dart 字段 | 类型 | 说明 |
|---|---|---|---|
| `path` | `path` | `String` | 文件绝对路径，**唯一键** |
| `title` | `title` | `String` | 展示标题；无标签时用文件名兜底 |
| `artist` | `artist` | `String?` | 可空 |
| `album` | `album` | `String?` | 可空 |
| `duration_secs` | `durationSecs` | `double` | 时长（秒），未知为 `0` |
| `track_num` | `trackNum` | `int?` | 专辑内曲目号，未知为空或 `0` |
| `added_at` | `addedAt` | `int` | 入库时间戳（Unix 秒） |

### `ScanReport`（`rust/src/api/scan.rs`）

| Rust | Dart | 类型 | 说明 |
|---|---|---|---|
| `scanned` | `scanned` | `int` | 遍历到的候选文件数 |
| `upserted` | `upserted` | `int` | 入库/更新的曲目数 |
| `failed` | `failed` | `int` | 解析失败被跳过的文件数 |
| `elapsed_ms` | `elapsedMs` | `int` | 耗时（毫秒） |

### `PlaybackState`（枚举）

`Stopped` / `Playing` / `Paused` → Dart 同名枚举值。

## 4. 曲库 `api::db`

| Rust 签名 | Dart 签名 | 状态 |
|---|---|---|
| `init_db(path: String) -> Result<()>` | `Future<void> initDb({required String path})` | 已实现 |
| `all_tracks() -> Result<Vec<Track>>` | `Future<List<Track>> allTracks()` | 已实现 |
| `search_tracks(query: String, limit: i32) -> Result<Vec<Track>>` | `Future<List<Track>> searchTracks({required String query, required int limit})` | 已实现 |
| `upsert_tracks(tracks: Vec<Track>) -> Result<i32>` | `Future<int> upsertTracks({required List<Track> tracks})` | 已实现 |
| `prune_missing_tracks() -> Result<i32>` | `Future<int> pruneMissingTracks()` | 已实现 |

语义补充：

- `init_db` 幂等：重复调用复用已有连接；未初始化就调用其它 db 函数会返回错误而不是 panic。
- `search_tracks` 采用**前缀匹配**（`query` 自动补 `*`），`limit` 截断到 `1..=2000`。
  中文不做分词，搜「周杰」能命中「周杰伦」，搜「杰伦」命中不了 —— 这是已知限制。
- `upsert_tracks` 在单个事务里完成，失败回滚；返回本次处理的条数（不等于实际新增数）。
- `prune_missing_tracks` 只清理磁盘上已不存在的 `path` 记录。

## 5. 扫描 `api::scan`

| Rust 签名 | Dart 签名 | 状态 |
|---|---|---|
| `scan_folder(folder: String) -> Result<ScanReport>` | `Future<ScanReport> scanFolder({required String folder})` | 已实现 |

语义补充：

- 递归子目录，**不跟随软链接**（避免目录环）；支持的扩展名：
  `mp3 flac wav ogg m4a aac wma ape opus`（不区分大小写）。
- 解析结果直接入库（内部调 `upsert_tracks`），调用方拿 `ScanReport` 刷新列表即可；
  已存在的曲目按 `path` 更新，重复扫描不会产生重复记录。
- **单个文件解析失败只计入 `failed`，不影响其它文件入库**；目录不存在或曲库未初始化才整体报错。
- 无标签时标题用文件名（去扩展名）兜底；解析出的 `duration_secs` 为真实时长。
- 大目录扫描在 frb 的 worker 线程执行，不阻塞 UI；进度上报留待后续**新增** `StreamSink`
  接口，不改动本签名。

## 6. 播放 `api::player`

| Rust 签名 | Dart 签名 | 同步 | 状态 |
|---|---|---|---|
| `player_is_available() -> bool` | `bool playerIsAvailable()` | 是 | **存根** |
| `player_play(path: String) -> Result<()>` | `Future<void> playerPlay({required String path})` | 否 | **存根** |
| `player_pause() -> Result<()>` | `Future<void> playerPause()` | 否 | **存根** |
| `player_resume() -> Result<()>` | `Future<void> playerResume()` | 否 | **存根** |
| `player_stop() -> Result<()>` | `Future<void> playerStop()` | 否 | **存根** |
| `player_seek(position_secs: f64) -> Result<()>` | `Future<void> playerSeek({required double positionSecs})` | 否 | **存根** |
| `player_set_volume(volume: f64) -> Result<()>` | `Future<void> playerSetVolume({required double volume})` | 否 | **存根** |
| `player_position() -> Result<f64>` | `Future<double> playerPosition()` | 否 | **存根** |
| `player_duration() -> Result<f64>` | `Future<double> playerDuration()` | 否 | **存根** |
| `player_state() -> PlaybackState` | `PlaybackState playerState()` | 是 | **存根** |

语义补充：

- `player_is_available` / `player_state` 是**同步**函数（只读状态），可以在 `build` 里直接用；
  其余均为 `Future`，不要在 `build` 里调用。
- `player_play` 会先停止当前曲目再加载新文件；文件不存在或格式不支持时返回错误。
- `player_position` / `player_duration` 在未加载曲目时返回 `0.0`，不报错。
- 状态推进由 Dart 侧轮询（M2 先用轮询，后续可换事件流）。

## 7. 桥接自检 `api::simple`

| Rust | Dart | 用途 |
|---|---|---|
| `greet(name: String) -> String`（sync） | `String greet({required String name})` | 只用于 `integration_test` 验证 FFI 通路，**不承载业务语义** |

## 8. 生成代码规则

- `lib/src/rust/**`、`rust/src/frb_generated.rs` 全部由 codegen 产出，**禁止手改**。
- 提交前用 `git status` 确认生成文件与 Rust 源码是同一批改动。
- CI 的 `frb 生成代码一致性` 任务会重新生成并比对，不一致直接失败。

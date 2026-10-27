# 接口契约（Rust ↔ Dart）

> **当前版本：v0.4（2026-10-23）**
>
> 本文档是 Flutter 与 Rust 之间的唯一约定。签名与本文不一致的 PR 不会合并。
>
> v0.4 变更：`Track` 新增 `cover_path`（内嵌封面缓存路径）；曲库结构升到 v3
> （`user_version = 3`），升级时清零文件指纹以补封面。纯新增字段，不改现有语义。
>
> v0.3 变更：新增 `api::collections`（歌单 / 收藏 / 播放历史）与 `Playlist` 模型；
> 曲库结构升到 v2（`user_version = 2`）。均为纯新增。
>
> v0.2 变更：新增 `db::close_db`；`ScanReport` 新增 `unchanged` / `walk_errors` / `pruned`；
> `search_tracks` 修正特殊字符处理（不再报 FTS5 语法错误）并改为 bm25 排序。

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
| `added_at` | `addedAt` | `PlatformInt64` | 入库时间戳（Unix 秒；native 上就是 `int`，web 上是 `BigInt`） |
| `cover_path` | `coverPath` | `String?` | 内嵌封面的缓存文件绝对路径；无封面或提取失败为空 |

### `Playlist`（`rust/src/api/model.rs`）

| Rust 字段 | Dart 字段 | 类型 | 说明 |
|---|---|---|---|
| `id` | `id` | `PlatformInt64` | 歌单 id |
| `name` | `name` | `String` | 去首尾空白后非空，忽略 ASCII 大小写唯一 |
| `track_count` | `trackCount` | `int` | 曲目数 |
| `created_at` | `createdAt` | `PlatformInt64` | 创建时间戳（Unix 秒） |
| `updated_at` | `updatedAt` | `PlatformInt64` | 最近一次改名 / 增删曲目的时间戳（Unix 秒） |

### `ScanReport`（`rust/src/api/scan.rs`）

| Rust | Dart | 类型 | 说明 |
|---|---|---|---|
| `scanned` | `scanned` | `int` | 遍历到的候选文件数（含未变化与解析失败的） |
| `unchanged` | `unchanged` | `int` | 因 mtime/大小未变而跳过解析的文件数 |
| `upserted` | `upserted` | `int` | 本次入库/更新的曲目数 |
| `failed` | `failed` | `int` | 解析失败被跳过的文件数 |
| `walk_errors` | `walkErrors` | `int` | 遍历时读不到的条目数（权限、IO 错误等） |
| `pruned` | `pruned` | `int` | 本次清理掉的「文件已不存在」记录数 |
| `elapsed_ms` | `elapsedMs` | `PlatformInt64` | 耗时（毫秒；native 上就是 `int`） |

### `PlaybackState`（枚举）

`Stopped` / `Playing` / `Paused` → Dart 同名枚举值。

## 4. 曲库 `api::db`

| Rust 签名 | Dart 签名 | 状态 |
|---|---|---|
| `init_db(path: String) -> Result<()>` | `Future<void> initDb({required String path})` | 已实现 |
| `close_db() -> Result<()>` | `Future<void> closeDb()` | 已实现 |
| `all_tracks() -> Result<Vec<Track>>` | `Future<List<Track>> allTracks()` | 已实现 |
| `search_tracks(query: String, limit: i32) -> Result<Vec<Track>>` | `Future<List<Track>> searchTracks({required String query, required int limit})` | 已实现 |
| `upsert_tracks(tracks: Vec<Track>) -> Result<i32>` | `Future<int> upsertTracks({required List<Track> tracks})` | 已实现 |
| `prune_missing_tracks() -> Result<i32>` | `Future<int> pruneMissingTracks()` | 已实现 |
| `remove_tracks(paths: Vec<String>) -> Result<i32>` | `Future<int> removeTracks({required List<String> paths})` | 已实现 |

语义补充：

- `init_db` 幂等：**同一路径**重复调用复用已有连接；换成别的路径会返回错误，
  必须先 `close_db()`。未初始化就调用其它 db 函数会返回错误而不是 panic。
- 曲库结构带版本号（`PRAGMA user_version`）：打开旧库时自动升级并重建 FTS 索引；
  库版本高于程序支持的版本时报错，提示升级。
- 升级前会先 `wal_checkpoint(TRUNCATE)` 再把库复制成 `<path>.bak`，迁移失败可回退；
  这是新库（0 字节）或版本已是最新时不做备份。
- `close_db` 不只是关连接：先 `PRAGMA optimize`，再 `wal_checkpoint(TRUNCATE)` 把 WAL
  合并回主库并清空。应用退出时必须调用，否则曲目数据一直压在 `-wal` 里。
- `search_tracks` 采用**前缀匹配**（每个词包成短语再补 `*`），`limit` 截断到 `1..=2000`。
  查询词里的 `-`、`+`、`:`、引号等按字面量处理，不会触发 FTS5 语法错误；
  空查询直接返回空列表。结果按 `bm25` 相关度排序。
  中文不做分词，搜「周杰」能命中「周杰伦」，搜「杰伦」命中不了 —— 这是已知限制。
- `upsert_tracks` 在单个事务里完成，失败回滚；返回本次处理的条数（不等于实际新增数）。
  它不携带文件指纹（mtime/大小），因此不会破坏扫描记录的增量信息。
- `prune_missing_tracks` 只清理磁盘上已不存在的 `path` 记录；磁盘检查在锁外完成，
  删除在单事务里完成。
- `remove_tracks` 按路径批量删除曲库记录，**只删记录、不动磁盘上的音频文件**；
  歌单 / 收藏 / 播放历史由外键级联清理。整批在单事务里完成，重复或不在库里的路径
  直接忽略，返回实际删除条数；空列表返回 0。
- 两道数据保护（会级联删除歌单 / 收藏 / 历史，不能误删）：
  1. **卷根可达性**：某块盘的根目录读不到时（移动硬盘 / 网络盘未挂载），该卷下的曲目
     一律不算缺失，直接跳过；
  2. **删除比例**：曲目总数 ≥ 10 且本次要删超过一半时，返回错误而不动库
     （提示「疑似磁盘未挂载」）。调用方应把错误展示给用户，不要重试。

## 5. 歌单 / 收藏 / 历史 `api::collections`

| Rust 签名 | Dart 签名 | 状态 |
|---|---|---|
| `list_playlists() -> Result<Vec<Playlist>>` | `Future<List<Playlist>> listPlaylists()` | 已实现 |
| `create_playlist(name: String) -> Result<Playlist>` | `Future<Playlist> createPlaylist({required String name})` | 已实现 |
| `rename_playlist(id: i64, name: String) -> Result<()>` | `Future<void> renamePlaylist({required PlatformInt64 id, required String name})` | 已实现 |
| `delete_playlist(id: i64) -> Result<()>` | `Future<void> deletePlaylist({required PlatformInt64 id})` | 已实现 |
| `playlist_tracks(id: i64) -> Result<Vec<Track>>` | `Future<List<Track>> playlistTracks({required PlatformInt64 id})` | 已实现 |
| `add_track_to_playlist(id: i64, path: String) -> Result<bool>` | `Future<bool> addTrackToPlaylist({required PlatformInt64 id, required String path})` | 已实现 |
| `remove_track_from_playlist(id: i64, path: String) -> Result<bool>` | `Future<bool> removeTrackFromPlaylist({required PlatformInt64 id, required String path})` | 已实现 |
| `add_tracks_to_playlist(id: i64, paths: Vec<String>) -> Result<i32>` | `Future<int> addTracksToPlaylist({required PlatformInt64 id, required List<String> paths})` | 已实现 |
| `list_favorites() -> Result<Vec<Track>>` | `Future<List<Track>> listFavorites()` | 已实现 |
| `favorite_paths() -> Result<Vec<String>>` | `Future<List<String>> favoritePaths()` | 已实现 |
| `is_favorite(path: String) -> Result<bool>` | `Future<bool> isFavorite({required String path})` | 已实现 |
| `set_favorite(path: String, favorite: bool) -> Result<()>` | `Future<void> setFavorite({required String path, required bool favorite})` | 已实现 |
| `set_favorites(paths: Vec<String>, favorite: bool) -> Result<i32>` | `Future<int> setFavorites({required List<String> paths, required bool favorite})` | 已实现 |
| `record_play(path: String) -> Result<()>` | `Future<void> recordPlay({required String path})` | 已实现 |
| `recent_tracks(limit: i32) -> Result<Vec<Track>>` | `Future<List<Track>> recentTracks({required int limit})` | 已实现 |
| `clear_history() -> Result<()>` | `Future<void> clearHistory()` | 已实现 |
| `record_play_time(path: String, day: i32, seconds: i64) -> Result<()>` | `Future<void> recordPlayTime({required String path, required int day, required PlatformInt64 seconds})` | 已实现 |
| `play_stats() -> Result<PlayStats>` | `Future<PlayStats> playStats()` | 已实现 |
| `top_tracks(limit: i32) -> Result<Vec<TrackPlayStat>>` | `Future<List<TrackPlayStat>> topTracks({required int limit})` | 已实现 |
| `daily_playtime(since_day: i32) -> Result<Vec<DailyPlaytime>>` | `Future<List<DailyPlaytime>> dailyPlaytime({required int sinceDay})` | 已实现 |

语义补充：

- 三张表都通过 `track_path` 外键关联 `tracks(path)`，并启用 `ON DELETE CASCADE`：
  曲目被扫描清理（`pruned`）或历史路径合并时，歌单条目 / 收藏 / 历史一起删除，不留悬空引用。
- **歌单名**：先去首尾空白；空名报错；忽略 ASCII 大小写唯一（`Night` 与 `night` 视为同名）。
  歌单 id 不存在、曲目不在曲库时均返回错误，不静默忽略。
- **歌单顺序**：按加入顺序（`added_at`，同一秒内按插入顺序），暂不支持手动排序。
- `add_track_to_playlist` / `remove_track_from_playlist` 幂等：重复加 / 重复移除不报错，
  返回值表示这次是否真的改变了数据。
- `add_tracks_to_playlist` 是批量版：整批在单事务里完成，任一曲目不在曲库时整体回滚，
  不会留下半批数据；已在歌单内的曲目忽略，返回真正新增条数。
- **收藏**：`set_favorite` 幂等；收藏时曲目必须已在曲库。`favorite_paths` 供列表页
  一次性拉取后做成员判断，避免逐曲调 `is_favorite`。
- `set_favorites` 是批量版：收藏时逐条校验曲目存在、任一失败整体回滚；取消收藏不校验
  （删库后的残留路径也能清掉）。重复路径幂等，返回真正改变的条数。
- **历史**：按曲目去重，每首歌一行；`record_play` 更新最近播放时间并累加 `play_count`
  （当前不对外暴露计数），`recent_tracks` 按最近播放倒序，`limit` 截断到 `1..=500`。
- **记录时机**：由 Dart 侧在 `player_play` 成功后调用 `record_play`；播放层不反向依赖曲库，
  避免两层耦合。
- 时间戳一律 Unix 秒。
- 曲库从 v1 升级到 v2 时自动建表，无需手动迁移；v1 程序打开 v2 库会报版本过高。
- v3 给 `tracks` 加 `cover_path`（封面缓存路径），并**清零全部文件指纹**：
  下次扫描会重新解析一遍，把老曲目的封面补上；随后指纹恢复，增量扫描照常跳过未变化文件。
  旧程序打开 v3 库会报版本过高。
- **听歌时长（v4）**：新增 `play_sessions(track_path, day, seconds)`，主键 `(track_path, day)`，
  `day` 是本地日期整数（`20261026`）而非时间戳——热力图按天聚合，直接比大小即可。
  `record_play_time` 累加同一个 `(曲目, 天)` 的秒数，`seconds <= 0` 静默忽略；
  `play_stats` 的 `total_seconds` 只统计 v4 之后的记录，`total_plays` 沿用 `play_history.play_count`
  （包含更早历史，两者口径不同，页面会说明）。
  `top_tracks` 按 `play_count` 倒序、`limit` 截断到 `1..=100`；`daily_playtime` 只返回有记录的
  天，不补零，补零是展示层的事。时长也通过外键 `ON DELETE CASCADE` 跟着曲目清理。
- **时长上报时机**：Dart 侧按轮询增量累计（只认 0 < delta < 3 秒，seek 跳变与切歌跨度不计入），
  攒到 15 秒或遇到暂停 / 切歌 / 播完 / 停止 / 退出时写库，不逐拍写。

## 6. 扫描 `api::scan`

| Rust 签名 | Dart 签名 | 状态 |
|---|---|---|
| `scan_folder(folder: String) -> Result<ScanReport>` | `Future<ScanReport> scanFolder({required String folder})` | 已实现 |

语义补充：

- 递归子目录，**不跟随软链接**（避免目录环）；支持的扩展名：
  `mp3 flac wav ogg m4a aac ape opus`（不区分大小写）。
  **不支持 wma**：标签解析用的 lofty 不支持 ASF 格式，暂不列入候选。
- **路径归一化**：入口目录先 canonicalize（还原磁盘真实大小写与分隔符），
  且 Windows 下路径比较忽略大小写、`/` 与 `\` 等价——
  `E:\Music` 与 `e:/music` 指同一批文件，不会产生重复记录。
- **增量**：曲库里记录了每个文件的 mtime（纳秒）与大小，两者都没变的文件直接跳过解析，
  只计入 `unchanged`；改过标签/换过文件才会重新解析。
- **封面**：解析时取内嵌图（优先正封面），按图片内容哈希存到 `<曲库目录>/covers/<hash>.<ext>`，
  同图只落一份盘；只收 jpg/png/gif/bmp，单张超过 20 MB 跳过。路径写入 `Track.cover_path`，
  缓存目录随曲库路径切换；扫描结束会清掉没有被任何曲目引用的封面文件。
- **自动清理**：扫描结束后删除「该目录下、本次没遍历到」的记录（`pruned`）。
  遍历过程中有权限/IO 错误（`walk_errors > 0`）时跳过清理，避免误删读不到的文件。
- 写入时按上面的归一化规则合并历史遗留的「同一文件不同写法」（大小写、`/` 与 `\`），
  不会因为写入路径变化而留下重复记录。
- 解析结果直接入库，调用方拿 `ScanReport` 刷新列表即可；已存在的曲目按 `path` 更新，
  重复扫描不会产生重复记录。
- **单个文件解析失败只计入 `failed`，不影响其它文件入库**；目录不存在或曲库未初始化才整体报错。
  单个文件解析时如果底层库 panic，也会被隔离成该文件的 `failed`，不会带走整个进程。
- 无标签时标题用文件名（去扩展名）兜底；解析出的 `duration_secs` 为真实时长。
- 大目录扫描在 frb 的 worker 线程执行，不阻塞 UI；进度上报留待后续**新增** `StreamSink`
  接口，不改动本签名。

## 7. 播放 `api::player`

| Rust 签名 | Dart 签名 | 同步 | 状态 |
|---|---|---|---|
| `player_is_available() -> bool` | `bool playerIsAvailable()` | 是 | **已实现** |
| `player_play(path: String) -> Result<()>` | `Future<void> playerPlay({required String path})` | 否 | **已实现** |
| `player_pause() -> Result<()>` | `Future<void> playerPause()` | 否 | **已实现** |
| `player_resume() -> Result<()>` | `Future<void> playerResume()` | 否 | **已实现** |
| `player_stop() -> Result<()>` | `Future<void> playerStop()` | 否 | **已实现** |
| `player_seek(position_secs: f64) -> Result<()>` | `Future<void> playerSeek({required double positionSecs})` | 否 | **已实现** |
| `player_set_volume(volume: f64) -> Result<()>` | `Future<void> playerSetVolume({required double volume})` | 否 | **已实现** |
| `player_now() -> Result<PlayerProgress>` | `Future<PlayerProgress> playerNow()` | 否 | **已实现** |
| `player_position() -> Result<f64>` | `Future<double> playerPosition()` | 否 | **已实现** |
| `player_duration() -> Result<f64>` | `Future<double> playerDuration()` | 否 | **已实现** |
| `player_state() -> PlaybackState` | `PlaybackState playerState()` | 是 | **已实现** |
| `player_is_exclusive() -> bool` | `bool playerIsExclusive()` | 是 | **已实现** |
| `player_set_exclusive(exclusive: bool) -> Result<()>` | `Future<void> playerSetExclusive({required bool exclusive})` | 否 | **已实现** |
| `player_output_info() -> Result<String>` | `Future<String> playerOutputInfo()` | 否 | **已实现** |
| `player_set_equalizer(enabled: bool, gains: Vec<f32>) -> Result<()>` | `Future<void> playerSetEqualizer({required bool enabled, required List<double> gains})` | 否 | **已实现** |
| `player_shutdown() -> Result<()>` | `Future<void> playerShutdown()` | 否 | **已实现** |

语义补充：

- `player_is_available` / `player_state` 是**同步**函数（只读状态），可以在 `build` 里直接用；
  其余均为 `Future`，不要在 `build` 里调用。
- frb 的 `Future` 函数跑在线程池上，同一串调用可能落在不同线程；实现必须把 BASS 的
  初始化与通道操作收敛到**自己创建的专用线程**，本组函数只负责投递命令并等待回执。
- `bass.dll` 优先从 exe 同级目录加载（构建时由 `windows/CMakeLists.txt` 拷入），
  开发态再回退 `third_party/bass/windows/x64/`；不要依赖当前工作目录。
- `player_play` 会先停止当前曲目再加载新文件；文件不存在或格式不支持时返回错误。
- `player_position` / `player_duration` 在未加载曲目时返回 `0.0`，不报错。
- `player_now` 返回 `PlayerProgress { position_secs, duration_secs, state }`，轮询用它：
  一次跨线程往返拿全三项，也不会出现「位置是新曲、时长还是旧曲」的错位。
- 命令带单调序号与入队时刻：同类命令（换曲 / 跳转 / 音量、均衡器与独占切换）只认最新一条，
  在队列里等到超过 10 秒的会被直接丢弃并回成功——调用方早就超时了，迟到的命令执行下去
  只会让引擎状态和界面对不上。查询与 `player_shutdown` 永不丢弃。
- 所有 `player_*` 命令都在同一条引擎线程上串行执行，单条命令等待 **10 秒**超时
  （`LAMP_ENGINE_TIMEOUT_SECS` 仅供测试调短）。超时返回「播放引擎无响应」而不是永久挂起：
  打开断连的 SMB / 休眠中的移动盘上的文件时，`CreateFile` 可能阻塞数十秒。
  超时后引擎线程可能仍在阻塞，后续命令会排队；UI 应提示用户检查磁盘，并把该曲目当作播放失败。
- `player_set_exclusive` 切换输出模式（`true` = WASAPI 独占）。切换会重开当前曲目：
  位置与播放状态由引擎保留，正在出声时会有一次短暂中断。
- 独占走「`BASS_Init(0)` 只解码 + `bassmix` 重采样 + `BASS_WASAPI_Init` 回调拉数据」：
  设备按自身混音格式独占（不做系统混音），素材统一由 bassmix 转换到设备格式，
  因此**不是 bit-perfect 直通**。
- 独占不可用（缺 `basswasapi.dll` / 设备被占用 / 不支持该格式）时引擎**自动回落共享**，
  `player_set_exclusive` 仍返回成功，`player_is_exclusive()` 为 `false`，
  `player_output_info()` 里带回落原因——界面据此提示，而不是当成硬失败。
- 独占开启后设备由本进程持有：`player_stop` 立刻释放；停止超过 3 秒（`LAMP_EXCLUSIVE_IDLE_SECS`
  可调，仅供测试）也会自动交还，暂停不计时（用户随时会继续）。
- `player_shutdown` 关闭引擎线程并释放设备，退出前调用；未初始化时是空操作。
  进程退出本身也会交还设备，但显式关闭能让音频线程先收尾。
- 状态推进由 Dart 侧轮询（当前实现；后续可换事件流）。

## 8. 桥接自检 `api::simple`

| Rust | Dart | 用途 |
|---|---|---|
| `greet(name: String) -> String`（sync） | `String greet({required String name})` | 只用于 `integration_test` 验证 FFI 通路，**不承载业务语义** |

## 9. 歌词 `api::lyrics`

| Rust 签名 | Dart 签名 | 状态 |
|---|---|---|
| `lyrics_load(path: String) -> Result<TrackLyrics>` | `Future<TrackLyrics> lyricsLoad({required String path})` | **已实现** |

语义补充：

- `TrackLyrics`：`lines`（按时间升序，毫秒）+ `plain`（无时间轴文本）+ `source`（`sidecar` / `embedded` / `none`）。
- `LyricLine`：`time_ms` / `end_ms`（下一行起点，末行按最后一个字推算）+ `text` + `words`（逐字时间轴，空表示行级）+ `translation`（同时间戳的其余行，`\n` 分隔）。
- `LyricWord`：`time_ms` + `text`。
- 优先级：同目录同名 `.lrc`（`.LRC` 也试）> 内嵌 `Lyrics` / `UnsynchronizedLyrics`。
- **没有歌词不是错误**：返回空结构、`source = none`；只有音频文件本身读不了才会抛。
- 解析规则：一行多个时间戳会展开成多行；`[ar:...]` 这类元数据忽略；空行（间奏）保留为空文本。
- 逐字歌词：行内 `[mm:ss.xx]`（网易云 / QQ 导出）与 `<mm:ss.xx>`（增强 LRC）都支持；同一起始时间的多行合并为一行，带逐字标签的当正文，其余（罗马音 / 翻译）进 `translation`；`[offset:±ms]` 会整体平移时间轴。

## 10. 系统集成 `api::media`

Windows 系统媒体控制（SMTC）与单实例。两者都是「有更好、没有也能用」：
非 Windows 或系统不支持时返回错误 / 安全默认值，调用方忽略即可，**不能影响播放**。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `media_is_supported() -> bool` | `bool mediaIsSupported()` | 是 | **已实现** |
| `media_init() -> Result<()>` | `Future<void> mediaInit()` | 否 | **已实现** |
| `media_set_track(title, artist, album, cover_path: Option<String>) -> Result<()>` | `Future<void> mediaSetTrack({required String title, required String artist, required String album, String? coverPath})` | 否 | **已实现** |
| `media_set_state(state: MediaPlayState) -> Result<()>` | `Future<void> mediaSetState({required MediaPlayState state})` | 否 | **已实现** |
| `media_clear() -> Result<()>` | `Future<void> mediaClear()` | 否 | **已实现** |
| `media_commands() -> Stream<MediaCommand>` | `Stream<MediaCommand> mediaCommands()` | — | **已实现** |
| `single_instance_acquire() -> Result<bool>` | `Future<bool> singleInstanceAcquire()` | 否 | **已实现** |
| `single_instance_signal_existing() -> Result<bool>` | `Future<bool> singleInstanceSignalExisting()` | 否 | **已实现** |
| `single_instance_take_activation() -> bool` | `bool singleInstanceTakeActivation()` | 是 | **已实现** |

语义补充：

- `media_init` 幂等，失败可重试；用一个静音的 `MediaPlayer` 只为拿它的 SMTC，
  `CommandManager` 已关闭，不会和 BASS 抢输出。
- `media_set_track` 的 `cover_path` 指向本地图片，读不到时只用文字（不报错）。
- `media_commands` **只能订阅一次**：重复注册会让每个媒体键触发多次。
  命令含义：`play` / `pause` / `next` / `previous` / `stop`（`stop` 只停音频、保留曲目）。
- `single_instance_acquire` 返回 `false` 表示已有实例：调用 `single_instance_signal_existing`
  （命名事件）通知它把窗口亮出来，然后退出即可。互斥体句柄活到进程结束，
  同一进程内重复调用恒为 `true`。
- **唤起必须由首个实例自己做**：第二个进程此时已经建好了同名窗口，
  `FindWindow` 会命中它自己，跨进程 `ShowWindow` 无效。首个实例每 500 ms 调
  `single_instance_take_activation`（非阻塞），拿到 `true` 就 `windowManager.show()`。

## 11. 外观 `api::appearance`

读系统强调色给 MD3 动态取色用。非 Windows 或读取失败返回 `None`，
调用方回落默认种子色即可——动态取色是可选项，不是错误。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `system_accent_color() -> Option<u32>` | `int? systemAccentColor()` | 是 | **已实现** |

语义补充：

- 返回值为 `0xAARRGGBB`，Windows 上与「个性化 → 颜色 → 强调色」同源。
- 只在启动时读一次：Windows 改强调色后重启应用生效（后续可加事件监听）。

## 12. 生成代码规则

- `lib/src/rust/**`、`rust/src/frb_generated.rs` 全部由 codegen 产出，**禁止手改**。
- 提交前用 `git status` 确认生成文件与 Rust 源码是同一批改动。
- CI 的 `frb 生成代码一致性` 任务会重新生成并比对，不一致直接失败。

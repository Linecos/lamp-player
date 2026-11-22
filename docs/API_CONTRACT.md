# 接口契约（Rust ↔ Dart）

> **当前版本：v0.25（2026-11-23）**
>
> 本文档是 Flutter 与 Rust 之间的唯一约定。签名与本文不一致的 PR 不会合并。
>
> v0.25 变更（**破坏性，Dart 侧已同步**）：`lyrics_load(path)` 加
> `embedded_first: bool`——「歌词来源优先级」设置（默认旁载优先）要能反过来。
> 两条来源都不变，先试的一边解析不出内容仍退给另一边，见 §9。
>
> v0.24 变更：**补登记** `api::metadata::audio_channels(path) -> Result<i32>`
> （2026-11-20 就已实现，元数据编辑页的「声道数」用它；`lofty` 的
> `FileProperties::channels()`，不升 schema、不用重扫，读不到时调用方显示「—」）。
> 纯新增，见 §14。
>
> v0.23 变更：**新增** `api::fonts::installed_font_families`（本机字体族枚举，
> 供设置页「选择字体」弹窗）。纯新增，见 §16。
>
> v0.22 变更：**新增** `desktop_lyrics_set_font_family` / `desktop_lyrics_font_family`
> （桌面歌词字体族，来自设置里的「歌词字体」）。同时补上此前一直没在本文登记的
> §15 `api::desktop_lyrics`——该模块早已存在，只是契约里缺一节。纯新增，不改现有语义。
>
> v0.21 变更（**破坏性，Dart 侧已同步**）：
>
> - `player_analyze_replay_gain(path)` 返回值由 `Result<f64>`（-18 LUFS 参考下的
>   建议增益）改为 `Result<LoudnessAnalysis>`：一次解码量出 EBU R128 积分响度与
>   采样 / 真两种峰值（线性幅度），增益由 Dart 侧按用户设置现算，改参考响度
>   （-23 / -18 / -14 LUFS）或峰值类型（采样 / 真峰值）立刻生效、不必重跑解码。
> - 新增 `Track.loudness_lufs` / `sample_peak` / `true_peak`（缺失 / 没测过为 0），
>   曲库结构升到 **v11**：`tracks` 追加这三列（`REAL NOT NULL DEFAULT 0`）。
>   老行只有标签增益，三列留 0；标签增益按 −18 LUFS 口径 + 参考响度偏移使用。
> - 现场分析不再写 `tracks.replay_gain`（那一列只留标签值），改由 `store_loudness`
>   写三列测量值。
>
> v0.20 变更（纯新增）：
>
> - 新增 `api::collections::touch_play_history(path: String) -> Result<()>`：
>   只刷新 `play_history.last_played_at`，不增加 `play_count`（新行以 0 落地）。
>   「最近播放」跟起播走，播放次数改由 Dart 侧听够一半之后再调 `record_play`。
>
> v0.19 变更（纯新增）：
>
> - 新增 `api::media::media_set_play_mode(repeat: MediaRepeatMode, shuffle: bool)`
>   与 `MediaRepeatMode`（`off` / `all` / `one`）。循环 / 随机不再只是界面状态：
>   只有上报过这两个属性，Windows 播控浮层里的循环、随机按钮才会点亮并可点。
> - `MediaCommand` 新增 `repeatOff` / `repeatAll` / `repeatOne` / `shuffleOn` /
>   `shuffleOff`（系统浮层点了这两个按钮时下发）。不带载荷，仍是不需要 freezed 的
>   普通枚举。
>
> v0.18 变更（**破坏性，Dart 侧已同步**）：
>
> - `Track` 新增 `file_size` / `audio_bitrate` / `sample_rate` / `bit_depth`
>   （音质原始量，未知为 `0`），曲库结构升到 v10。升级时老行的 `file_mtime` /
>   `file_size` 会清零，下次扫描重新解析；**升级后第一次启动会自动补扫一次**已添加目录。
> - `lyrics_save_raw` 增加 `target: String` 入参（`sidecar` / `embedded`）：
>   原来恒定写同名 `.lrc`，现在可选写进音频标签。入参变了，属于破坏性改动。
> - 新增 `metadata::write_track_cover`（把图片写进音频文件的封面标签并落缓存）。
> - `TrackTags` 新增 `composer` / `lyricist` / `comment` 三个字段。
>
> v0.17 变更：**新增** `api::metadata` 两个函数（`read_track_tags` / `write_track_tags`）
> 与 `TrackTags` 结构；`api::lyrics` 新增 `lyrics_read_raw` / `lyrics_shift_raw` /
> `lyrics_save_raw` 与 `RawLyrics` 结构（歌词编辑与整体平移时间戳）。纯新增，
> 不改现有函数语义。
>
> v0.16 变更：`api::cover_override` 的 `kind` 增加 `playlist`（歌单封面，键为歌单 id），
> 纯增量，签名不变。
>
> v0.15 变更：**新增** `api::cover_override` 三个函数（`set_cover_override` /
> `clear_cover_override` / `list_cover_overrides`）与 `CoverOverride` 结构，配套
> 曲库结构升到 v9（新增 `cover_overrides` 表）。纯新增，不改现有语义。
>
> v0.14 变更：**删除** `media_hotkeys_supported` / `media_hotkey_commands` 与
> `MediaHotkeyCommand`（全局媒体键 `RegisterHotKey` 整体移除）。媒体键统一交给 SMTC
> 按「谁在播放」路由：暂停后按播放会回到本应用，应用空闲时也不会抢占别的播放器。
>
> v0.13 变更（已撤回）：曾新增上述三个符号，同日移除。
>
> v0.12 变更：新增 `player_set_volume_fade`（音量过渡开关，默认开）。开启时暂停 /
> 停止先淡出再收尾（状态立即生效），起播与定位后淡入，定位是「瞬间静音 → 跳转 →
> 短淡入」避免跳转爆音；关闭时全部硬切。纯新增，不改现有语义。
>
> v0.11 变更：新增 `collections::remove_tracks_from_playlist`（批量移出歌单，整批一个
> 事务，返回真正删掉的条数）。纯新增，不改现有语义。
>
> v0.10 变更：`hide_tracks` 语义从「搬进 hidden_tracks 再从 tracks 删行」改成
> 「置 `tracks.hidden` 标记」。签名不变，但行为变了：隐藏不再级联删掉收藏 / 歌单 /
> 播放历史 / 听歌时长（v7 的实现会，恢复只能回来一条空壳记录），隐藏中的曲目也
> 可以继续写收藏 / 播放记录。曲库结构升到 v8（`user_version = 8`），升级时把
> `hidden_tracks` 里的行搬回 `tracks` 并置位后删表。收藏 / 歌单 / 历史 / 排行统一
> 过滤 `hidden = 1`（行保留、列表不显示）。
>
> v0.9 变更：`player_analyze_replay_gain` 现在会把算出的增益写回曲库
> （`tracks.replay_gain`），重扫时文件仍无标签也不会覆盖；`player_set_replay_gain`
> 保留但不再有调用方（自动补算不在播放中途改音量）。签名不变。
>
> v0.8 变更：新增 `player_set_replay_gain`（把起播后补算出的 ReplayGain 增益
> 应用到当前输出）。纯新增，不改现有语义。
>
> v0.7 变更：新增 `api::replaygain`（`write_replay_gain`，把增益写进文件标签）。
> 纯新增，不改现有语义。
>
> v0.6 变更：新增 `player_analyze_replay_gain`（整曲响度分析，返回 ReplayGain 建议增益）。
> 纯新增，不改现有语义。
>
> v0.5 变更：`Track` 新增 `replay_gain`（ReplayGain 曲目增益，dB；无标签为 0），
> 曲库结构升到 v5（`user_version = 5`）；`player_play` 增加 `replay_gain_db` 入参；
> 新增输出设备枚举 / 切换与换曲淡变时长接口。纯新增 + 一个入参，Dart 侧同步更新。
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
| `replay_gain` | `replayGain` | `double` | ReplayGain 曲目增益（dB）；标签里没有时为 `0`（现场分析出的值也写回这一列） |
| `added_at` | `addedAt` | `PlatformInt64` | 入库时间戳（Unix 秒；native 上就是 `int`，web 上是 `BigInt`） |
| `cover_path` | `coverPath` | `String?` | 内嵌封面的缓存文件绝对路径；无封面或提取失败为空 |
| `file_size` | `fileSize` | `PlatformInt64` | 文件大小（字节）；未知为 `0`（v0.18 起） |
| `audio_bitrate` | `audioBitrate` | `int` | 平均码率（kbps）；未知为 `0`（v0.18 起） |
| `sample_rate` | `sampleRate` | `int` | 采样率（Hz）；未知为 `0`（v0.18 起） |
| `bit_depth` | `bitDepth` | `int` | 位深（bit）；有损编码没有这个值，恒为 `0`（v0.18 起） |

后四个字段是**音质评级的原始量**，评级本身不落库：`lib/src/common/audio/audio_quality.dart`
用它们算 `AudioQuality`（HR / SQ / HQ / 其他），规则调整只需重算列表。

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
| `hide_tracks(paths: Vec<String>) -> Result<i32>` | `Future<int> hideTracks({required List<String> paths})` | 已实现 |
| `hidden_tracks() -> Result<Vec<HiddenTrack>>` | `Future<List<HiddenTrack>> hiddenTracks()` | 已实现 |
| `unhide_tracks(paths: Vec<String>) -> Result<i32>` | `Future<int> unhideTracks({required List<String> paths})` | 已实现 |

语义补充：

- `init_db` 幂等：**同一路径**重复调用复用已有连接；换成别的路径会返回错误，
  必须先 `close_db()`。未初始化就调用其它 db 函数会返回错误而不是 panic。
- 曲库结构带版本号（`PRAGMA user_version`）：打开旧库时自动升级并重建 FTS 索引；
  库版本高于程序支持的版本时报错，提示升级。当前结构版本 **v11**：`tracks` 增加
  `loudness_lufs` / `sample_peak` / `true_peak`（ReplayGain 的测量值，0 = 未知），
  v10 增加的 `file_size` / `audio_bitrate` / `sample_rate` / `bit_depth` 也在其中
  （v10 升级时老行的 `file_mtime` / `file_size` 清零，下次扫描重新解析）。
- 升级前会先 `wal_checkpoint(TRUNCATE)` 再把库复制成 `<path>.bak`，迁移失败可回退；
  这是新库（0 字节）或版本已是最新时不做备份。
- `close_db` 不只是关连接：先 `PRAGMA optimize`，再 `wal_checkpoint(TRUNCATE)` 把 WAL
  合并回主库并清空。应用退出时必须调用，否则曲目数据一直压在 `-wal` 里。
- `search_tracks` 采用**前缀匹配**（每个词包成短语再补 `*`），`limit` 截断到 `1..=2000`。
  查询词里的 `-`、`+`、`:`、引号等按字面量处理，不会触发 FTS5 语法错误；
  空查询直接返回空列表。结果按 `bm25` 相关度排序。
  中文不做分词，搜「周杰」能命中「周杰伦」，搜「杰伦」命中不了 —— 这是已知限制。
- `upsert_tracks` 在单个事务里完成，失败回滚；返回本次处理的条数（不等于实际新增数）。
  它不携带文件指纹的 mtime，因此不会破坏扫描记录的增量信息；`file_size` 与音质三列传
  `0` 表示「调用方没带」，会保留库里已有的值（写标签、换封面构造的 `Track` 不必填全）。
- `prune_missing_tracks` 只清理磁盘上已不存在的 `path` 记录；磁盘检查在锁外完成，
  删除在单事务里完成。
- `remove_tracks` 按路径批量删除曲库记录，**只删记录、不动磁盘上的音频文件**；
  歌单 / 收藏 / 播放历史由外键级联清理。整批在单事务里完成，重复或不在库里的路径
  直接忽略，返回实际删除条数；空列表返回 0。
- `hide_tracks` / `unhide_tracks` 只改 `tracks.hidden` 标记，**不动行**：收藏、歌单、
  播放历史、听歌时长都挂在 `tracks(path)` 外键上，删行会被级联清空。隐藏中的曲目
  照常可以写收藏与播放记录（正在播放的那首被隐藏时不该报错）。`all_tracks` /
  `search_tracks` / 收藏 / 歌单 / 历史 / 排行都过滤 `hidden = 1`：行保留、列表不显示，
  恢复即刻复原。扫描照常维护隐藏曲目的元数据（指纹在，未改动的文件不会重新解析）。
- `HiddenTrack`（`path/title/artist/album/duration_secs/cover_path/hidden_at`）用于「被隐藏的
  歌曲」列表，最近隐藏的在前；`hidden_at` 为隐藏时刻（Unix 秒），`cover_path` 是封面缓存
  路径（空字符串表示没有封面），设置页据此像曲库列表一样显示封面。
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
| `remove_tracks_from_playlist(id: i64, paths: Vec<String>) -> Result<i32>` | `Future<int> removeTracksFromPlaylist({required PlatformInt64 id, required List<String> paths})` | 已实现 |
| `add_tracks_to_playlist(id: i64, paths: Vec<String>) -> Result<i32>` | `Future<int> addTracksToPlaylist({required PlatformInt64 id, required List<String> paths})` | 已实现 |
| `list_favorites() -> Result<Vec<Track>>` | `Future<List<Track>> listFavorites()` | 已实现 |
| `favorite_paths() -> Result<Vec<String>>` | `Future<List<String>> favoritePaths()` | 已实现 |
| `is_favorite(path: String) -> Result<bool>` | `Future<bool> isFavorite({required String path})` | 已实现 |
| `set_favorite(path: String, favorite: bool) -> Result<()>` | `Future<void> setFavorite({required String path, required bool favorite})` | 已实现 |
| `set_favorites(paths: Vec<String>, favorite: bool) -> Result<i32>` | `Future<int> setFavorites({required List<String> paths, required bool favorite})` | 已实现 |
| `touch_play_history(path: String) -> Result<()>` | `Future<void> touchPlayHistory({required String path})` | 已实现 |
| `record_play(path: String) -> Result<()>` | `Future<void> recordPlay({required String path})` | 已实现 |
| `recent_tracks(limit: i32) -> Result<Vec<Track>>` | `Future<List<Track>> recentTracks({required int limit})` | 已实现 |
| `clear_history() -> Result<()>` | `Future<void> clearHistory()` | 已实现 |
| `record_play_time(path: String, day: i32, seconds: i64) -> Result<()>` | `Future<void> recordPlayTime({required String path, required int day, required PlatformInt64 seconds})` | 已实现 |
| `play_stats() -> Result<PlayStats>` | `Future<PlayStats> playStats()` | 已实现 |
| `top_tracks(limit: i32) -> Result<Vec<TrackPlayStat>>` | `Future<List<TrackPlayStat>> topTracks({required int limit})` | 已实现 |
| `top_artists(limit: i32) -> Result<Vec<ArtistPlayStat>>` | `Future<List<ArtistPlayStat>> topArtists({required int limit})` | 已实现 |
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
- **历史**：按曲目去重，每首歌一行；`record_play` 更新最近播放时间并累加 `play_count`，
  `recent_tracks` 按最近播放倒序，`limit` 截断到 `1..=500`。
- **记录时机（v0.20 起拆成两拍）**：`player_play` 成功后 Dart 侧先调
  `touch_play_history`（只刷新时间，历史立刻出现）；之后这一轮真正听过的秒数到全曲
  一半时才调 `record_play` 累加次数。`touch_play_history` 建的新行 `play_count = 0`，
  排行榜、`play_stats.total_plays` 都按 `play_count > 0` 过滤，所以只听了一半以前的
  曲目只会出现在历史里，不会进任何计数。播放层不反向依赖曲库，避免两层耦合。
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
  `top_artists` 按标签原样（`t.artist`）分组聚合，`limit` 同样截断到 `1..=100`；合唱标签
  `A/B` 会单独占一行，**拆分与按人合并交给展示层**（`splitArtistTag`），拆法只有一份。
  它返回的 `cover_path` 是这位艺术家播得最多的那首的封面（空字符串按没有处理）。
- **时长上报时机**：Dart 侧按轮询增量累计（只认 0 < delta < 3 秒，seek 跳变与切歌跨度不计入），
  攒到 15 秒或遇到暂停 / 切歌 / 播完 / 停止 / 退出时写库，不逐拍写。
- **路径合并**（`merge_track_path`）：同一文件的不同字面路径（大小写 / 分隔符）合并时，
  收藏、歌单、播放历史、听歌时长都要迁到新路径；历史按曲目合并次数并保留较新的时间，
  时长按 `(曲目, 天)` 逐日**相加**（`ON CONFLICT ... seconds + excluded.seconds`），
  不是二选一——否则合并一次就把旧路径那一截时长连同热力图一起删掉。
- **歌单排序**（`move_playlist_track`）：下标按**界面可见顺序**给；隐藏曲目也在歌单里，
  实现按「槽位」处理——可见曲目按拖拽结果依次填回原来的可见槽位，隐藏条目留在自己的槽位，
  最后整体重排成 `0..n-1`。这样序号始终唯一，隐藏曲恢复后仍在原来的相对位置。
- **整体覆盖顺序**（`set_playlist_order`）：界面在**别的排序下**（最近添加 / 标题…）拖动时用
  这个，`paths` 就是拖完的那一列。只挪一首（`move_playlist_track`）会让界面先跳回旧的自定义
  顺序再动一格，看到的位置和手拖的位置对不上。没提到的可见曲目按原相对顺序补到末尾，
  不在歌单里的路径与重复项忽略；同样按槽位写回，隐藏条目原地不动。
- **批量移出**（`remove_tracks_from_playlist`）：整批一个事务，只回真正删掉的条数；
  不在歌单里的路径忽略。界面批量移出必须走它，逐条删会出现「删了一半但提示整批失败」。

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
| `player_play(path: String, replay_gain_db: f64) -> Result<()>` | `Future<void> playerPlay({required String path, required double replayGainDb})` | 否 | **已实现** |
| `player_analyze_replay_gain(path: String) -> Result<LoudnessAnalysis>` | `Future<LoudnessAnalysis> playerAnalyzeReplayGain({required String path})` | 否 | **已实现** |
| `player_pause() -> Result<()>` | `Future<void> playerPause()` | 否 | **已实现** |
| `player_resume() -> Result<()>` | `Future<void> playerResume()` | 否 | **已实现** |
| `player_stop() -> Result<()>` | `Future<void> playerStop()` | 否 | **已实现** |
| `player_seek(position_secs: f64) -> Result<()>` | `Future<void> playerSeek({required double positionSecs})` | 否 | **已实现** |
| `player_set_volume(volume: f64) -> Result<()>` | `Future<void> playerSetVolume({required double volume})` | 否 | **已实现** |
| `player_set_replay_gain(gain_db: f64) -> Result<()>` | `Future<void> playerSetReplayGain({required double gainDb})` | 否 | **已实现**（当前无调用方，见语义补充） |
| `player_now() -> Result<PlayerProgress>` | `Future<PlayerProgress> playerNow()` | 否 | **已实现** |
| `player_position() -> Result<f64>` | `Future<double> playerPosition()` | 否 | **已实现** |
| `player_duration() -> Result<f64>` | `Future<double> playerDuration()` | 否 | **已实现** |
| `player_state() -> PlaybackState` | `PlaybackState playerState()` | 是 | **已实现** |
| `player_is_exclusive() -> bool` | `bool playerIsExclusive()` | 是 | **已实现** |
| `player_set_exclusive(exclusive: bool) -> Result<()>` | `Future<void> playerSetExclusive({required bool exclusive})` | 否 | **已实现** |
| `player_output_info() -> Result<String>` | `Future<String> playerOutputInfo()` | 否 | **已实现** |
| `player_devices() -> Result<Vec<PlayerDevice>>` | `Future<List<PlayerDevice>> playerDevices()` | 否 | **已实现** |
| `player_set_device(index: i32) -> Result<()>` | `Future<void> playerSetDevice({required int index})` | 否 | **已实现** |
| `player_current_device() -> i32` | `int playerCurrentDevice()` | 是 | **已实现** |
| `player_set_crossfade(seconds: f64) -> Result<()>` | `Future<void> playerSetCrossfade({required double seconds})` | 否 | **已实现** |
| `player_set_volume_fade(enabled: bool) -> Result<()>` | `Future<void> playerSetVolumeFade({required bool enabled})` | 否 | **已实现** |
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
  `replay_gain_db` 由调用方按设置决定传标签值还是 `0`，引擎把它与用户音量相乘后下发
  （夹在 −24…+12 dB，避免离谱标签削波）。
- `player_analyze_replay_gain` 整曲解码并量出 ReplayGain 2.0 需要的三个量：
  EBU R128 积分响度（LUFS）与采样 / 真峰值（线性幅度，1.0 = 满量程）。解码走独立
  线程、不需要输出设备，也不占用引擎线程；全曲分析约 1~2 秒。**测量值会写回曲库**
  （`tracks.loudness_lufs` / `sample_peak` / `true_peak`，重扫不会覆盖），
  所以 Dart 侧不必长期缓存。增益不在 Rust 侧算，Dart 侧公式：
  `gain = clamp(min(reference − loudness, −20log10(peak)), −24, +24)`，
  `peak` 取当前设置的峰值类型；标签增益（−18 口径）按
  `tagGain + (reference + 18)` 偏移后同样夹 ±24，不做峰值限幅（标签里没有峰值）。
  Dart 实现见 `lib/src/common/audio/replay_gain.dart`。
- `player_set_replay_gain` 立即把增益作用到当前输出。自动补算**不再调用**它：
  起播时增益未知就先按不归一播（整首响度一致），算出的值从下一次起播开始生效，
  避免「先响 1~2 秒、随后突然变小」。接口保留给需要即时应用的场景。
- `player_set_device` 只影响共享输出；`index = -1` 表示系统默认。切换会保留当前曲目、
  位置与播放状态重开会话。设备已拔掉时引擎回退系统默认并在 `player_output_info` 里说明。
- `player_devices` 只返回可用设备（索引与 `BASS_GetDeviceInfo` 一致，从 1 开始）；
  系统默认那一项由界面自己补，热插拔靠界面低频轮询本函数发现。
- `player_set_crossfade` 传 0 关闭。共享模式是两条流重叠的真交叉淡变；独占模式输出只有
  一条混音流，只做新曲淡入（不重叠）。
- `player_set_volume_fade` 默认开（Dart 侧会话默认值与引擎默认值一致）。开启时：
  暂停 / 停止先淡出（约 500ms），淡出结束时引擎补真正的动作，**状态立即生效**、
  `player_now` 立即报告 Paused / Stopped，淡出期间 `player_position` 对停止报 0；
  起播淡入同样约 500ms；淡出途中 `player_resume` 会取消那次挂起的暂停并把音量滑回去。
  定位（seek）不延迟：瞬间静音 → 跳转 → 约 60ms 淡入。关闭时所有操作是硬切。
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
| `lyrics_load(path: String, embedded_first: bool) -> Result<TrackLyrics>` | `Future<TrackLyrics> lyricsLoad({required String path, required bool embeddedFirst})` | **已实现** |
| `lyrics_read_raw(path: String) -> Result<RawLyrics>` | `Future<RawLyrics> lyricsReadRaw({required String path})` | **已实现** |
| `lyrics_shift_raw(text: String, delta_ms: i64) -> String`（sync） | `String lyricsShiftRaw({required String text, required int deltaMs})` | **已实现** |
| `lyrics_save_raw(path: String, text: String, target: String) -> Result<String>` | `Future<String> lyricsSaveRaw({required String path, required String text, required String target})` | **已实现** |

编辑用的三支（v0.17，`lyrics_save_raw` 在 v0.18 加了 `target`）：

- `RawLyrics`：`text`（原文，含 `[ti:]` 与逐字标签原样）+ `source`（`sidecar` / `embedded` / `none`）。
  没有歌词返回空文本 + `none`，不报错。
- `lyrics_shift_raw` 是**纯文本变换**，不碰文件：负数是提前、正数是延后，平移后夹到 0；
  方括号 `[mm:ss.xx]` 与尖括号 `<mm:ss.xx>` 都平移（逐字标签是绝对时间，只改行首会错位），
  `[ti:]` / `[offset:]` 这类元数据与正文里的普通方括号原样保留；小数位数按原样保留。
- `lyrics_save_raw` 的 `target` 取 `sidecar` / `embedded`（其他值按 `sidecar` 处理）：
  - `sidecar`：写同名 `.lrc`（UTF-8 无 BOM），返回写入路径。
  - `embedded`：写音频标签（ID3v2 的 USLT / Vorbis 的 `LYRICS`），返回音频文件路径。
    默认「旁载优先」，所以**同目录已有同名 `.lrc` 时会一并把同样的文本刷进去**，
    否则旧旁载会盖住刚落进标签的新歌词；没有 `.lrc` 就不新建。
- 界面顺序：先 `shift_raw` 拿到新文本给用户看，确认后 `save_raw` 落盘。

语义补充：

- `TrackLyrics`：`lines`（按时间升序，毫秒）+ `plain`（无时间轴文本）+ `source`（`sidecar` / `embedded` / `none`）。
- `LyricLine`：`time_ms` / `end_ms`（下一行起点，末行按最后一个字推算）+ `text` + `words`（逐字时间轴，空表示行级）+ `translation`（同时间戳的其余行，`\n` 分隔）。
- `LyricWord`：`time_ms` + `text`。
- 优先级（v0.25 起由 `embedded_first` 指定，默认旁载优先）：
  旁载同名 `.lrc`（`.LRC` 也试）→ `.ttml`（`.TTML` 也试）→ 内嵌 `Lyrics` / `UnsynchronizedLyrics`；
  `embedded_first = true` 时内嵌先试，读不到再退旁载（顺序反过来，来源集合不变）。
- 编辑用的 `lyrics_read_raw` 仍**固定旁载优先**：编辑窗要显示「改的是哪个文件」，
  跟着播放顺序漂会让同一首歌的编辑目标随设置变。
- 格式按**内容**嗅探（根元素 `<tt` 走 TTML，其余按 LRC），不看扩展名：旁载与内嵌两条路都可能拿到 TTML。
- **没有歌词不是错误**：返回空结构、`source = none`；只有音频文件本身读不了才会抛。
- 解析规则：一行多个时间戳会展开成多行；`[ar:...]` 这类元数据忽略；空行（间奏）保留为空文本。
- 逐字歌词：行内 `[mm:ss.xx]`（网易云 / QQ 导出）与 `<mm:ss.xx>`（增强 LRC）都支持；同一起始时间的多行合并为一行，带逐字标签的当正文，其余（罗马音 / 翻译）进 `translation`；`[offset:±ms]` 会整体平移时间轴。

## 10. 系统集成 `api::media`

Windows 系统媒体控制（SMTC）、全局媒体键（`RegisterHotKey`）与单实例。这些功能都是
「有更好、没有也能用」：非 Windows 或系统不支持时返回错误 / 安全默认值，调用方忽略
即可，**不能影响播放**。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `media_is_supported() -> bool` | `bool mediaIsSupported()` | 是 | **已实现** |
| `media_init() -> Result<()>` | `Future<void> mediaInit()` | 否 | **已实现** |
| `media_set_track(title, artist, album, cover_path: Option<String>) -> Result<()>` | `Future<void> mediaSetTrack({required String title, required String artist, required String album, String? coverPath})` | 否 | **已实现** |
| `media_set_state(state: MediaPlayState) -> Result<()>` | `Future<void> mediaSetState({required MediaPlayState state})` | 否 | **已实现** |
| `media_set_play_mode(repeat: MediaRepeatMode, shuffle: bool) -> Result<()>` | `Future<void> mediaSetPlayMode({required MediaRepeatMode repeat, required bool shuffle})` | 否 | **已实现** |
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
  命令含义：`play` / `pause` / `next` / `previous` / `stop`（`stop` 只停音频、保留曲目），
  `repeatOff` / `repeatAll` / `repeatOne`（系统浮层改了循环），
  `shuffleOn` / `shuffleOff`（系统浮层改了随机）。
- **循环 / 随机必须上报过才算数**：Windows 没有 `IsRepeatEnabled` 这类开关，浮层里的
  循环、随机按钮亮不亮取决于会话有没有报过 `AutoRepeatMode` / `ShuffleEnabled`。
  `media_init` 先报一次「不循环 / 不随机」的初值，真实状态由 `media_set_play_mode`
  覆盖；播放模式一变（启动恢复、按钮轮换、系统请求回写）都要再同步一次。
  两个属性变更走 `AutoRepeatModeChangeRequested` / `ShuffleEnabledChangeRequested`
  事件，不是 `ButtonPressed`。
- **媒体键只走 SMTC 一条路，没有全局注册**：`RegisterHotKey` 会让应用空闲时全局
  独占、吃掉别的播放器的媒体键；改成「只在出声时占用」又在暂停后把键交还系统，
  再按播放常常落不到本应用。交给系统按「谁在播放」路由后，暂停时 SMTC 会话仍在，
  按播放会回到本应用。曾经的 `media_hotkeys_supported` / `media_hotkey_commands`
  与 `MediaHotkeyCommand` 已从接口面删除（v0.14）。
- 代价（已知并接受）：SMTC 会话被别的播放器抢走时，本应用收不到媒体键。
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

## 12. ReplayGain 标签 `api::replaygain`

多选「计算 ReplayGain」的落盘端。分析本身在 `api::player::player_analyze_replay_gain`
（EBU R128，ReplayGain 2.0），本模块只负责把结果写回文件标签，
让增益跟着文件走——重新扫描、换播放器都还在。

写入的增益**恒按 −18 LUFS 参考**（ReplayGain 的通用口径）：设置里的参考响度只影响
本机播放，不跟着标签走；峰值限幅按设置的峰值类型（采样 / 真峰值）。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `write_replay_gain(path: String, gain_db: f64) -> Result<()>` | `Future<void> writeReplayGain({required String path, required double gainDb})` | 否 | **已实现** |

语义补充：

- 写 `REPLAYGAIN_TRACK_GAIN`，文本形如 `-7.23 dB`，与扫描时 `parse_replay_gain` 的口径一致；
  已有则覆盖，没有标签就新建主标签。
- 增益夹在 ±24 dB；非有限值直接报错。只读文件、格式不支持写标签时返回错误，
  lofty 先写临时文件再替换，不会留下半截文件。
- **会修改用户文件**：调用方必须先明确告知并取得确认，不能当成无副作用的读操作。
- 写完后要重扫该文件所在目录，曲库里的 `replay_gain` 才会更新。增量扫描按
  mtime / size 判定，改过标签的文件必然重新解析。

## 13. 自定义封面 `api::cover_override`

给艺术家 / 专辑指定一张本地图片作封面。扫描出来的封面是「自动」的（专辑取内嵌图、
艺术家取第一首有封面的曲目），这里是用户显式覆盖，优先于自动结果。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `set_cover_override(kind: String, name: String, artist: String, source_path: String) -> Result<String>` | `Future<String> setCoverOverride({required String kind, required String name, required String artist, required String sourcePath})` | 否 | **已实现** |
| `clear_cover_override(kind: String, name: String, artist: String) -> Result<bool>` | `Future<bool> clearCoverOverride({required String kind, required String name, required String artist})` | 否 | **已实现** |
| `list_cover_overrides() -> Result<Vec<CoverOverride>>` | `Future<List<CoverOverride>> listCoverOverrides()` | 否 | **已实现** |

`CoverOverride` 字段：`kind`（`artist` / `album` / `playlist`）、`name`（艺术家名 / 专辑名 / **歌单 id 的十进制字符串**）、
`artist`（专辑所属艺术家，艺术家与歌单为空串）、`path`（缓存文件绝对路径）、`updated_at`（秒）。

语义补充：

- `kind` 只接受 `artist`、`album`、`playlist`，其它值报错；`album` 必须带非空 `artist`，
  因为同名专辑在不同艺术家下是两张不同的专辑。
- **歌单用 id 不用名字**：歌单可以重命名，用名字当键的话改一次名自定义封面就找不回来了
  （旧名字那行还会留在表里变成孤儿）。调用方传 `playlist.id.toString()`。
- 图片由 Rust 侧解码校验（不是图片直接报错）、缩到 1024 长边、按内容哈希去重，
  落到 `<支持目录>/custom_covers/`，返回缓存路径。**不复制进 `covers/`**：那是扫描缓存，
  `prune_unused_covers` 会删掉没有被 `tracks.cover_path` 引用的文件，自定义封面会被误清。
- 同一目标重复调用即「换一张」，旧缓存文件会被删除；`clear` 也会删文件。
- `clear` 在本来就没有自定义封面时返回 `false`，不算错误。
- `list` 会跳过缓存文件已不存在（用户手动删过）的记录。
- 键拆成 `name` + `artist` 两列存储，不用 Dart 侧的 `albumGroupKey`：那个键含 `\u0000`，
  而 SQLite 的 TEXT 以 NUL 结尾，含 NUL 的字符串存进去会被截断。

## 14. 标签元数据 `api::metadata`

曲目右键「修改元数据」的落盘端：读的是**文件标签本身**，不是曲库缓存（曲库只存
标题 / 艺术家 / 专辑 / 曲目号，年份、流派、专辑艺术家、碟号库里没有）。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `read_track_tags(path: String) -> Result<TrackTags>` | `Future<TrackTags> readTrackTags({required String path})` | 否 | **已实现** |
| `audio_channels(path: String) -> Result<i32>` | `Future<int> audioChannels({required String path})` | 否 | **已实现**（v0.24） |
| `write_track_tags(path: String, tags: TrackTags) -> Result<TrackTags>` | `Future<TrackTags> writeTrackTags({required String path, required TrackTags tags})` | 否 | **已实现** |
| `write_track_cover(path: String, source: String) -> Result<String>` | `Future<String> writeTrackCover({required String path, required String source})` | 否 | **已实现**（v0.18） |

`TrackTags` 字段全部是字符串：`title` / `artist` / `album` / `album_artist` / `year` /
`track_no` / `disc_no` / `genre` / `composer` / `lyricist` / `comment`（后三个 v0.18 新增）。
不用数字类型是因为标签里的值不保证是数字（`2003-05-01` 的日期、`03/12` 的曲目号都真实存在），
强转会在保存时静默丢内容。

语义补充：

- **会修改用户文件**：调用方必须先明确告知；写盘由 lofty 先写临时文件再替换，
  失败不会留下半截文件。
- 空字符串表示**清掉这个键**，不会写一个空值进去；写入前统一 trim。
- 返回值是**写完重新读出来**的结果：不同标签格式会做归一化（补零、多值合并、
  不支持的键被丢弃），调用方拿它刷新界面才不会出现「显示 3、文件里是 03」。
- 没有标签的文件（`read_track_tags` 返回全空）可正常写：会自动建一个主标签。
- 写完后曲库那一行**不会自动更新**：调用方用返回的 `title` / `artist` / `album` /
  `track_no` 组装 `Track` 后调 `upsert_tracks`（保留原 `added_at` / `cover_path` /
  `replay_gain`），再刷新列表。不要为此整库重扫。
- `write_track_cover`（v0.18）：把 `source` 指向的图片**嵌进音频标签**（只换正面封面，
  封底 / 艺人照保留），同时落一份到封面缓存，返回**缓存文件路径**——界面显示的永远是
  缓存里那张，调用方拿它更新 `Track.cover_path`。超过 1024 长边会缩、非 JPEG 会转 JPEG；
  缓存写失败不报错（下次扫描会重新提取），音频文件本身写失败才报错。
- 自定义封面（艺术家 / 专辑 / 歌单）不走这里，走 `api::cover_override`。
- `audio_channels`（v0.24）：只读文件属性拿声道数（`lofty` 的 `FileProperties::channels()`），
  曲库不存这一列，所以每次打开元数据面板按需调用；文件读不到或格式不报时返回 0，
  界面统一显示「—」。返回不在 `Track` 里，也不要为此加 schema。

## 15. 桌面歌词 `api::desktop_lyrics`

一个独立的置顶无边框窗口，用 GDI+ 直接画字（不经过 Flutter 引擎），因此这里的
接口都是「推状态 + 拉状态」，没有 widget 可以复用。非 Windows 平台上
`desktop_lyrics_supported()` 返回 `false`，其余调用报错或空操作。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `desktop_lyrics_supported() -> bool` | `bool desktopLyricsSupported()` | 是 | **已实现** |
| `desktop_lyrics_show() -> Result<()>` | `Future<void> desktopLyricsShow()` | 否 | **已实现** |
| `desktop_lyrics_hide() -> Result<()>` | `Future<void> desktopLyricsHide()` | 否 | **已实现** |
| `desktop_lyrics_set_line(line: String) -> Result<()>` | `Future<void> desktopLyricsSetLine({required String line})` | 否 | **已实现** |
| `desktop_lyrics_set_progress(ratio: f32)` | `void desktopLyricsSetProgress({required double ratio})` | 是 | **已实现** |
| `desktop_lyrics_set_playing(playing: bool)` | `Future<void> desktopLyricsSetPlaying({required bool playing})` | 否 | **已实现** |
| `desktop_lyrics_set_font_size(size: i32)` | `Future<void> desktopLyricsSetFontSize({required int size})` | 否 | **已实现** |
| `desktop_lyrics_font_size() -> i32` | `int desktopLyricsFontSize()` | 是 | **已实现** |
| `desktop_lyrics_set_font_family(family: String)` | `Future<void> desktopLyricsSetFontFamily({required String family})` | 否 | **已实现**（v0.22） |
| `desktop_lyrics_font_family() -> String` | `String desktopLyricsFontFamily()` | 是 | **已实现**（v0.22） |
| `desktop_lyrics_set_locked(locked: bool)` | `Future<void> desktopLyricsSetLocked({required bool locked})` | 否 | **已实现** |
| `desktop_lyrics_locked() -> bool` | `bool desktopLyricsLocked()` | 是 | **已实现** |
| `desktop_lyrics_set_position(x: i32, y: i32)` | `void desktopLyricsSetPosition({required int x, required int y})` | 是 | **已实现** |
| `desktop_lyrics_position() -> Option<DesktopLyricPosition>` | `DesktopLyricPosition? desktopLyricsPosition()` | 是 | **已实现** |
| `desktop_lyrics_commands() -> Stream<DesktopLyricsCommand>` | `Stream<DesktopLyricsCommand> desktopLyricsCommands()` | — | **已实现** |

语义补充：

- **窗口上的按钮回流用事件流**：`DesktopLyricsCommand` 里的播放 / 切歌 / 关闭 /
  锁定 / 字号变化都由窗口推给 Dart。带值的（锁定、字号）命令不带字段，Dart 收到后
  用对应的 getter 读最新值再写会话存档——两边各自存一份值迟早会对不上。
- **字号**范围 16–56（96 DPI 逻辑像素），Rust 侧夹取；默认 27。窗口工具栏的
  A- / A+ / 「恢复默认」都直接改 Rust 侧状态，再发 `FontSizeChanged` 通知 Dart。
- **字体族**接受两种值：① **系统已安装**的字体名（GDI+ 的
  `GdipCreateFontFamilyFromName` 拿不到未安装字体）；② 随安装包分发的 MiSans
  （`MiSans`）。后者由私有字体集合提供，字体文件里的家族名就是 `MiSans`；早先
  随包发过四个字重时的旧别名（`MiSans Light` 等）也会归一成这个名字。GDI+ 这边
  只有「常规 / 粗体」两档：随包 MiSans 用常规字形，系统字体用粗体字形。
  空串 = 内置默认链：`Microsoft YaHei UI` → `Segoe UI`；取不到时按同一链降级，
  不会出现空白窗口。
- **换字号 / 换字体都要重排窗口**：折行数按当前字体测量，长句可能从两行变三行，
  窗口高度随之变化；因此这两个 setter 走 `request_apply()` 而不是单纯重绘。
- 位置是屏幕坐标、由 Rust 夹到当前显示器工作区内；Dart 只负责记到会话存档里，
  下次启动原样推回去。

## 16. 字体枚举 `api::fonts`

设置页「选择字体」弹窗用，只读、无状态。

| Rust 签名 | Dart 签名 | sync | 状态 |
|---|---|---|---|
| `installed_font_families() -> Vec<String>` | `Future<List<String>> installedFontFamilies()` | 否 | **已实现** |

语义补充：

- 扫 `%WINDIR%\Fonts` 与 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`（双击安装的用户字体），
  读字体文件 name 表取**传统族名**（name_id 1）。`Light / Semibold` 这类字重在 Windows
  上是独立族名，Flutter 与 GDI+ 都按它解析；用排版族名（name_id 16）会把它们合并掉，
  存档里已有的 `Microsoft YaHei Light` 反而找不到。没有 1 时才退 16。
- `.ttc` 逐个 face 解析（最多 32 个），小写名去重、按名字排序后返回。
- 第一次调用扫全部字体文件（本机约 0.6 秒），结果缓存在 Rust 侧；平台无关，非 Windows
  扫不到目录时返回空表，Dart 侧会退回内置的中文字体表兜底。

## 17. 生成代码规则

- `lib/src/rust/**`、`rust/src/frb_generated.rs` 全部由 codegen 产出，**禁止手改**。
- 提交前用 `git status` 确认生成文件与 Rust 源码是同一批改动。
- CI 的 `frb 生成代码一致性` 任务会重新生成并比对，不一致直接失败。

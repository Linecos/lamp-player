//! 曲库持久化：SQLite + FTS5 全文检索
//!
//! 表结构有版本号（`PRAGMA user_version`），升级时在 [`migrate`] 里追加一段，
//! 不要靠 `CREATE TABLE IF NOT EXISTS` 猜——它不会给老库补列。

use crate::api::model::Track;
use crate::scanner::{path_key, ScannedTrack};
use anyhow::{bail, Context};
use rusqlite::{params, Connection, Row};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// 曲库结构版本。每次改表结构 +1，并在 [`migrate`] 里补升级逻辑。
const SCHEMA_VERSION: i32 = 5;

struct Database {
    path: String,
    conn: Connection,
}

/// 全局单例；`None` 表示尚未初始化或已 [`close_db`]。
static DB: OnceLock<Mutex<Option<Database>>> = OnceLock::new();

fn cell() -> &'static Mutex<Option<Database>> {
    DB.get_or_init(|| Mutex::new(None))
}

/// 曲库操作唯一入口：持有全局锁执行一次闭包。
///
/// 未初始化、锁中毒都转成普通错误返回，避免在库代码里 panic。
pub(crate) fn with_conn<T>(
    f: impl FnOnce(&mut Connection) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let mut guard = cell()
        .lock()
        .map_err(|_| anyhow::anyhow!("曲库连接锁已中毒（此前有线程 panic）"))?;
    let db = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("曲库未初始化：请先调用 init_db(path)"))?;
    f(&mut db.conn)
}

/// 初始化数据库：建表 + FTS5 虚表 + 同步触发器，并按需升级结构。
///
/// 同一个路径重复调用是幂等的；换路径必须先 [`close_db`]，否则报错，
/// 避免「以为切了库、其实还在写旧库」。
pub fn init_db(path: String) -> anyhow::Result<()> {
    let mut guard = cell()
        .lock()
        .map_err(|_| anyhow::anyhow!("曲库连接锁已中毒（此前有线程 panic）"))?;

    if let Some(db) = guard.as_ref() {
        if db.path == path {
            return Ok(());
        }
        bail!("曲库已初始化为 {}，切换路径前请先调用 close_db()", db.path);
    }

    let mut conn = Connection::open(&path).with_context(|| format!("打开曲库失败: {path}"))?;
    conn.execute_batch("PRAGMA journal_mode = WAL;")?;
    // 歌单 / 收藏 / 历史用外键关联 tracks.path，删除曲目时要级联清理
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    // 外部工具（备份脚本、DB 客户端）持写锁时等一会儿，而不是立刻 SQLITE_BUSY
    conn.execute_batch("PRAGMA busy_timeout = 5000;")?;
    backup_before_upgrade(&mut conn, &path);
    migrate(&mut conn)?;

    *guard = Some(Database { path, conn });
    Ok(())
}

/// 升级结构前把整个库复制成 `<path>.bak`。
///
/// 迁移里全是 `ALTER TABLE` / `UPDATE`，中途失败或新版有 bug 时数据是回不去的；
/// 有一份升级前的副本，用户改回旧版（或手工换回 .bak）就能回到原样。
/// 备份失败只记日志不阻断启动——打不开曲库比缺一份副本更糟。
fn backup_before_upgrade(conn: &mut Connection, path: &str) {
    let Ok(version) = conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
    else {
        return;
    };
    if version >= SCHEMA_VERSION {
        return;
    }
    let source = Path::new(path);
    if source.metadata().map(|meta| meta.len()).unwrap_or(0) == 0 {
        // 刚建的空库，没有可备份的东西
        return;
    }
    // WAL 里可能压着还没落盘的数据，先合并再复制，否则副本是残缺的
    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    let backup = PathBuf::from(format!("{path}.bak"));
    if let Err(error) = fs::copy(source, &backup) {
        eprintln!("升级前备份曲库失败（{}）：{error}", backup.display());
    }
}

/// 关闭曲库连接，释放文件句柄；之后可以再次 `init_db` 到别的路径。
///
/// 关闭前做两件收尾：`PRAGMA optimize` 让查询计划统计信息落盘、
/// `wal_checkpoint(TRUNCATE)` 把 WAL 合并回主库并清空——只关连接不 checkpoint，
/// 曲目数据会一直堆在 `-wal` 里（主库看着只有几 KB），任何「只拷主库」的备份
/// 都会丢数据。
pub fn close_db() -> anyhow::Result<()> {
    let mut guard = cell()
        .lock()
        .map_err(|_| anyhow::anyhow!("曲库连接锁已中毒（此前有线程 panic）"))?;
    if let Some(db) = guard.as_mut() {
        // 两条都是尽力而为：外部工具正持锁时 checkpoint 会返回 busy，不该让退出失败
        let _ = db.conn.execute_batch("PRAGMA optimize;");
        let _ = db.conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    }
    *guard = None;
    Ok(())
}

/// 封面缓存目录：与曲库文件同级（`<支持目录>/covers`）。
///
/// 让缓存跟着曲库走，扫描器不需要额外参数；换库路径时封面目录也随之切换。
pub(crate) fn covers_dir() -> anyhow::Result<PathBuf> {
    let guard = cell()
        .lock()
        .map_err(|_| anyhow::anyhow!("曲库连接锁已中毒（此前有线程 panic）"))?;
    let db = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("曲库未初始化：请先调用 init_db(path)"))?;
    let parent = Path::new(&db.path)
        .parent()
        .unwrap_or_else(|| Path::new(""));
    Ok(parent.join("covers"))
}

/// 正在扫描的线程数（通常 0 或 1）。
///
/// 扫描是「先把封面落盘、最后才 upsert 入库」：这段窗口里封面文件已经存在，
/// 但还没有任何曲目引用它。若此时用户删曲目 / 清理缺失文件触发
/// [`prune_unused_covers`]，新封面会被当成残留删掉，扫描完就显示不出封面。
static SCANNING: AtomicUsize = AtomicUsize::new(0);

/// 在扫描期间执行 [`f`]，期间暂停封面回收；无论成功失败都会恢复。
pub(crate) fn with_scanning<T>(f: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<T> {
    SCANNING.fetch_add(1, Ordering::SeqCst);
    let result = f();
    SCANNING.fetch_sub(1, Ordering::SeqCst);
    result
}

/// 清掉没有被任何曲目引用的封面文件（换封面、删曲目后的残留）。
///
/// 只看曲库目录下的缓存文件；路径转不成 UTF-8 的文件不碰，避免误删。
///
/// 扫描进行中直接跳过：此时封面可能已落盘但尚未入库（见 [`SCANNING`]），
/// 回收交给扫描结束时那一次。
pub(crate) fn prune_unused_covers() -> anyhow::Result<i32> {
    if SCANNING.load(Ordering::SeqCst) > 0 {
        return Ok(0);
    }
    let dir = covers_dir()?;
    if !dir.is_dir() {
        return Ok(0);
    }

    let referenced: HashSet<String> = with_conn(|conn| {
        let mut stmt =
            conn.prepare_cached("SELECT cover_path FROM tracks WHERE cover_path <> ''")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<HashSet<_>, _>>()?)
    })?;

    let mut removed = 0;
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let path = entry.path();
        let keep = match path.to_str() {
            Some(text) => referenced.contains(text),
            None => true,
        };
        if !keep && fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

const SCHEMA_V1: &str = r#"
CREATE TABLE IF NOT EXISTS tracks (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    path          TEXT    NOT NULL UNIQUE,
    title         TEXT    NOT NULL DEFAULT '',
    artist        TEXT    NOT NULL DEFAULT '',
    album         TEXT    NOT NULL DEFAULT '',
    duration_secs REAL    NOT NULL DEFAULT 0,
    track_num     INTEGER NOT NULL DEFAULT 0,
    added_at      INTEGER NOT NULL DEFAULT 0,
    file_mtime    INTEGER NOT NULL DEFAULT 0,
    file_size     INTEGER NOT NULL DEFAULT 0
);

CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5 (
    title, artist, album,
    content = 'tracks',
    content_rowid = 'id'
);

CREATE TRIGGER IF NOT EXISTS tracks_ai AFTER INSERT ON tracks BEGIN
    INSERT INTO tracks_fts(rowid, title, artist, album)
    VALUES (new.id, new.title, new.artist, new.album);
END;

CREATE TRIGGER IF NOT EXISTS tracks_ad AFTER DELETE ON tracks BEGIN
    INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album)
    VALUES ('delete', old.id, old.title, old.artist, old.album);
END;

CREATE TRIGGER IF NOT EXISTS tracks_au AFTER UPDATE ON tracks BEGIN
    INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album)
    VALUES ('delete', old.id, old.title, old.artist, old.album);
    INSERT INTO tracks_fts(rowid, title, artist, album)
    VALUES (new.id, new.title, new.artist, new.album);
END;
"#;

/// v2：歌单 / 收藏 / 播放历史。
///
/// 都通过 `track_path` 关联 `tracks(path)`（该列有 UNIQUE 索引，可作外键目标），
/// `ON DELETE CASCADE` 保证曲目被清理时不留悬空引用。
///
/// - 歌单顺序按加入时间，暂不支持手动排序；
/// - 歌单名忽略 ASCII 大小写唯一；
/// - 历史按曲目去重，累计 `play_count` 并记录最近播放时间。
const SCHEMA_V2: &str = r#"
CREATE TABLE IF NOT EXISTS playlists (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS playlists_name ON playlists(name COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS playlist_items (
    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_path  TEXT    NOT NULL REFERENCES tracks(path) ON DELETE CASCADE,
    added_at    INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, track_path)
);

CREATE INDEX IF NOT EXISTS playlist_items_track ON playlist_items(track_path);

CREATE TABLE IF NOT EXISTS favorites (
    track_path TEXT    NOT NULL PRIMARY KEY REFERENCES tracks(path) ON DELETE CASCADE,
    added_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS play_history (
    track_path     TEXT    NOT NULL PRIMARY KEY REFERENCES tracks(path) ON DELETE CASCADE,
    last_played_at INTEGER NOT NULL,
    play_count     INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS play_history_recent ON play_history(last_played_at DESC);
"#;

/// schema v4：听歌时长。
///
/// 按「曲目 × 本地日期」聚合，不记录每次播放，写放大可控；
/// `day` 是本地日期整数（如 `20261026`），热力图按它做范围扫描。
const SCHEMA_V4: &str = r#"
CREATE TABLE IF NOT EXISTS play_sessions (
    track_path TEXT    NOT NULL REFERENCES tracks(path) ON DELETE CASCADE,
    day        INTEGER NOT NULL,
    seconds    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (track_path, day)
);

CREATE INDEX IF NOT EXISTS play_sessions_day ON play_sessions(day DESC);
"#;

/// 依版本号升级库结构。老库（`user_version = 0`）可能已有表，需要逐列补。
fn migrate(conn: &mut Connection) -> anyhow::Result<()> {
    let version: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

    if version > SCHEMA_VERSION {
        bail!("曲库结构版本 {version} 高于当前程序支持的 {SCHEMA_VERSION}，请升级 Lamp Player");
    }

    if version < 1 {
        conn.execute_batch(SCHEMA_V1)?;
        // v1 之前建的库没有增量扫描需要的两列
        if !column_exists(conn, "tracks", "file_mtime")? {
            conn.execute_batch(
                "ALTER TABLE tracks ADD COLUMN file_mtime INTEGER NOT NULL DEFAULT 0;",
            )?;
        }
        if !column_exists(conn, "tracks", "file_size")? {
            conn.execute_batch(
                "ALTER TABLE tracks ADD COLUMN file_size INTEGER NOT NULL DEFAULT 0;",
            )?;
        }
        // 老库可能缺触发器或索引漂移，重建一次最省心（只发生在升级那一次）
        conn.execute_batch("INSERT INTO tracks_fts(tracks_fts) VALUES('rebuild');")?;
        conn.pragma_update(None, "user_version", 1)?;
    }

    if version < 2 {
        conn.execute_batch(SCHEMA_V2)?;
        conn.pragma_update(None, "user_version", 2)?;
    }

    if version < 3 {
        // v3：封面缓存路径。老库没有封面，把文件指纹清零，让下次扫描重新解析
        // 一遍（否则未变化的文件会被增量扫描跳过，封面永远补不上）。
        if !column_exists(conn, "tracks", "cover_path")? {
            conn.execute_batch(
                "ALTER TABLE tracks ADD COLUMN cover_path TEXT NOT NULL DEFAULT '';",
            )?;
        }
        conn.execute_batch("UPDATE tracks SET file_mtime = 0, file_size = 0;")?;
        conn.pragma_update(None, "user_version", 3)?;
    }

    if version < 4 {
        conn.execute_batch(SCHEMA_V4)?;
        conn.pragma_update(None, "user_version", 4)?;
    }

    if version < 5 {
        // v5：ReplayGain 曲目增益。老库没有这个标签，清零即可；下次扫描会补。
        if !column_exists(conn, "tracks", "replay_gain")? {
            conn.execute_batch(
                "ALTER TABLE tracks ADD COLUMN replay_gain REAL NOT NULL DEFAULT 0;",
            )?;
        }
        conn.pragma_update(None, "user_version", 5)?;
    }

    Ok(())
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> anyhow::Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name.eq_ignore_ascii_case(column) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// FTS5 全文检索（歌名/歌手/专辑）。
///
/// 每个词都包成短语并做前缀匹配（`"周杰"*`），因此 `-`、`+`、`:`、引号
/// 等字符只会被当字面量，不会变成 FTS5 查询语法；空查询直接返回空列表。
pub fn search_tracks(query: String, limit: i32) -> anyhow::Result<Vec<Track>> {
    let limit = limit.clamp(1, 2000);
    let Some(fts_query) = fts_prefix_query(&query) else {
        return Ok(Vec::new());
    };

    let mut results = with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at, t.cover_path, t.replay_gain
            FROM tracks t
            JOIN tracks_fts f ON f.rowid = t.id
            WHERE tracks_fts MATCH ?1
            ORDER BY bm25(tracks_fts), t.id
            LIMIT ?2
            "#,
        )?;
        let rows = stmt.query_map(params![fts_query, limit], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;

    // FTS5 的 unicode61 不切分 CJK：「林间电台」整条是一个 token，
    // 所以「电台」这种词中间的子串用前缀查询永远搜不到。
    // 前缀没搜满时补一条子串匹配，命中结果按顺序追加在后面。
    if results.len() >= limit as usize {
        return Ok(results);
    }
    let extra = substring_search(&query, limit)?;
    let mut seen: HashSet<String> = results.iter().map(|track| track.path.clone()).collect();
    for track in extra {
        if seen.insert(track.path.clone()) {
            results.push(track);
            if results.len() >= limit as usize {
                break;
            }
        }
    }
    Ok(results)
}

/// 子串匹配兜底：补上 FTS 前缀查不到的情况（中文词中间、英文词中片段）。
///
/// 只扫 title / artist / album 的拼接串并用 `LIMIT` 截断，万级曲库也是毫秒级；
/// 多个词之间是 AND 关系，和搜索框的直觉一致。
fn substring_search(query: &str, limit: i32) -> anyhow::Result<Vec<Track>> {
    let terms: Vec<&str> = query
        .split_whitespace()
        .filter(|term| term.chars().any(char::is_alphanumeric))
        .collect();
    if terms.is_empty() {
        return Ok(Vec::new());
    }

    let fields = "(title || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, ''))";
    let mut sql = String::from(
        "SELECT path, title, artist, album, duration_secs, track_num, added_at, cover_path, replay_gain \
         FROM tracks WHERE ",
    );
    for index in 0..terms.len() {
        if index > 0 {
            sql.push_str(" AND ");
        }
        sql.push_str(&format!("{fields} LIKE ?{} ESCAPE '\\'", index + 1));
    }
    sql.push_str(&format!(
        " ORDER BY title, artist, id LIMIT ?{}",
        terms.len() + 1
    ));

    let patterns: Vec<String> = terms
        .iter()
        .map(|term| format!("%{}%", escape_like(term)))
        .collect();

    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(&sql)?;
        let mut values: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(patterns.len() + 1);
        for pattern in &patterns {
            values.push(pattern);
        }
        values.push(&limit);
        let rows = stmt.query_map(rusqlite::params_from_iter(values), row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 转义 LIKE 的通配符，否则用户输入的 `%` / `_` 会变成通配符
fn escape_like(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for ch in text.chars() {
        if matches!(ch, '%' | '_' | '\\') {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}

/// 把用户输入转成 FTS5 前缀查询；没有任何可检索词时返回 `None`。
fn fts_prefix_query(query: &str) -> Option<String> {
    let terms: Vec<String> = query
        .split_whitespace()
        .map(|term| term.replace('"', ""))
        .filter(|term| term.chars().any(char::is_alphanumeric))
        .map(|term| format!("\"{term}\"*"))
        .collect();
    (!terms.is_empty()).then(|| terms.join(" "))
}

/// 全量曲库（按歌手、专辑、曲号排序）
pub fn all_tracks() -> anyhow::Result<Vec<Track>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT path, title, artist, album, duration_secs, track_num, added_at, cover_path, replay_gain
            FROM tracks
            ORDER BY artist, album, track_num, title
            "#,
        )?;
        let rows = stmt.query_map([], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 批量写入/更新（按 path 去重），整个批次在一个事务里完成。
///
/// 不携带文件指纹（mtime/size），因此不会覆盖扫描记录里的增量信息。
pub fn upsert_tracks(tracks: Vec<Track>) -> anyhow::Result<i32> {
    if tracks.is_empty() {
        return Ok(0);
    }
    let paths: Vec<&str> = tracks.iter().map(|t| t.path.as_str()).collect();

    with_conn(|conn| {
        let tx = conn.transaction()?;
        reconcile_paths(&tx, &paths)?;
        {
            let mut stmt = tx.prepare_cached(
                r#"
                INSERT INTO tracks (path, title, artist, album, duration_secs, track_num, added_at, cover_path, replay_gain)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE(?8, ''), ?9)
                ON CONFLICT(path) DO UPDATE SET
                    title         = excluded.title,
                    artist        = excluded.artist,
                    album         = excluded.album,
                    duration_secs = excluded.duration_secs,
                    track_num     = excluded.track_num,
                    cover_path    = COALESCE(?8, tracks.cover_path),
                    replay_gain   = excluded.replay_gain
                "#,
            )?;
            for t in &tracks {
                stmt.execute(params![
                    t.path,
                    t.title,
                    t.artist.as_deref().unwrap_or(""),
                    t.album.as_deref().unwrap_or(""),
                    t.duration_secs,
                    t.track_num.unwrap_or(0),
                    t.added_at,
                    t.cover_path,
                    t.replay_gain
                ])?;
            }
        }
        tx.commit()?;
        Ok(tracks.len() as i32)
    })
}

/// 扫描链路专用写入：额外记录文件指纹，供下次增量扫描比对。
///
/// 路径归一化处理同 [`upsert_tracks`]。
pub(crate) fn upsert_scanned(items: &[ScannedTrack]) -> anyhow::Result<i32> {
    if items.is_empty() {
        return Ok(0);
    }
    let paths: Vec<&str> = items.iter().map(|item| item.track.path.as_str()).collect();

    with_conn(|conn| {
        let tx = conn.transaction()?;
        reconcile_paths(&tx, &paths)?;
        {
            let mut stmt = tx.prepare_cached(
                r#"
                INSERT INTO tracks
                    (path, title, artist, album, duration_secs, track_num, added_at, file_mtime, file_size, cover_path, replay_gain)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, COALESCE(?10, ''), ?11)
                ON CONFLICT(path) DO UPDATE SET
                    title         = excluded.title,
                    artist        = excluded.artist,
                    album         = excluded.album,
                    duration_secs = excluded.duration_secs,
                    track_num     = excluded.track_num,
                    file_mtime    = excluded.file_mtime,
                    file_size     = excluded.file_size,
                    -- 重新解析失败（文件损坏、插件临时不可用）时不要把已有封面抹掉
                    cover_path    = CASE
                        WHEN excluded.cover_path <> '' THEN excluded.cover_path
                        ELSE tracks.cover_path
                    END,
                    replay_gain   = excluded.replay_gain
                "#,
            )?;
            for item in items {
                let t = &item.track;
                stmt.execute(params![
                    t.path,
                    t.title,
                    t.artist.as_deref().unwrap_or(""),
                    t.album.as_deref().unwrap_or(""),
                    t.duration_secs,
                    t.track_num.unwrap_or(0),
                    t.added_at,
                    item.mtime_ns,
                    item.size,
                    t.cover_path,
                    t.replay_gain
                ])?;
            }
        }
        tx.commit()?;
        Ok(items.len() as i32)
    })
}

/// 已入库文件的指纹（path → (mtime_ns, size)），供扫描时跳过未变文件。
pub(crate) fn file_signatures() -> anyhow::Result<HashMap<String, (i64, i64)>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            "SELECT path, file_mtime, file_size FROM tracks WHERE file_mtime > 0",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?;
        let mut map = HashMap::new();
        for row in rows {
            let (path, mtime, size) = row?;
            // key 归一化，配合 scanner::path_key 的同口径比对
            map.insert(path_key(&path), (mtime, size));
        }
        Ok(map)
    })
}

/// 至少要有这么多曲目才启用「删除比例」保护（小库删几首是正常的）
const PRUNE_GUARD_MIN_TOTAL: usize = 10;

/// 一次清理超过这个比例就判定为「整块盘不可达」，拒绝删除
const PRUNE_GUARD_MAX_RATIO: f64 = 0.5;

/// 文件是否确实不存在。
///
/// `Path::exists()` 把「权限不足 / 共享断连 / IO 错误」也一并当成不存在，
/// 曲库不足 [`PRUNE_GUARD_MIN_TOTAL`] 首时删除比例保护不生效，会误删整批记录。
/// 这里只认 `NotFound`；其它错误按「还在」处理，宁可少删也不删错。
fn file_missing(path: &str) -> bool {
    match fs::metadata(path) {
        Ok(_) => false,
        Err(error) => error.kind() == std::io::ErrorKind::NotFound,
    }
}

/// 曲目路径所在的卷根（`E:/Music/a.mp3` → `E:/`，UNC → `//server/share`）。///
/// 用于判断「同一块盘的其它文件是否还在」：盘没挂载时整卷文件都 `exists()==false`，
/// 直接按缺失删除会把歌单/收藏/历史级联清空。
fn volume_root(path: &str) -> Option<String> {
    use std::path::Component;
    let mut components = Path::new(path).components();
    match components.next() {
        Some(Component::Prefix(prefix)) => {
            let mut root = prefix.as_os_str().to_string_lossy().to_string();
            if !root.ends_with(std::path::MAIN_SEPARATOR) {
                root.push(std::path::MAIN_SEPARATOR);
            }
            Some(root)
        }
        Some(Component::RootDir) => Some(std::path::MAIN_SEPARATOR.to_string()),
        _ => None,
    }
}

/// 已有封面路径指向的文件是否还在；不在就返回这些曲目的 path。
///
/// 封面缓存被清理、曲库搬家后，文件本身没变（mtime/size 一致）会被增量扫描
/// 跳过，封面就永远不会重新提取。扫描前先把这些曲目的指纹抹掉，强制重解析。
pub(crate) fn tracks_with_missing_covers() -> anyhow::Result<Vec<String>> {
    let rows: Vec<(String, String)> = with_conn(|conn| {
        let mut stmt =
            conn.prepare_cached("SELECT path, cover_path FROM tracks WHERE cover_path <> ''")?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;
    Ok(rows
        .into_iter()
        .filter(|(_, cover)| !Path::new(cover).exists())
        .map(|(path, _)| path)
        .collect())
}

/// 清理已不存在的文件记录，返回删除数。
///
/// 磁盘检查在锁外完成，避免网络盘/大曲库把其它查询一起卡住；删除在单事务里。
///
/// 两道防护，避免「移动硬盘/网络盘没挂载」时把整个曲库删空（`delete_tracks`
/// 会级联清掉歌单、收藏、播放历史）：
/// 1. **卷根可达性**：某块盘的根目录都读不到时，该卷下的曲目一律不算缺失；
/// 2. **删除比例**：一次要删超过一半（且总数 ≥ 10）时判定为异常，直接报错不动库。
pub fn prune_missing_tracks() -> anyhow::Result<i32> {
    let rows: Vec<(i64, String)> = with_conn(|conn| {
        let mut stmt = conn.prepare_cached("SELECT id, path FROM tracks")?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;

    let total = rows.len();
    let mut reachable: HashMap<String, bool> = HashMap::new();
    let mut missing: Vec<i64> = Vec::new();
    let mut skipped_volumes: HashSet<String> = HashSet::new();
    for (id, path) in &rows {
        // 只有「确实不存在」才算缺失：权限不足、共享断连、IO 错误都会被
        // `Path::exists()` 判成 false，那会误删整批记录（连带级联清收藏 / 歌单 / 历史）
        if !file_missing(path) {
            continue;
        }
        let Some(root) = volume_root(path) else {
            missing.push(*id);
            continue;
        };
        let ok = *reachable
            .entry(root.clone())
            .or_insert_with(|| Path::new(&root).exists());
        if ok {
            missing.push(*id);
        } else {
            skipped_volumes.insert(root);
        }
    }

    if !skipped_volumes.is_empty() {
        // 卷不可达：整体跳过这部分，只清理确认可达的盘上真正消失的文件
        let mut list: Vec<String> = skipped_volumes.into_iter().collect();
        list.sort();
        eprintln!(
            "prune_missing_tracks: 跳过不可达的卷 {}（疑似未挂载）",
            list.join(", ")
        );
    }

    if total >= PRUNE_GUARD_MIN_TOTAL && missing.len() as f64 > total as f64 * PRUNE_GUARD_MAX_RATIO
    {
        bail!(
            "检测到 {} / {} 首曲目同时缺失，疑似磁盘未挂载或权限异常，已跳过清理",
            missing.len(),
            total
        );
    }

    let deleted = delete_tracks(&missing)?;
    if deleted > 0 {
        let _ = prune_unused_covers();
    }
    Ok(deleted)
}

/// 清理某个目录下「本次扫描没看到」的记录（文件被删除/移走），返回删除数。
///
/// 比较基于 [`path_key`] 归一化后的 key：Windows 下库里的历史路径与本次扫描
/// 传入的目录只在大小写/斜杠上不同时，也要能清到，且边界要用分隔符挡住
/// 「`E:\Music` 误匹配 `E:\Music2`」这种情况。
pub(crate) fn prune_tracks_under(folder: &Path, seen: &HashSet<String>) -> anyhow::Result<i32> {
    let folder_key = path_key(&folder.to_string_lossy());
    let prefix = folder_prefix(&folder_key, std::path::MAIN_SEPARATOR);

    let rows: Vec<(i64, String)> = with_conn(|conn| {
        let mut stmt = conn.prepare_cached("SELECT id, path FROM tracks")?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;

    let stale: Vec<i64> = rows
        .into_iter()
        .filter(|(_, path)| {
            let key = path_key(path);
            key.starts_with(&prefix) && !seen.contains(&key)
        })
        .map(|(id, _)| id)
        .collect();

    let deleted = delete_tracks(&stale)?;
    if deleted > 0 {
        let _ = prune_unused_covers();
    }
    Ok(deleted)
}

/// 目录前缀：去掉末尾分隔符后统一补一个分隔符，
/// 既能匹配子文件，又挡住「`E:\Music` 误匹配 `E:\Music2`」。
///
/// `sep` 必须传 [`std::path::MAIN_SEPARATOR`]：`path_key` 在 Windows 下会把 `/`
/// 归一成 `\`，在其它平台保持 `/`；写死反斜杠会让非 Windows 的前缀永远失配。
fn folder_prefix(folder_key: &str, sep: char) -> String {
    let trimmed = folder_key.trim_end_matches(sep);
    format!("{trimmed}{sep}")
}

/// 合并「同一文件、不同字面路径」的历史行（大小写、`/` 与 `\` 差异）。
///
/// `path UNIQUE` 是按字节比较的：Windows 上老记录可能存成 `e:/music/a.mp3`，
/// 本次扫描写入的是 canonicalize 后的 `E:\Music\a.mp3`，不处理就会留下两条。
/// 这里一次读出库里的行（每批只扫一次，不是每首歌一次），按 [`path_key`]
/// 找到本批次涉及的孪生行。不能直接删旧行：歌单、收藏、历史都通过
/// `track_path` 外键级联到 `tracks`，直接删会把用户数据一起清掉。
/// 因此先把旧路径的引用迁移到新路径（歌单/收藏去重，历史合并播放次数），
/// 再删旧行；字面完全一致的行保留，交给 `ON CONFLICT(path)` 原地更新。
fn reconcile_paths(tx: &rusqlite::Transaction<'_>, paths: &[&str]) -> anyhow::Result<()> {
    let targets: HashMap<String, &str> = paths.iter().map(|path| (path_key(path), *path)).collect();
    if targets.is_empty() {
        return Ok(());
    }

    let stale: Vec<(String, String)> = {
        let mut stmt = tx.prepare_cached("SELECT path FROM tracks")?;
        let mut rows = stmt.query([])?;
        let mut stale = Vec::new();
        while let Some(row) = rows.next()? {
            let path: String = row.get(0)?;
            if let Some(target) = targets.get(&path_key(&path)) {
                if path.as_str() != *target {
                    stale.push((path, (*target).to_string()));
                }
            }
        }
        stale
    };

    for (old_path, target_path) in stale {
        merge_track_path(tx, &old_path, &target_path)?;
    }
    Ok(())
}

/// 把 `old_path` 的曲目和用户数据迁移到 `target_path`。
///
/// 先保证目标曲目行存在（复制旧行，保留 `added_at`），再迁移歌单/收藏/历史，
/// 最后删除旧行。调用方必须已在事务中，且 `old_path != target_path`。
fn merge_track_path(
    tx: &rusqlite::Transaction<'_>,
    old_path: &str,
    target_path: &str,
) -> anyhow::Result<()> {
    let target_exists: i64 = tx.query_row(
        "SELECT COUNT(*) FROM tracks WHERE path = ?1",
        [target_path],
        |row| row.get(0),
    )?;

    if target_exists == 0 {
        // 目标行可能尚未由本次 upsert 插入；先复制旧行，外键才允许挂引用。
        let copied = tx.execute(
            r#"
            INSERT INTO tracks
                (path, title, artist, album, duration_secs, track_num, added_at, file_mtime, file_size, cover_path, replay_gain)
            SELECT ?1, title, artist, album, duration_secs, track_num, added_at, file_mtime, file_size, cover_path, replay_gain
            FROM tracks
            WHERE path = ?2
            "#,
            params![target_path, old_path],
        )?;
        if copied == 0 {
            return Ok(());
        }
    }

    // 收藏：目标已有则保留目标的加入时间，只清掉旧路径。
    tx.execute(
        r#"
        INSERT OR IGNORE INTO favorites (track_path, added_at)
        SELECT ?1, added_at FROM favorites WHERE track_path = ?2
        "#,
        params![target_path, old_path],
    )?;
    tx.execute("DELETE FROM favorites WHERE track_path = ?1", [old_path])?;

    // 歌单：同一歌单里已经存在目标曲目时去重，否则把旧条目迁过去。
    tx.execute(
        r#"
        INSERT OR IGNORE INTO playlist_items (playlist_id, track_path, added_at)
        SELECT playlist_id, ?1, added_at FROM playlist_items WHERE track_path = ?2
        "#,
        params![target_path, old_path],
    )?;
    tx.execute(
        "DELETE FROM playlist_items WHERE track_path = ?1",
        [old_path],
    )?;

    // 历史：按曲目去重，合并播放次数并保留较新的播放时间。
    tx.execute(
        r#"
        INSERT INTO play_history (track_path, last_played_at, play_count)
        SELECT ?1, last_played_at, play_count FROM play_history WHERE track_path = ?2
        ON CONFLICT(track_path) DO UPDATE SET
            last_played_at = max(play_history.last_played_at, excluded.last_played_at),
            play_count     = play_history.play_count + excluded.play_count
        "#,
        params![target_path, old_path],
    )?;
    tx.execute("DELETE FROM play_history WHERE track_path = ?1", [old_path])?;

    tx.execute("DELETE FROM tracks WHERE path = ?1", [old_path])?;
    Ok(())
}

/// 按路径批量删除曲库记录，返回实际删除数。
///
/// 只删数据库里的记录，不动磁盘上的音频文件；歌单 / 收藏 / 播放历史通过外键
/// 级联清理。匹配用 [`path_key`] 归一化，调用方传大小写 / 分隔符变体也能删到
/// （否则会「删 0 条且不报错」）。
pub fn remove_tracks(paths: Vec<String>) -> anyhow::Result<i32> {
    if paths.is_empty() {
        return Ok(0);
    }
    let keys: HashSet<String> = paths.iter().map(|path| path_key(path)).collect();

    // path_key 是 Rust 侧算的，SQL 里没有同款函数：先取 (id, path) 再在内存里筛
    let ids: Vec<i64> = with_conn(|conn| {
        let mut stmt = conn.prepare_cached("SELECT id, path FROM tracks")?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get::<_, String>(1)?)))?;
        let rows = rows.collect::<Result<Vec<(i64, String)>, _>>()?;
        Ok(rows
            .into_iter()
            .filter(|(_, path)| keys.contains(&path_key(path)))
            .map(|(id, _)| id)
            .collect::<Vec<i64>>())
    })?;

    let deleted = delete_tracks(&ids)?;
    if deleted > 0 {
        // 曲目一删，它们的封面就没人引用了；不顺手回收的话 covers/ 会一直留到下次扫描
        let _ = prune_unused_covers();
    }
    Ok(deleted)
}

/// 按 id 批量删除，返回删除数。
///
/// 一条 `DELETE ... WHERE id IN (...)` 比逐条执行快一个数量级；SQLite 的变量
/// 数量有上限（默认 999），所以按 500 个一批分开执行。
fn delete_tracks(ids: &[i64]) -> anyhow::Result<i32> {
    if ids.is_empty() {
        return Ok(0);
    }

    let mut deleted = 0usize;
    with_conn(|conn| {
        let tx = conn.transaction()?;
        {
            for chunk in ids.chunks(500) {
                let placeholders = std::iter::repeat_n("?", chunk.len())
                    .collect::<Vec<_>>()
                    .join(",");
                let sql = format!("DELETE FROM tracks WHERE id IN ({placeholders})");
                let mut stmt = tx.prepare(&sql)?;
                let params: Vec<&dyn rusqlite::ToSql> =
                    chunk.iter().map(|id| id as &dyn rusqlite::ToSql).collect();
                deleted += stmt.execute(rusqlite::params_from_iter(params))?;
            }
        }
        tx.commit()?;
        Ok(())
    })?;
    Ok(deleted as i32)
}

pub(crate) fn row_to_track(row: &Row) -> rusqlite::Result<Track> {
    Ok(Track {
        path: row.get(0)?,
        title: row.get(1)?,
        artist: some_if_not_empty(row.get::<_, String>(2)?),
        album: some_if_not_empty(row.get::<_, String>(3)?),
        duration_secs: row.get(4)?,
        track_num: Some(row.get::<_, i32>(5)?).filter(|n| *n > 0),
        added_at: row.get(6)?,
        cover_path: some_if_not_empty(row.get::<_, String>(7)?),
        replay_gain: row.get(8)?,
    })
}

fn some_if_not_empty(s: String) -> Option<String> {
    (!s.is_empty()).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::{folder_prefix, merge_track_path};
    use rusqlite::Connection;

    fn merge_fixture() -> Connection {
        let conn = Connection::open_in_memory().expect("内存库");
        conn.execute_batch(
            r#"
            PRAGMA foreign_keys = ON;
            CREATE TABLE tracks (
                path          TEXT PRIMARY KEY,
                title         TEXT NOT NULL DEFAULT '',
                artist        TEXT NOT NULL DEFAULT '',
                album         TEXT NOT NULL DEFAULT '',
                duration_secs REAL NOT NULL DEFAULT 0,
                track_num     INTEGER NOT NULL DEFAULT 0,
                added_at      INTEGER NOT NULL DEFAULT 0,
                file_mtime    INTEGER NOT NULL DEFAULT 0,
                file_size     INTEGER NOT NULL DEFAULT 0,
                cover_path    TEXT NOT NULL DEFAULT '',
                replay_gain   REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE playlists (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE playlist_items (
                playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                track_path  TEXT NOT NULL REFERENCES tracks(path) ON DELETE CASCADE,
                added_at    INTEGER NOT NULL,
                PRIMARY KEY (playlist_id, track_path)
            );
            CREATE TABLE favorites (
                track_path TEXT PRIMARY KEY REFERENCES tracks(path) ON DELETE CASCADE,
                added_at   INTEGER NOT NULL
            );
            CREATE TABLE play_history (
                track_path     TEXT PRIMARY KEY REFERENCES tracks(path) ON DELETE CASCADE,
                last_played_at INTEGER NOT NULL,
                play_count     INTEGER NOT NULL DEFAULT 1
            );
            "#,
        )
        .expect("建表");
        conn
    }

    #[test]
    fn merge_track_path_keeps_user_data_when_target_is_new() {
        let mut conn = merge_fixture();
        conn.execute(
            "INSERT INTO tracks (path, title, added_at) VALUES (?1, '旧标题', 42)",
            ["/music/Old.mp3"],
        )
        .expect("旧曲目");
        conn.execute(
            "INSERT INTO playlists (id, name, created_at, updated_at) VALUES (1, 'P', 1, 1)",
            [],
        )
        .expect("歌单");
        conn.execute(
            "INSERT INTO playlist_items VALUES (1, '/music/Old.mp3', 10)",
            [],
        )
        .expect("歌单条目");
        conn.execute("INSERT INTO favorites VALUES ('/music/Old.mp3', 20)", [])
            .expect("收藏");
        conn.execute(
            "INSERT INTO play_history VALUES ('/music/Old.mp3', 100, 2)",
            [],
        )
        .expect("历史");

        let tx = conn.transaction().expect("事务");
        merge_track_path(&tx, "/music/Old.mp3", "/music/new.mp3").expect("合并路径");
        tx.commit().expect("提交");

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .expect("曲目数");
        assert_eq!(count, 1);
        let (title, added_at): (String, i64) = conn
            .query_row(
                "SELECT title, added_at FROM tracks WHERE path = ?1",
                ["/music/new.mp3"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("目标曲目");
        assert_eq!(title, "旧标题");
        assert_eq!(added_at, 42, "合并应保留原入库时间");

        let favorite: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM favorites WHERE track_path = ?1",
                ["/music/new.mp3"],
                |row| row.get(0),
            )
            .expect("收藏");
        assert_eq!(favorite, 1);
        let item: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM playlist_items WHERE track_path = ?1",
                ["/music/new.mp3"],
                |row| row.get(0),
            )
            .expect("歌单条目");
        assert_eq!(item, 1);
        let history: (i64, i64) = conn
            .query_row(
                "SELECT last_played_at, play_count FROM play_history WHERE track_path = ?1",
                ["/music/new.mp3"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("历史");
        assert_eq!(history, (100, 2));
    }

    #[test]
    fn merge_track_path_merges_duplicate_target_rows() {
        let mut conn = merge_fixture();
        conn.execute_batch(
            r#"
            INSERT INTO tracks (path, title, added_at)
            VALUES ('/music/Old.mp3', '旧', 1), ('/music/new.mp3', '新', 2);
            INSERT INTO playlists (id, name, created_at, updated_at) VALUES (1, 'P', 1, 1);
            INSERT INTO playlist_items VALUES
                (1, '/music/Old.mp3', 10), (1, '/music/new.mp3', 20);
            INSERT INTO favorites VALUES
                ('/music/Old.mp3', 10), ('/music/new.mp3', 20);
            INSERT INTO play_history VALUES
                ('/music/Old.mp3', 100, 2), ('/music/new.mp3', 200, 3);
            "#,
        )
        .expect("准备数据");

        let tx = conn.transaction().expect("事务");
        merge_track_path(&tx, "/music/Old.mp3", "/music/new.mp3").expect("合并路径");
        tx.commit().expect("提交");

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .expect("曲目数");
        assert_eq!(count, 1);

        let favorite: i64 = conn
            .query_row("SELECT COUNT(*) FROM favorites", [], |row| row.get(0))
            .expect("收藏数");
        assert_eq!(favorite, 1, "同一曲目只保留一条收藏");
        let item: i64 = conn
            .query_row("SELECT COUNT(*) FROM playlist_items", [], |row| row.get(0))
            .expect("歌单条目数");
        assert_eq!(item, 1, "同一歌单只保留一条");

        let (last, plays): (i64, i64) = conn
            .query_row(
                "SELECT last_played_at, play_count FROM play_history WHERE track_path = ?1",
                ["/music/new.mp3"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("历史");
        assert_eq!(last, 200, "保留较新的播放时间");
        assert_eq!(plays, 5, "播放次数应累加");
    }

    #[test]
    fn folder_prefix_uses_given_separator() {
        // 非 Windows 分支：旧实现写死 '\' 时这里会失败
        assert_eq!(folder_prefix("/music", '/'), "/music/");
        assert_eq!(folder_prefix("/", '/'), "/");

        // Windows 分支：末尾分隔符不重复，根目录也能用
        assert_eq!(folder_prefix("e:\\music", '\\'), "e:\\music\\");
        assert_eq!(folder_prefix("e:\\music\\", '\\'), "e:\\music\\");
        assert_eq!(folder_prefix("\\", '\\'), "\\");
    }

    /// 扫描窗口内封面已落盘但尚未入库：此时回收必须让路，否则会把新封面删掉。
    #[test]
    fn prune_unused_covers_is_paused_while_scanning() {
        use super::{close_db, init_db, prune_unused_covers, with_scanning};
        use std::time::{SystemTime, UNIX_EPOCH};

        let _guard = db_guard();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("lamp_prune_{}_{}", std::process::id(), nanos));
        let covers = dir.join("covers");
        std::fs::create_dir_all(&covers).expect("创建封面目录");
        let orphan = covers.join("orphan.jpg");
        std::fs::write(&orphan, b"cover").expect("写入封面");

        init_db(dir.join("library.db").to_string_lossy().into_owned()).expect("初始化曲库");

        {
            with_scanning(|| {
                assert_eq!(
                    prune_unused_covers().expect("扫描中回收"),
                    0,
                    "扫描期间不该删任何封面"
                );
                assert!(orphan.exists(), "扫描中未入库的新封面必须保留");
                Ok(())
            })
            .expect("扫描中执行");
        }

        assert_eq!(
            prune_unused_covers().expect("扫描结束后回收"),
            1,
            "扫描结束后才清理真正的残留"
        );
        assert!(!orphan.exists());

        close_db().expect("关闭曲库");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 曲库是进程级单例：凡是要 `init_db` 的用例必须串行跑
    static DB_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn db_guard() -> std::sync::MutexGuard<'static, ()> {
        DB_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn temp_path(tag: &str) -> std::path::PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|dur| dur.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("lamp_{tag}_{}_{}", std::process::id(), nanos));
        std::fs::create_dir_all(&dir).expect("创建临时目录");
        dir.join("library.db")
    }

    /// 关闭曲库要把 WAL 合并回主库并截断：只关连接的话曲目数据一直压在
    /// `-wal` 里（主库看着只有几 KB），只拷主库的备份会丢数据。
    #[test]
    fn close_db_checkpoints_and_truncates_wal() {
        use super::{close_db, init_db, with_conn};

        let _guard = db_guard();
        let path = temp_path("close_wal");
        let path_text = path.to_string_lossy().into_owned();
        init_db(path_text.clone()).expect("初始化曲库");
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO tracks (path, title) VALUES ('/music/a.mp3', '夜航')",
                [],
            )?;
            Ok(())
        })
        .expect("写入曲目");

        let wal = std::path::PathBuf::from(format!("{path_text}-wal"));
        assert!(
            wal.metadata().map(|meta| meta.len()).unwrap_or(0) > 0,
            "写入后 WAL 应非空"
        );

        close_db().expect("关闭曲库");
        assert_eq!(
            wal.metadata().map(|meta| meta.len()).unwrap_or(0),
            0,
            "关闭时应截断 WAL"
        );

        let conn = Connection::open(&path).expect("直接打开主库");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .expect("曲目数");
        assert_eq!(count, 1, "数据应已合并进主库");
        drop(conn);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// 结构升级前留一份 `.bak`：迁移中途失败或新版有 bug 时有回退点。
    #[test]
    fn upgrade_keeps_backup_of_previous_version() {
        use super::{close_db, init_db, with_conn};

        let _guard = db_guard();
        let path = temp_path("upgrade_bak");
        let path_text = path.to_string_lossy().into_owned();
        init_db(path_text.clone()).expect("初始化曲库");
        with_conn(|conn| {
            conn.execute(
                "INSERT INTO tracks (path, title) VALUES ('/music/b.mp3', '灯下')",
                [],
            )?;
            Ok(())
        })
        .expect("写入曲目");
        close_db().expect("关闭曲库");

        // 把版本号退回去，模拟旧版程序建的曲库
        {
            let conn = Connection::open(&path).expect("改版本号");
            conn.pragma_update(None, "user_version", 3).expect("写版本");
        }

        init_db(path_text.clone()).expect("重新初始化触发升级");
        let backup = std::path::PathBuf::from(format!("{path_text}.bak"));
        assert!(backup.is_file(), "升级前应留下 .bak");

        let conn = Connection::open(&backup).expect("打开备份");
        let version: i32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .expect("备份版本");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))
            .expect("备份曲目数");
        assert_eq!(version, 3, "备份应是升级前的结构版本");
        assert_eq!(count, 1, "备份里应含升级前的数据");
        drop(conn);

        close_db().expect("关闭曲库");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}

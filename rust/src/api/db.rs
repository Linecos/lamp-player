//! 曲库持久化：SQLite + FTS5 全文检索
//!
//! 表结构有版本号（`PRAGMA user_version`），升级时在 [`migrate`] 里追加一段，
//! 不要靠 `CREATE TABLE IF NOT EXISTS` 猜——它不会给老库补列。

use crate::api::model::Track;
use crate::scanner::{path_key, ScannedTrack};
use anyhow::{bail, Context};
use rusqlite::{params, Connection, Row};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Mutex, OnceLock};

/// 曲库结构版本。每次改表结构 +1，并在 [`migrate`] 里补升级逻辑。
const SCHEMA_VERSION: i32 = 1;

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
fn with_conn<T>(f: impl FnOnce(&mut Connection) -> anyhow::Result<T>) -> anyhow::Result<T> {
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
    migrate(&mut conn)?;

    *guard = Some(Database { path, conn });
    Ok(())
}

/// 关闭曲库连接，释放文件句柄；之后可以再次 `init_db` 到别的路径。
pub fn close_db() -> anyhow::Result<()> {
    let mut guard = cell()
        .lock()
        .map_err(|_| anyhow::anyhow!("曲库连接锁已中毒（此前有线程 panic）"))?;
    *guard = None;
    Ok(())
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
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
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
    let Some(fts_query) = fts_prefix_query(&query) else {
        return Ok(Vec::new());
    };

    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at
            FROM tracks t
            JOIN tracks_fts f ON f.rowid = t.id
            WHERE tracks_fts MATCH ?1
            ORDER BY bm25(tracks_fts), t.id
            LIMIT ?2
            "#,
        )?;
        let rows = stmt.query_map(params![fts_query, limit.clamp(1, 2000)], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
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
            SELECT path, title, artist, album, duration_secs, track_num, added_at
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
/// 注意 `path UNIQUE` 的冲突判定是区分大小写的：Windows 下同一文件写成
/// `E:\Music\a.mp3` 和 `e:\music\a.mp3` 不会撞上，所以写入前先删掉
/// 「忽略大小写后与目标路径相同、但字面不同」的历史遗留行，避免重复记录。
pub fn upsert_tracks(tracks: Vec<Track>) -> anyhow::Result<i32> {
    if tracks.is_empty() {
        return Ok(0);
    }

    with_conn(|conn| {
        let tx = conn.transaction()?;
        {
            // 见函数 doc：删掉同一文件的大小写孪生行
            // （必须与 stmt 同一作用域，Drop 在 commit 之前发生）
            let mut twin = tx.prepare_cached(
                "DELETE FROM tracks WHERE path = ?1 COLLATE NOCASE AND path <> ?1",
            )?;
            let mut stmt = tx.prepare_cached(
                r#"
                INSERT INTO tracks (path, title, artist, album, duration_secs, track_num, added_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(path) DO UPDATE SET
                    title         = excluded.title,
                    artist        = excluded.artist,
                    album         = excluded.album,
                    duration_secs = excluded.duration_secs,
                    track_num     = excluded.track_num
                "#,
            )?;
            for t in &tracks {
                twin.execute(params![t.path])?;
                stmt.execute(params![
                    t.path,
                    t.title,
                    t.artist.as_deref().unwrap_or(""),
                    t.album.as_deref().unwrap_or(""),
                    t.duration_secs,
                    t.track_num.unwrap_or(0),
                    t.added_at
                ])?;
            }
        }
        tx.commit()?;
        Ok(tracks.len() as i32)
    })
}

/// 扫描链路专用写入：额外记录文件指纹，供下次增量扫描比对。
///
/// 大小写孪生行的处理同 [`upsert_tracks`]。
pub(crate) fn upsert_scanned(items: &[ScannedTrack]) -> anyhow::Result<i32> {
    if items.is_empty() {
        return Ok(0);
    }

    with_conn(|conn| {
        let tx = conn.transaction()?;
        {
            // 见 upsert_tracks：删掉同一文件的大小写孪生行
            let mut twin = tx.prepare_cached(
                "DELETE FROM tracks WHERE path = ?1 COLLATE NOCASE AND path <> ?1",
            )?;
            let mut stmt = tx.prepare_cached(
                r#"
                INSERT INTO tracks
                    (path, title, artist, album, duration_secs, track_num, added_at, file_mtime, file_size)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                ON CONFLICT(path) DO UPDATE SET
                    title         = excluded.title,
                    artist        = excluded.artist,
                    album         = excluded.album,
                    duration_secs = excluded.duration_secs,
                    track_num     = excluded.track_num,
                    file_mtime    = excluded.file_mtime,
                    file_size     = excluded.file_size
                "#,
            )?;
            for item in items {
                let t = &item.track;
                twin.execute(params![t.path])?;
                stmt.execute(params![
                    t.path,
                    t.title,
                    t.artist.as_deref().unwrap_or(""),
                    t.album.as_deref().unwrap_or(""),
                    t.duration_secs,
                    t.track_num.unwrap_or(0),
                    t.added_at,
                    item.mtime_ns,
                    item.size
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

/// 清理已不存在的文件记录，返回删除数。
///
/// 磁盘检查在锁外完成，避免网络盘/大曲库把其它查询一起卡住；删除在单事务里。
pub fn prune_missing_tracks() -> anyhow::Result<i32> {
    let rows: Vec<(i64, String)> = with_conn(|conn| {
        let mut stmt = conn.prepare_cached("SELECT id, path FROM tracks")?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;

    let missing: Vec<i64> = rows
        .into_iter()
        .filter(|(_, path)| !Path::new(path).exists())
        .map(|(id, _)| id)
        .collect();

    delete_tracks(&missing)
}

/// 清理某个目录下「本次扫描没看到」的记录（文件被删除/移走），返回删除数。
///
/// 比较基于 [`path_key`] 归一化后的 key：Windows 下库里的历史路径与本次扫描
/// 传入的目录只在大小写/斜杠上不同时，也要能清到，且边界要用分隔符挡住
/// 「`E:\Music` 误匹配 `E:\Music2`」这种情况。
pub(crate) fn prune_tracks_under(folder: &Path, seen: &HashSet<String>) -> anyhow::Result<i32> {
    // 末尾的分隔符去掉，避免拼出「..\..\」导致前缀比对永远失配
    let folder_key = path_key(&folder.to_string_lossy());
    let folder_key = folder_key.trim_end_matches(['\\', '/']);
    let prefix = format!("{folder_key}\\");

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

    delete_tracks(&stale)
}

fn delete_tracks(ids: &[i64]) -> anyhow::Result<i32> {
    if ids.is_empty() {
        return Ok(0);
    }

    with_conn(|conn| {
        let tx = conn.transaction()?;
        let deleted = {
            let mut stmt = tx.prepare_cached("DELETE FROM tracks WHERE id = ?1")?;
            let mut count = 0;
            for id in ids {
                count += stmt.execute([id])?;
            }
            count
        };
        tx.commit()?;
        Ok(deleted as i32)
    })
}

fn row_to_track(row: &Row) -> rusqlite::Result<Track> {
    Ok(Track {
        path: row.get(0)?,
        title: row.get(1)?,
        artist: some_if_not_empty(row.get::<_, String>(2)?),
        album: some_if_not_empty(row.get::<_, String>(3)?),
        duration_secs: row.get(4)?,
        track_num: Some(row.get::<_, i32>(5)?).filter(|n| *n > 0),
        added_at: row.get(6)?,
    })
}

fn some_if_not_empty(s: String) -> Option<String> {
    (!s.is_empty()).then_some(s)
}

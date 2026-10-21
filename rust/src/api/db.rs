//! 曲库持久化：SQLite + FTS5 全文检索

use crate::api::model::Track;
use once_cell::sync::OnceCell;
use rusqlite::{params, Connection, Row};
use std::sync::{Mutex, MutexGuard};

static DB: OnceCell<Mutex<Connection>> = OnceCell::new();

/// 取全局连接（所有 db 函数唯一的入口）。
///
/// 未初始化或锁中毒都转成普通错误返回，避免在库代码里 panic。
fn conn() -> anyhow::Result<MutexGuard<'static, Connection>> {
    let db = DB
        .get()
        .ok_or_else(|| anyhow::anyhow!("曲库未初始化：请先调用 init_db(path)"))?;
    db.lock()
        .map_err(|_| anyhow::anyhow!("曲库连接锁已中毒（此前有线程 panic）"))
}

/// 初始化数据库（建表 + FTS5 虚表 + 同步触发器）
pub fn init_db(path: String) -> anyhow::Result<()> {
    let conn = Connection::open(&path)?;

    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;

        CREATE TABLE IF NOT EXISTS tracks (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            path          TEXT    NOT NULL UNIQUE,
            title         TEXT    NOT NULL DEFAULT '',
            artist        TEXT    NOT NULL DEFAULT '',
            album         TEXT    NOT NULL DEFAULT '',
            duration_secs REAL    NOT NULL DEFAULT 0,
            track_num     INTEGER NOT NULL DEFAULT 0,
            added_at      INTEGER NOT NULL DEFAULT 0
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
        "#,
    )?;

    // 设置 _DB；若重复初始化则直接复用已有连接
    let _ = DB.set(Mutex::new(conn));
    Ok(())
}

/// FTS5 全文检索
pub fn search_tracks(query: String, limit: i32) -> anyhow::Result<Vec<Track>> {
    // 传入的用户词按"前缀匹配"处理：huo => huo*
    let q = format!("{}*", query.replace('"', "\"\"").trim());
    let sql = format!(
        r#"
        SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at
        FROM tracks t
        JOIN tracks_fts f ON f.rowid = t.id
        WHERE tracks_fts = ?1
        LIMIT {}
        "#,
        limit.clamp(1, 2000)
    );

    let conn = conn()?;
    let mut stmt = conn.prepare_cached(&sql)?;
    let rows = stmt.query_map([&q], row_to_track)?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// 全量曲库（按歌手、专辑、曲号排序）
pub fn all_tracks() -> anyhow::Result<Vec<Track>> {
    let conn = conn()?;
    let mut stmt = conn.prepare_cached(
        r#"
        SELECT path, title, artist, album, duration_secs, track_num, added_at
        FROM tracks
        ORDER BY artist, album, track_num, title
        "#,
    )?;
    let rows = stmt.query_map([], row_to_track)?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// 批量写入/更新（按 path 去重），整个批次在一个事务里完成
pub fn upsert_tracks(tracks: Vec<Track>) -> anyhow::Result<i32> {
    let conn = conn()?;
    conn.execute("BEGIN IMMEDIATE", [])?;
    let inserted = (|| -> anyhow::Result<()> {
        let mut stmt = conn.prepare_cached(
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
        Ok(())
    })();

    match inserted {
        Ok(()) => {
            conn.execute("COMMIT", [])?;
            Ok(tracks.len() as i32)
        }
        Err(err) => {
            // 失败时回滚，避免半批数据落库
            let _ = conn.execute("ROLLBACK", []);
            Err(err)
        }
    }
}

/// 清理已不存在的文件记录，返回删除数
pub fn prune_missing_tracks() -> anyhow::Result<i32> {
    let conn = conn()?;
    let mut stmt = conn.prepare_cached("SELECT id, path FROM tracks")?;
    let missing: Vec<i64> = stmt
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|(_, p)| !std::path::Path::new(p).exists())
        .map(|(id, _)| id)
        .collect();
    drop(stmt);
    let mut deleted = 0;
    {
        let mut stmt = conn.prepare_cached("DELETE FROM tracks WHERE id = ?1")?;
        for id in missing {
            deleted += stmt.execute([id])?;
        }
    }
    Ok(deleted as i32)
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

/// 确认 bundled SQLite 带 FTS5
#[cfg(test)]
mod tests {
    // 单元测试见 tests/fts5.rs
}

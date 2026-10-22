//! 歌单 / 收藏 / 播放历史（schema v2）。
//!
//! 三张表都通过 `track_path` 外键关联 `tracks(path)`，删除曲目时级联清理，
//! 不会留下指向已清理文件的悬空条目。
//!
//! 语义要点：
//! - 歌单名去掉首尾空白后不能为空，忽略 ASCII 大小写唯一；
//! - 歌单内曲目按加入时间排序，暂不支持手动排序；
//! - 收藏 / 加歌单是幂等操作，重复调用不报错，返回值表示是否真的改变了数据；
//! - 历史按曲目去重，重复播放只更新最近时间并累加 `play_count`。

use crate::api::db::{row_to_track, with_conn};
use crate::api::model::{Playlist, Track};
use anyhow::{bail, Context};
use rusqlite::{params, Connection, OptionalExtension, Row};
use std::time::{SystemTime, UNIX_EPOCH};

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

const PLAYLIST_SELECT: &str = r#"
    SELECT p.id,
           p.name,
           (SELECT COUNT(*) FROM playlist_items i WHERE i.playlist_id = p.id),
           p.created_at,
           p.updated_at
    FROM playlists p
"#;

fn row_to_playlist(row: &Row<'_>) -> rusqlite::Result<Playlist> {
    Ok(Playlist {
        id: row.get(0)?,
        name: row.get(1)?,
        track_count: row.get(2)?,
        created_at: row.get(3)?,
        updated_at: row.get(4)?,
    })
}

fn playlist_by_id(conn: &Connection, id: i64) -> anyhow::Result<Playlist> {
    conn.query_row(
        &format!("{PLAYLIST_SELECT} WHERE p.id = ?1"),
        [id],
        row_to_playlist,
    )
    .optional()?
    .ok_or_else(|| anyhow::anyhow!("歌单不存在: {id}"))
}

fn playlist_exists(conn: &Connection, id: i64) -> anyhow::Result<()> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM playlists WHERE id = ?1)",
        [id],
        |row| row.get(0),
    )?;
    if !exists {
        bail!("歌单不存在: {id}");
    }
    Ok(())
}

fn track_exists(conn: &Connection, path: &str) -> anyhow::Result<()> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM tracks WHERE path = ?1)",
        [path],
        |row| row.get(0),
    )?;
    if !exists {
        bail!("曲目不在曲库: {path}");
    }
    Ok(())
}

fn clean_name(name: &str) -> anyhow::Result<String> {
    let name = name.trim();
    if name.is_empty() {
        bail!("歌单名不能为空");
    }
    Ok(name.to_string())
}

/// 同名判定忽略 ASCII 大小写；`exclude_id` 用于重命名时排除自己。
fn name_taken(conn: &Connection, name: &str, exclude_id: Option<i64>) -> anyhow::Result<bool> {
    let taken: bool = conn.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM playlists
             WHERE name = ?1 COLLATE NOCASE
               AND (?2 IS NULL OR id <> ?2)
         )",
        params![name, exclude_id],
        |row| row.get(0),
    )?;
    Ok(taken)
}

// ---------------------------------------------------------------------------
// 歌单
// ---------------------------------------------------------------------------

/// 歌单列表，按名称排序，附带曲目数。
pub fn list_playlists() -> anyhow::Result<Vec<Playlist>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(&format!(
            "{PLAYLIST_SELECT} ORDER BY p.name COLLATE NOCASE, p.id"
        ))?;
        let rows = stmt.query_map([], row_to_playlist)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 新建歌单；名称去空白后不能为空，不能与已有歌单重名。
pub fn create_playlist(name: String) -> anyhow::Result<Playlist> {
    let name = clean_name(&name)?;
    with_conn(|conn| {
        if name_taken(conn, &name, None)? {
            bail!("已存在同名歌单: {name}");
        }
        let now = now_secs();
        conn.execute(
            "INSERT INTO playlists (name, created_at, updated_at) VALUES (?1, ?2, ?2)",
            params![name, now],
        )?;
        playlist_by_id(conn, conn.last_insert_rowid())
    })
}

/// 重命名歌单；同名判定与新建一致。
pub fn rename_playlist(id: i64, name: String) -> anyhow::Result<()> {
    let name = clean_name(&name)?;
    with_conn(|conn| {
        let tx = conn.transaction()?;
        playlist_exists(&tx, id)?;
        if name_taken(&tx, &name, Some(id))? {
            bail!("已存在同名歌单: {name}");
        }
        tx.execute(
            "UPDATE playlists SET name = ?1, updated_at = ?2 WHERE id = ?3",
            params![name, now_secs(), id],
        )?;
        tx.commit()?;
        Ok(())
    })
}

/// 删除歌单；歌单内条目由外键级联清理。
pub fn delete_playlist(id: i64) -> anyhow::Result<()> {
    with_conn(|conn| {
        let changed = conn.execute("DELETE FROM playlists WHERE id = ?1", [id])?;
        if changed == 0 {
            bail!("歌单不存在: {id}");
        }
        Ok(())
    })
}

/// 歌单内曲目，按加入时间排序。
pub fn playlist_tracks(id: i64) -> anyhow::Result<Vec<Track>> {
    with_conn(|conn| {
        playlist_exists(conn, id)?;
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at
            FROM playlist_items i
            JOIN tracks t ON t.path = i.track_path
            WHERE i.playlist_id = ?1
            ORDER BY i.added_at, i.rowid
            "#,
        )?;
        let rows = stmt.query_map([id], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 往歌单加曲目；已在歌单内时返回 `false`。
pub fn add_track_to_playlist(id: i64, path: String) -> anyhow::Result<bool> {
    with_conn(|conn| {
        let tx = conn.transaction()?;
        playlist_exists(&tx, id)?;
        track_exists(&tx, &path)?;
        let changed = tx.execute(
            "INSERT OR IGNORE INTO playlist_items (playlist_id, track_path, added_at)
             VALUES (?1, ?2, ?3)",
            params![id, path, now_secs()],
        )?;
        if changed > 0 {
            tx.execute(
                "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
                params![now_secs(), id],
            )?;
        }
        tx.commit()?;
        Ok(changed > 0)
    })
}

/// 从歌单移除曲目；本来就不在歌单内时返回 `false`。
pub fn remove_track_from_playlist(id: i64, path: String) -> anyhow::Result<bool> {
    with_conn(|conn| {
        let tx = conn.transaction()?;
        playlist_exists(&tx, id)?;
        let changed = tx.execute(
            "DELETE FROM playlist_items WHERE playlist_id = ?1 AND track_path = ?2",
            params![id, path],
        )?;
        if changed > 0 {
            tx.execute(
                "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
                params![now_secs(), id],
            )?;
        }
        tx.commit()?;
        Ok(changed > 0)
    })
}

// ---------------------------------------------------------------------------
// 收藏
// ---------------------------------------------------------------------------

/// 收藏的曲目，最近收藏的在前。
pub fn list_favorites() -> anyhow::Result<Vec<Track>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at
            FROM favorites f
            JOIN tracks t ON t.path = f.track_path
            ORDER BY f.added_at DESC, t.id
            "#,
        )?;
        let rows = stmt.query_map([], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 全部收藏路径。列表页一次性拉取，避免逐曲调 `is_favorite`。
pub fn favorite_paths() -> anyhow::Result<Vec<String>> {
    with_conn(|conn| {
        let mut stmt =
            conn.prepare_cached("SELECT track_path FROM favorites ORDER BY added_at DESC")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 单曲是否已收藏。
pub fn is_favorite(path: String) -> anyhow::Result<bool> {
    with_conn(|conn| {
        let favorite: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM favorites WHERE track_path = ?1)",
            [path],
            |row| row.get(0),
        )?;
        Ok(favorite)
    })
}

/// 设置收藏状态（幂等）；收藏时曲目必须在曲库中。
pub fn set_favorite(path: String, favorite: bool) -> anyhow::Result<()> {
    with_conn(|conn| {
        if favorite {
            track_exists(conn, &path)?;
            conn.execute(
                "INSERT OR IGNORE INTO favorites (track_path, added_at) VALUES (?1, ?2)",
                params![path, now_secs()],
            )?;
        } else {
            conn.execute("DELETE FROM favorites WHERE track_path = ?1", [path])?;
        }
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// 播放历史
// ---------------------------------------------------------------------------

/// 记录一次播放：同曲目只保留一行，更新时间并累加次数。
pub fn record_play(path: String) -> anyhow::Result<()> {
    with_conn(|conn| {
        track_exists(conn, &path)?;
        conn.execute(
            r#"
            INSERT INTO play_history (track_path, last_played_at, play_count)
            VALUES (?1, ?2, 1)
            ON CONFLICT(track_path) DO UPDATE SET
                last_played_at = excluded.last_played_at,
                play_count     = play_history.play_count + 1
            "#,
            params![path, now_secs()],
        )?;
        Ok(())
    })
}

/// 最近播放的曲目（按曲目去重），`limit` 截断到 `1..=500`。
pub fn recent_tracks(limit: i32) -> anyhow::Result<Vec<Track>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at
            FROM play_history h
            JOIN tracks t ON t.path = h.track_path
            ORDER BY h.last_played_at DESC, t.id
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map([limit.clamp(1, 500)], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 清空播放历史。
pub fn clear_history() -> anyhow::Result<()> {
    with_conn(|conn| {
        conn.execute("DELETE FROM play_history", [])
            .context("清空播放历史失败")?;
        Ok(())
    })
}

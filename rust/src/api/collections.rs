//! 歌单 / 收藏 / 播放历史（schema v2）。
//!
//! 三张表都通过 `track_path` 外键关联 `tracks(path)`，删除曲目时级联清理，
//! 不会留下指向已清理文件的悬空条目。
//!
//! 语义要点：
//! - 歌单名去掉首尾空白后不能为空，忽略 ASCII 大小写唯一；
//! - 歌单内曲目按 `position` 排序（schema v6），拖拽后整体归一化成 0..n-1；
//! - 收藏 / 加歌单是幂等操作，重复调用不报错，返回值表示是否真的改变了数据；
//! - 历史按曲目去重，重复播放只更新最近时间并累加 `play_count`。

use crate::api::db::{row_to_track, with_conn};
use crate::api::model::{DailyPlaytime, PlayStats, Playlist, Track, TrackPlayStat};
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

/// 歌单内曲目，按用户排好的 `position` 排序。
pub fn playlist_tracks(id: i64) -> anyhow::Result<Vec<Track>> {
    with_conn(|conn| {
        playlist_exists(conn, id)?;
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at, t.cover_path, t.replay_gain
            FROM playlist_items i
            JOIN tracks t ON t.path = i.track_path
            WHERE i.playlist_id = ?1
            ORDER BY i.position, i.added_at, i.rowid
            "#,
        )?;
        let rows = stmt.query_map([id], row_to_track)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 把歌单里第 `from` 个曲目挪到第 `to` 个位置（下标按当前展示顺序）。
///
/// 重排后把 position 归一化成 `0..n-1`：反复拖拽不会留下空洞，也不用担心
/// 并发（单连接串行）产生的重号。
pub fn move_playlist_track(id: i64, from: i32, to: i32) -> anyhow::Result<()> {
    with_conn(|conn| {
        let tx = conn.transaction()?;
        playlist_exists(&tx, id)?;
        let mut paths: Vec<String> = {
            let mut stmt = tx.prepare_cached(
                "SELECT track_path FROM playlist_items
                 WHERE playlist_id = ?1
                 ORDER BY position, added_at, rowid",
            )?;
            let rows = stmt.query_map([id], |row| row.get(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        let len = paths.len();
        let from = from.max(0) as usize;
        if from >= len {
            bail!("下标越界: {from} / {len}");
        }
        let to = (to.max(0) as usize).min(len - 1);
        if from == to {
            return Ok(());
        }
        let moved = paths.remove(from);
        paths.insert(to, moved);
        {
            let mut stmt = tx.prepare_cached(
                "UPDATE playlist_items SET position = ?1
                 WHERE playlist_id = ?2 AND track_path = ?3",
            )?;
            for (index, path) in paths.iter().enumerate() {
                stmt.execute(params![index as i64, id, path])?;
            }
        }
        tx.execute(
            "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
            params![now_secs(), id],
        )?;
        tx.commit()?;
        Ok(())
    })
}

/// 往歌单加曲目；已在歌单内时返回 `false`。
pub fn add_track_to_playlist(id: i64, path: String) -> anyhow::Result<bool> {
    with_conn(|conn| {
        let tx = conn.transaction()?;
        playlist_exists(&tx, id)?;
        track_exists(&tx, &path)?;
        let changed = tx.execute(
            "INSERT OR IGNORE INTO playlist_items
                 (playlist_id, track_path, added_at, position)
             VALUES (?1, ?2, ?3, (
                 SELECT COALESCE(MAX(position), -1) + 1
                   FROM playlist_items WHERE playlist_id = ?1
             ))",
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

/// 批量加入歌单，返回真正新增的条数。
///
/// 整个批次在一个事务里：任一曲目不在曲库时整体回滚，不会留下半批数据。
/// 已在歌单内的曲目会被忽略，不计入返回值。
pub fn add_tracks_to_playlist(id: i64, paths: Vec<String>) -> anyhow::Result<i32> {
    if paths.is_empty() {
        return Ok(0);
    }
    with_conn(|conn| {
        let tx = conn.transaction()?;
        playlist_exists(&tx, id)?;
        let now = now_secs();
        let mut added = 0;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT OR IGNORE INTO playlist_items
                     (playlist_id, track_path, added_at, position)
                 VALUES (?1, ?2, ?3, (
                     SELECT COALESCE(MAX(position), -1) + 1
                       FROM playlist_items WHERE playlist_id = ?1
                 ))",
            )?;
            for path in &paths {
                track_exists(&tx, path)?;
                added += stmt.execute(params![id, path, now])?;
            }
        }
        if added > 0 {
            tx.execute(
                "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
                params![now, id],
            )?;
        }
        tx.commit()?;
        Ok(added as i32)
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
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at, t.cover_path, t.replay_gain
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

/// 批量设置收藏状态，返回真正改变的条数。
///
/// 收藏时任一曲目不在曲库会整体回滚；取消收藏不校验曲目是否存在（删库后
/// 的残留路径也能清掉）。重复路径会被幂等忽略。
pub fn set_favorites(paths: Vec<String>, favorite: bool) -> anyhow::Result<i32> {
    if paths.is_empty() {
        return Ok(0);
    }
    with_conn(|conn| {
        let tx = conn.transaction()?;
        let now = now_secs();
        let mut changed = 0;
        if favorite {
            let mut stmt = tx.prepare_cached(
                "INSERT OR IGNORE INTO favorites (track_path, added_at) VALUES (?1, ?2)",
            )?;
            for path in &paths {
                track_exists(&tx, path)?;
                changed += stmt.execute(params![path, now])?;
            }
        } else {
            let mut stmt = tx.prepare_cached("DELETE FROM favorites WHERE track_path = ?1")?;
            for path in &paths {
                changed += stmt.execute([path])?;
            }
        }
        tx.commit()?;
        Ok(changed as i32)
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
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at, t.cover_path, t.replay_gain
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

// ---------------------------------------------------------------------------
// 听歌时长统计（schema v4）
// ---------------------------------------------------------------------------

/// 累加某首歌在 `day` 这一天的播放秒数。
///
/// `day` 由前端按本地时区算好（`yyyyMMdd` 整数），Rust 侧不做时区推断——
/// 后台线程没有可靠的本地时区信息，交给 Dart 的 `DateTime.now()` 更准。
/// `seconds <= 0` 直接忽略，避免暂停瞬间上报 0 秒写坏聚合行。
pub fn record_play_time(path: String, day: i32, seconds: i64) -> anyhow::Result<()> {
    if seconds <= 0 {
        return Ok(());
    }
    with_conn(|conn| {
        track_exists(conn, &path)?;
        conn.execute(
            r#"
            INSERT INTO play_sessions (track_path, day, seconds)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(track_path, day) DO UPDATE SET
                seconds = play_sessions.seconds + excluded.seconds
            "#,
            params![path, day, seconds],
        )?;
        Ok(())
    })
}

/// 听歌总览：累计时长、累计次数、曲目数、活跃天数。
pub fn play_stats() -> anyhow::Result<PlayStats> {
    with_conn(|conn| {
        let total_seconds: i64 = conn.query_row(
            "SELECT COALESCE(SUM(seconds), 0) FROM play_sessions",
            [],
            |row| row.get(0),
        )?;
        let total_plays: i64 = conn.query_row(
            "SELECT COALESCE(SUM(play_count), 0) FROM play_history",
            [],
            |row| row.get(0),
        )?;
        let track_count: i64 =
            conn.query_row("SELECT COUNT(*) FROM play_history", [], |row| row.get(0))?;
        let active_days: i64 = conn.query_row(
            "SELECT COUNT(DISTINCT day) FROM play_sessions WHERE seconds > 0",
            [],
            |row| row.get(0),
        )?;
        Ok(PlayStats {
            total_seconds,
            total_plays,
            track_count,
            active_days,
        })
    })
}

/// 播放次数排行，`limit` 截断到 `1..=100`；次数相同按最近播放时间排。
pub fn top_tracks(limit: i32) -> anyhow::Result<Vec<TrackPlayStat>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT t.path, t.title, t.artist, t.album, t.duration_secs, t.track_num, t.added_at, t.cover_path, t.replay_gain,
                   h.play_count
            FROM play_history h
            JOIN tracks t ON t.path = h.track_path
            WHERE h.play_count > 0
            ORDER BY h.play_count DESC, h.last_played_at DESC, t.id
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map([limit.clamp(1, 100)], |row| {
            Ok(TrackPlayStat {
                track: row_to_track(row)?,
                plays: row.get(9)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

/// 自 `since_day` 起每天的播放时长，只返回有记录的天。
///
/// 不做「补齐空白天」——补零是展示层的事，Rust 只吐真实数据。
pub fn daily_playtime(since_day: i32) -> anyhow::Result<Vec<DailyPlaytime>> {
    with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT day, SUM(seconds)
            FROM play_sessions
            WHERE day >= ?1
            GROUP BY day
            ORDER BY day
            "#,
        )?;
        let rows = stmt.query_map([since_day], |row| {
            Ok(DailyPlaytime {
                day: row.get(0)?,
                seconds: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}

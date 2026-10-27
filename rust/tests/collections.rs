//! 歌单 / 收藏 / 播放历史存储接口测试。
//!
//! 曲库连接是进程内单例，所有用例用 `DB_LOCK` 串行执行，每个用例一个临时库。

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rust_lib_lamp_player::api::model::Track;
use rust_lib_lamp_player::api::{collections, db, scan};

static DB_LOCK: Mutex<()> = Mutex::new(());

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "lamp_collections_{}_{}_{}",
            tag,
            std::process::id(),
            nanos
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("创建临时目录");
        Self(dir)
    }

    fn db_path(&self) -> String {
        self.0.join("library.db").to_string_lossy().into_owned()
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        // 先关连接再删文件，否则 Windows 上文件被占用删不掉
        let _ = db::close_db();
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn begin(tag: &str) -> (MutexGuard<'static, ()>, TempDir) {
    let guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let _ = db::close_db();
    (guard, TempDir::new(tag))
}

fn track(path: &str, title: &str) -> Track {
    Track {
        path: path.to_string(),
        title: title.to_string(),
        artist: Some("测试歌手".to_string()),
        album: Some("测试专辑".to_string()),
        duration_secs: 1.5,
        track_num: None,
        added_at: 1,
        cover_path: None,
        replay_gain: 0.0,
    }
}

fn seed(dir: &TempDir, items: &[(&str, &str)]) {
    db::init_db(dir.db_path()).expect("初始化曲库");
    let tracks: Vec<Track> = items
        .iter()
        .map(|(path, title)| track(path, title))
        .collect();
    db::upsert_tracks(tracks).expect("写入曲目");
}

#[test]
fn playlist_crud_and_item_lifecycle() {
    let (_lock, dir) = begin("pl");
    seed(
        &dir,
        &[
            ("/music/a.mp3", "A"),
            ("/music/b.mp3", "B"),
            ("/music/c.mp3", "C"),
        ],
    );

    let playlist = collections::create_playlist("  Night Drive  ".to_string()).expect("新建歌单");
    assert_eq!(playlist.name, "Night Drive", "名称应去掉首尾空白");
    assert_eq!(playlist.track_count, 0);
    assert!(playlist.created_at > 0);

    let err = collections::create_playlist("night drive".to_string())
        .expect_err("大小写不同也算重名")
        .to_string();
    assert!(err.contains("同名"), "错误信息应说明重名: {err}");
    assert!(collections::create_playlist("   ".to_string()).is_err());

    assert!(
        collections::add_track_to_playlist(playlist.id, "/music/b.mp3".to_string()).expect("加 B")
    );
    assert!(
        !collections::add_track_to_playlist(playlist.id, "/music/b.mp3".to_string())
            .expect("重复加不报错"),
        "重复加应返回 false"
    );
    assert!(
        collections::add_track_to_playlist(playlist.id, "/music/a.mp3".to_string()).expect("加 A")
    );
    assert!(
        collections::add_track_to_playlist(playlist.id, "/music/missing.mp3".to_string()).is_err(),
        "曲目不在曲库时应报错"
    );

    let playlists = collections::list_playlists().expect("歌单列表");
    assert_eq!(playlists.len(), 1);
    assert_eq!(playlists[0].track_count, 2);

    let items = collections::playlist_tracks(playlist.id).expect("歌单曲目");
    assert_eq!(
        items.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(),
        vec!["B", "A"],
        "按加入顺序排列"
    );

    collections::rename_playlist(playlist.id, "Late Night".to_string()).expect("重命名");
    assert_eq!(
        collections::list_playlists().expect("歌单列表")[0].name,
        "Late Night"
    );

    let other = collections::create_playlist("Other".to_string()).expect("再建一个");
    assert!(
        collections::rename_playlist(other.id, "late night".to_string()).is_err(),
        "重命名也要拦重名"
    );

    assert!(
        collections::remove_track_from_playlist(playlist.id, "/music/b.mp3".to_string())
            .expect("移除")
    );
    assert!(
        !collections::remove_track_from_playlist(playlist.id, "/music/b.mp3".to_string())
            .expect("重复移除不报错"),
        "重复移除应返回 false"
    );
    assert_eq!(
        collections::playlist_tracks(playlist.id)
            .expect("歌单曲目")
            .len(),
        1
    );

    collections::delete_playlist(playlist.id).expect("删除歌单");
    assert_eq!(collections::list_playlists().expect("歌单列表").len(), 1);
    assert!(
        collections::playlist_tracks(playlist.id).is_err(),
        "删除后查曲目应报错"
    );
    assert!(collections::rename_playlist(playlist.id, "x".to_string()).is_err());
    assert!(collections::delete_playlist(playlist.id).is_err());
}

#[test]
fn favorites_are_idempotent_and_listed() {
    let (_lock, dir) = begin("fav");
    seed(&dir, &[("/music/a.mp3", "A"), ("/music/b.mp3", "B")]);

    collections::set_favorite("/music/a.mp3".to_string(), true).expect("收藏");
    collections::set_favorite("/music/a.mp3".to_string(), true).expect("重复收藏不报错");

    assert!(collections::is_favorite("/music/a.mp3".to_string()).expect("查询收藏"));
    assert!(!collections::is_favorite("/music/b.mp3".to_string()).expect("查询收藏"));
    assert_eq!(
        collections::favorite_paths().expect("收藏路径"),
        vec!["/music/a.mp3".to_string()]
    );
    let favorites = collections::list_favorites().expect("收藏列表");
    assert_eq!(favorites.len(), 1);
    assert_eq!(favorites[0].title, "A");

    collections::set_favorite("/music/a.mp3".to_string(), false).expect("取消收藏");
    assert!(!collections::is_favorite("/music/a.mp3".to_string()).expect("查询收藏"));
    assert!(collections::favorite_paths().expect("收藏路径").is_empty());

    assert!(
        collections::set_favorite("/music/missing.mp3".to_string(), true).is_err(),
        "不在曲库的曲目不能收藏"
    );
}

#[test]
fn batch_favorites_and_playlist_add_are_atomic() {
    let (_lock, dir) = begin("batch");
    seed(
        &dir,
        &[
            ("/music/a.mp3", "A"),
            ("/music/b.mp3", "B"),
            ("/music/c.mp3", "C"),
        ],
    );

    assert_eq!(
        collections::set_favorites(
            vec!["/music/a.mp3".to_string(), "/music/b.mp3".to_string()],
            true
        )
        .expect("批量收藏"),
        2
    );
    assert_eq!(
        collections::set_favorites(
            vec!["/music/a.mp3".to_string(), "/music/b.mp3".to_string()],
            true
        )
        .expect("重复收藏"),
        0,
        "已经收藏过的曲目不应重复计数"
    );

    // 批量里混入不存在的曲目：整批回滚，C 不能被收藏
    assert!(collections::set_favorites(
        vec!["/music/c.mp3".to_string(), "/music/missing.mp3".to_string()],
        true
    )
    .is_err());
    assert!(!collections::is_favorite("/music/c.mp3".to_string()).expect("查询收藏"));

    assert_eq!(
        collections::set_favorites(
            vec!["/music/a.mp3".to_string(), "/music/b.mp3".to_string()],
            false
        )
        .expect("批量取消收藏"),
        2
    );
    assert!(collections::favorite_paths().expect("收藏路径").is_empty());

    let playlist = collections::create_playlist("Batch".to_string()).expect("新建歌单");
    assert_eq!(
        collections::add_tracks_to_playlist(
            playlist.id,
            vec![
                "/music/a.mp3".to_string(),
                "/music/b.mp3".to_string(),
                "/music/a.mp3".to_string(),
            ],
        )
        .expect("批量加入歌单"),
        2,
        "重复路径只算一次"
    );
    assert!(
        collections::add_tracks_to_playlist(
            playlist.id,
            vec!["/music/c.mp3".to_string(), "/music/missing.mp3".to_string(),],
        )
        .is_err(),
        "任一曲目不在曲库时应整批回滚"
    );
    assert_eq!(
        collections::playlist_tracks(playlist.id)
            .expect("歌单曲目")
            .len(),
        2,
        "失败的批次不能留下半批数据"
    );
}

#[test]
fn remove_tracks_deletes_by_path_and_cascades() {
    let (_lock, dir) = begin("remove");
    seed(
        &dir,
        &[
            ("/music/a.mp3", "A"),
            ("/music/b.mp3", "B"),
            ("/music/c.mp3", "C"),
        ],
    );
    let playlist = collections::create_playlist("Remove".to_string()).expect("新建歌单");
    collections::add_track_to_playlist(playlist.id, "/music/a.mp3".to_string()).expect("加入歌单");
    collections::set_favorite("/music/a.mp3".to_string(), true).expect("收藏");

    assert_eq!(
        db::remove_tracks(vec![
            "/music/a.mp3".to_string(),
            "/music/missing.mp3".to_string(),
            "/music/a.mp3".to_string(),
        ])
        .expect("批量移除"),
        1,
        "不存在的路径与重复路径应被忽略"
    );
    assert_eq!(db::all_tracks().expect("读取曲库").len(), 2);
    assert!(collections::playlist_tracks(playlist.id)
        .expect("歌单曲目")
        .is_empty());
    assert!(collections::favorite_paths().expect("收藏路径").is_empty());

    assert_eq!(db::remove_tracks(Vec::new()).expect("空批次"), 0);
}

#[test]
fn history_dedupes_plays_and_sorts_by_recent() {
    let (_lock, dir) = begin("history");
    seed(
        &dir,
        &[
            ("/music/a.mp3", "A"),
            ("/music/b.mp3", "B"),
            ("/music/c.mp3", "C"),
        ],
    );

    collections::record_play("/music/a.mp3".to_string()).expect("记录 A");
    collections::record_play("/music/b.mp3".to_string()).expect("记录 B");
    // last_played_at 精度是秒，睡一下才能验证「最近播放」的排序
    std::thread::sleep(Duration::from_millis(1_100));
    collections::record_play("/music/a.mp3".to_string()).expect("再记录 A");

    let recent = collections::recent_tracks(10).expect("最近播放");
    assert_eq!(
        recent.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(),
        vec!["A", "B"],
        "按曲目去重，最近播放的在前"
    );

    let limited = collections::recent_tracks(0).expect("limit 截断");
    assert_eq!(limited.len(), 1, "limit 最小按 1 处理");
    assert_eq!(limited[0].title, "A");

    assert!(
        collections::record_play("/music/missing.mp3".to_string()).is_err(),
        "不在曲库的曲目不能记历史"
    );

    collections::clear_history().expect("清空历史");
    assert!(collections::recent_tracks(10).expect("最近播放").is_empty());
}

#[test]
fn play_time_accumulates_per_day_and_ranks_tracks() {
    let (_lock, dir) = begin("playtime");
    seed(&dir, &[("/music/a.mp3", "A"), ("/music/b.mp3", "B")]);

    // 同一天多次上报要累加，跨天要分行
    collections::record_play_time("/music/a.mp3".to_string(), 20261026, 30).expect("上报 A");
    collections::record_play_time("/music/a.mp3".to_string(), 20261026, 45).expect("再上报 A");
    collections::record_play_time("/music/a.mp3".to_string(), 20261027, 60).expect("跨天 A");
    collections::record_play_time("/music/b.mp3".to_string(), 20261026, 10).expect("上报 B");
    // 0 秒不写库，避免暂停瞬间把聚合行写坏
    collections::record_play_time("/music/b.mp3".to_string(), 20261026, 0).expect("零秒忽略");

    let daily = collections::daily_playtime(20261001).expect("每日时长");
    assert_eq!(
        daily
            .iter()
            .map(|item| (item.day, item.seconds))
            .collect::<Vec<_>>(),
        vec![(20261026, 85), (20261027, 60)],
        "按天聚合，同曲同日累加"
    );

    let ranged = collections::daily_playtime(20261027).expect("范围过滤");
    assert_eq!(ranged.len(), 1, "只返回起始日期之后的天");
    assert_eq!(ranged[0].day, 20261027);

    let stats = collections::play_stats().expect("总览");
    assert_eq!(stats.total_seconds, 145);
    assert_eq!(stats.active_days, 2);
    assert_eq!(stats.total_plays, 0, "只上报时长时还没有播放次数");

    collections::record_play("/music/b.mp3".to_string()).expect("B 播一次");
    collections::record_play("/music/b.mp3".to_string()).expect("B 再播一次");
    collections::record_play("/music/a.mp3".to_string()).expect("A 播一次");

    let top = collections::top_tracks(100).expect("排行");
    assert_eq!(top[0].track.title, "B");
    assert_eq!(top[0].plays, 2, "次数多的排前面");
    assert_eq!(top[1].track.title, "A");
    assert_eq!(top[1].plays, 1);

    let capped = collections::top_tracks(0).expect("limit 截断");
    assert_eq!(capped.len(), 1, "limit 最小按 1 处理");

    assert!(
        collections::record_play_time("/music/missing.mp3".to_string(), 20261026, 10).is_err(),
        "不在曲库的曲目不能记时长"
    );
}

#[test]
fn deleting_track_cascades_playlist_favorites_and_history() {
    let (_lock, dir) = begin("cascade");
    let music = dir.0.join("music");
    write_wav(&music.join("song.wav"), 0.5);

    db::init_db(dir.db_path()).expect("初始化曲库");
    let report = scan::scan_folder(music.to_string_lossy().into_owned()).expect("扫描");
    assert_eq!(report.upserted, 1);

    let track = db::all_tracks().expect("读取曲库").remove(0);
    let playlist = collections::create_playlist("Cascade".to_string()).expect("新建歌单");
    collections::add_track_to_playlist(playlist.id, track.path.clone()).expect("加入歌单");
    collections::set_favorite(track.path.clone(), true).expect("收藏");
    collections::record_play(track.path.clone()).expect("记历史");

    fs::remove_file(music.join("song.wav")).expect("删除音频");
    let after = scan::scan_folder(music.to_string_lossy().into_owned()).expect("清理扫描");
    assert_eq!(after.pruned, 1, "曲目应被清理");

    assert!(collections::playlist_tracks(playlist.id)
        .expect("歌单曲目")
        .is_empty());
    assert!(collections::list_favorites().expect("收藏列表").is_empty());
    assert!(collections::recent_tracks(10).expect("最近播放").is_empty());
}

/// 生成一个 0.5 秒、8kHz、单声道 16bit 的静音 WAV（lofty 能解析时长，无标签）
fn write_wav(path: &Path, seconds: f32) {
    let sample_rate: u32 = 8_000;
    let channels: u16 = 1;
    let bits: u16 = 16;
    let block_align = channels * (bits / 8);
    let sample_count = (sample_rate as f32 * seconds) as u32;
    let data_len = sample_count * u32::from(block_align);

    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVE");
    bytes.extend_from_slice(b"fmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
    bytes.extend_from_slice(&channels.to_le_bytes());
    bytes.extend_from_slice(&sample_rate.to_le_bytes());
    bytes.extend_from_slice(&(sample_rate * u32::from(block_align)).to_le_bytes());
    bytes.extend_from_slice(&block_align.to_le_bytes());
    bytes.extend_from_slice(&bits.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    bytes.resize(44 + data_len as usize, 0);

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("创建测试目录");
    }
    fs::write(path, bytes).expect("写入 wav");
}

/// 拖拽重排：位置按 `from → to` 移动，并把 position 归一化成 0..n-1。
#[test]
fn playlist_move_reorders_and_normalizes_positions() {
    let (_lock, dir) = begin("pl_move");
    seed(
        &dir,
        &[
            ("/music/a.mp3", "A"),
            ("/music/b.mp3", "B"),
            ("/music/c.mp3", "C"),
            ("/music/d.mp3", "D"),
        ],
    );
    let playlist = collections::create_playlist("Order".to_string()).expect("新建歌单");
    for path in ["/music/a.mp3", "/music/b.mp3", "/music/c.mp3"] {
        collections::add_track_to_playlist(playlist.id, path.to_string()).expect("加曲目");
    }

    let titles = || -> Vec<String> {
        collections::playlist_tracks(playlist.id)
            .expect("歌单曲目")
            .into_iter()
            .map(|track| track.title)
            .collect()
    };
    assert_eq!(titles(), vec!["A", "B", "C"], "新加入的排在末尾");

    collections::move_playlist_track(playlist.id, 2, 0).expect("挪到最前");
    assert_eq!(titles(), vec!["C", "A", "B"]);

    // 越界的 to 夹到末尾，不会报错也不会丢条目
    collections::move_playlist_track(playlist.id, 0, 99).expect("挪到末尾");
    assert_eq!(titles(), vec!["A", "B", "C"]);

    assert!(
        collections::move_playlist_track(playlist.id, 9, 0).is_err(),
        "越界的 from 应报错"
    );

    // 重排后新加的曲目仍然追加在末尾
    collections::add_track_to_playlist(playlist.id, "/music/d.mp3".to_string()).expect("加 D");
    assert_eq!(titles(), vec!["A", "B", "C", "D"]);
}

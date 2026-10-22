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
        self.0.join("library.lampdb").to_string_lossy().into_owned()
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

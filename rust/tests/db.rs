//! 曲库链路测试：upsert 去重、FTS 触发器同步、搜索容错、prune、迁移与连接生命周期。
//!
//! 曲库连接是进程内单例，所以这里用 `DB_LOCK` 串行执行，每个用例用独立临时库。

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rust_lib_lamp_player::api::db;
use rust_lib_lamp_player::api::model::Track;

static DB_LOCK: Mutex<()> = Mutex::new(());

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir =
            std::env::temp_dir().join(format!("lamp_db_{}_{}_{}", tag, std::process::id(), nanos));
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

/// 拿到串行锁并确保没有遗留连接。
fn begin(tag: &str) -> (MutexGuard<'static, ()>, TempDir) {
    let guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let _ = db::close_db();
    (guard, TempDir::new(tag))
}

fn track(path: &str, title: &str, artist: Option<&str>, album: Option<&str>) -> Track {
    Track {
        path: path.to_string(),
        title: title.to_string(),
        artist: artist.map(str::to_string),
        album: album.map(str::to_string),
        duration_secs: 1.5,
        track_num: None,
        added_at: 1,
    }
}

#[test]
fn upsert_dedupes_by_path_and_keeps_fts_in_sync() {
    let (_lock, dir) = begin("dedupe");
    db::init_db(dir.db_path()).expect("初始化曲库");

    db::upsert_tracks(vec![track(
        "/music/a.mp3",
        "周杰伦",
        Some("Jay"),
        Some("专辑"),
    )])
    .expect("首次写入");

    assert_eq!(db::all_tracks().expect("读取曲库").len(), 1);
    assert_eq!(
        db::search_tracks("周杰".to_string(), 10)
            .expect("检索")
            .len(),
        1,
        "中文前缀应命中"
    );

    // 同 path 再写一次应更新而不是新增，旧索引必须被删除
    db::upsert_tracks(vec![track("/music/a.mp3", "新标题", Some("别人"), None)]).expect("更新写入");

    let all = db::all_tracks().expect("读取曲库");
    assert_eq!(all.len(), 1, "按 path 去重");
    assert_eq!(all[0].title, "新标题");
    assert_eq!(all[0].artist.as_deref(), Some("别人"));

    assert!(
        db::search_tracks("周杰".to_string(), 10)
            .expect("检索")
            .is_empty(),
        "更新后旧的 FTS 索引必须被触发器删除"
    );
    assert_eq!(
        db::search_tracks("新标题".to_string(), 10)
            .expect("检索")
            .len(),
        1
    );
}

#[test]
fn search_tolerates_fts_syntax_characters() {
    let (_lock, dir) = begin("fts");
    db::init_db(dir.db_path()).expect("初始化曲库");

    db::upsert_tracks(vec![
        track("/m/a-b.mp3", "a-b", None, None),
        track("/m/cpp.mp3", "c++", None, None),
        track("/m/dont.mp3", "Don't Stop", None, None),
        track("/m/cn.mp3", "本地音乐", Some("周杰伦"), None),
    ])
    .expect("写入曲库");

    // 这些输入以前会让 FTS5 语法报错
    for query in [
        "",
        "   ",
        "-",
        "*",
        "%",
        "_",
        "~",
        "(x)",
        "AND",
        "NOT",
        "a:b",
        "\"",
        "a*",
        "本地 音乐",
    ] {
        db::search_tracks(query.to_string(), 10)
            .unwrap_or_else(|err| panic!("查询 {query:?} 不应报错: {err}"));
    }

    assert!(
        db::search_tracks(String::new(), 10)
            .expect("空查询")
            .is_empty(),
        "空查询直接返回空列表"
    );
    assert_eq!(
        db::search_tracks("a-b".to_string(), 10)
            .expect("带连字符")
            .len(),
        1,
        "连字符应被当字面量"
    );
    assert_eq!(
        db::search_tracks("c++".to_string(), 10)
            .expect("带加号")
            .len(),
        1
    );
    assert_eq!(
        db::search_tracks("don't".to_string(), 10)
            .expect("带撇号")
            .len(),
        1
    );
    assert_eq!(
        db::search_tracks("周杰".to_string(), 10)
            .expect("中文前缀")
            .len(),
        1
    );

    // 前缀查询仍按 bm25 相关度排序：短标题更相关，排在前面
    db::upsert_tracks(vec![
        track("/m/hello.mp3", "hello", None, None),
        track("/m/hello-world.mp3", "hello world hello", None, None),
    ])
    .expect("写入曲库");
    let hits = db::search_tracks("hello".to_string(), 10).expect("检索");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].title, "hello", "应按 bm25 相关度排序");
}

/// Windows 文件系统不区分大小写：同一文件路径写成大小写不同的两份，
/// UPSERT 的冲突判定是区分大小写的，必须删掉孪生行，否则出现重复记录。
#[cfg(windows)]
#[test]
fn upsert_tracks_removes_case_variant_duplicates() {
    let (_lock, dir) = begin("twin");
    db::init_db(dir.db_path()).expect("初始化曲库");

    db::upsert_tracks(vec![track(
        "C:\\music\\a.mp3",
        "旧标题",
        Some("旧歌手"),
        None,
    )])
    .expect("首次写入");

    // 模拟同一文件以不同大小写路径进来（如老版本扫描留下的记录）
    db::upsert_tracks(vec![track("C:\\MUSIC\\a.mp3", "新标题", None, None)]).expect("孪生路径写入");

    let all = db::all_tracks().expect("读取曲库");
    assert_eq!(all.len(), 1, "大小写孪生行应被合并");
    assert_eq!(all[0].title, "新标题");
}

#[test]
fn prune_missing_tracks_only_removes_missing_files() {
    let (_lock, dir) = begin("prune");
    db::init_db(dir.db_path()).expect("初始化曲库");

    let kept = dir.0.join("kept.mp3");
    fs::write(&kept, b"x").expect("写入测试文件");
    let kept_path = kept.to_string_lossy().into_owned();
    let gone_path = dir.0.join("gone.mp3").to_string_lossy().into_owned();

    db::upsert_tracks(vec![
        track(&kept_path, "保留", None, None),
        track(&gone_path, "已删除", None, None),
    ])
    .expect("写入曲库");

    assert_eq!(db::prune_missing_tracks().expect("清理"), 1);
    let all = db::all_tracks().expect("读取曲库");
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].title, "保留");

    assert_eq!(db::prune_missing_tracks().expect("再次清理"), 0);
}

#[test]
fn init_db_rejects_path_switch_until_closed() {
    let (_lock, dir) = begin("switch");
    let first = dir.db_path();
    let second = dir.0.join("other.lampdb").to_string_lossy().into_owned();

    db::init_db(first.clone()).expect("初始化");
    db::init_db(first.clone()).expect("同路径重复初始化应幂等");
    assert!(
        db::init_db(second.clone()).is_err(),
        "换路径必须先 close_db"
    );

    db::close_db().expect("关闭");
    db::init_db(second).expect("关闭后可以切到新路径");
    assert!(db::all_tracks().expect("新库可读").is_empty());
}

#[test]
fn migrate_old_database_adds_columns_and_rebuilds_index() {
    let (_lock, dir) = begin("migrate");
    let path = dir.db_path();

    // 手工造一个 v1 之前的库：没有 file_mtime/file_size，也没有 FTS 触发器
    {
        let conn = rusqlite::Connection::open(&path).expect("打开旧库");
        conn.execute_batch(
            r#"
            CREATE TABLE tracks (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                path          TEXT    NOT NULL UNIQUE,
                title         TEXT    NOT NULL DEFAULT '',
                artist        TEXT    NOT NULL DEFAULT '',
                album         TEXT    NOT NULL DEFAULT '',
                duration_secs REAL    NOT NULL DEFAULT 0,
                track_num     INTEGER NOT NULL DEFAULT 0,
                added_at      INTEGER NOT NULL DEFAULT 0
            );
            CREATE VIRTUAL TABLE tracks_fts USING fts5 (
                title, artist, album,
                content = 'tracks',
                content_rowid = 'id'
            );
            INSERT INTO tracks (path, title, artist, album)
            VALUES ('/old/a.mp3', '老歌手', '老歌手', '');
            "#,
        )
        .expect("建旧库");
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .expect("读取版本"),
            0
        );
    }

    db::init_db(path.clone()).expect("升级旧库");

    let conn = rusqlite::Connection::open(&path).expect("重新打开");
    let version: i32 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .expect("读取版本");
    assert_eq!(version, 1, "升级后应写入当前结构版本");

    let mut columns = Vec::new();
    {
        let mut stmt = conn.prepare("PRAGMA table_info(tracks)").expect("表结构");
        let mut rows = stmt.query([]).expect("查询表结构");
        while let Some(row) = rows.next().expect("遍历表结构") {
            columns.push(row.get::<_, String>(1).expect("列名"));
        }
    }
    assert!(columns.contains(&"file_mtime".to_string()));
    assert!(columns.contains(&"file_size".to_string()));
    drop(conn);

    // 触发器与索引在升级时补齐/重建，老数据也要能搜到
    assert_eq!(
        db::search_tracks("老歌手".to_string(), 10)
            .expect("检索")
            .len(),
        1,
        "升级后应重建 FTS 索引"
    );
}

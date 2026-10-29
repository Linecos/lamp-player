//! 曲库链路测试：upsert 去重、FTS 触发器同步、搜索容错、prune、迁移与连接生命周期。
//!
//! 曲库连接是进程内单例，所以这里用 `DB_LOCK` 串行执行，每个用例用独立临时库。

use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rust_lib_lamp_player::api::model::Track;
use rust_lib_lamp_player::api::{collections, db};

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
        cover_path: None,
        replay_gain: 0.0,
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

/// 整块盘「不可达」时不能把曲库删空：一次缺失超过一半就该拒绝，并保留记录。
#[test]
fn prune_refuses_when_most_tracks_are_missing() {
    let (_lock, dir) = begin("prune_guard");
    db::init_db(dir.db_path()).expect("初始化曲库");

    // 目录本身存在（盘根可达），只是里面的文件都不在
    let gone_dir = dir.0.join("gone");
    fs::create_dir_all(&gone_dir).expect("创建目录");
    let items: Vec<Track> = (0..10)
        .map(|index| {
            let path = gone_dir.join(format!("{index}.mp3"));
            track(&path.to_string_lossy(), "缺失", None, None)
        })
        .collect();
    db::upsert_tracks(items).expect("写入曲库");
    // 收藏一首，验证清理被拒时不会级联丢数据
    let first = gone_dir.join("0.mp3").to_string_lossy().into_owned();
    collections::set_favorite(first, true).expect("收藏");

    let error = db::prune_missing_tracks().expect_err("整库缺失时应拒绝清理");
    assert!(
        error.to_string().contains("疑似磁盘未挂载"),
        "错误信息应说明原因：{error}"
    );
    assert_eq!(
        db::all_tracks().expect("读取曲库").len(),
        10,
        "记录不应被删"
    );
    assert!(
        collections::favorite_paths()
            .expect("读取收藏")
            .iter()
            .any(|path| path.ends_with("0.mp3")),
        "收藏不应被级联清空"
    );
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
    let second = dir.0.join("other.db").to_string_lossy().into_owned();

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
    assert_eq!(version, 8, "升级后应写入当前结构版本");

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
    assert!(columns.contains(&"cover_path".to_string()));
    assert!(
        columns.contains(&"replay_gain".to_string()),
        "v5 应补上 ReplayGain 列"
    );
    assert!(
        columns.contains(&"hidden".to_string()) && columns.contains(&"hidden_at".to_string()),
        "v8 应补上隐藏标记两列"
    );
    drop(conn);

    // v2 新增的三张表也要在升级时建好
    assert!(collections::list_playlists()
        .expect("歌单表已建")
        .is_empty());
    assert!(collections::favorite_paths()
        .expect("收藏表已建")
        .is_empty());
    assert!(collections::recent_tracks(10)
        .expect("历史表已建")
        .is_empty());

    // v4 的听歌时长表
    assert_eq!(
        collections::play_stats().expect("时长表已建").total_seconds,
        0
    );
    assert!(collections::daily_playtime(0)
        .expect("时长表已建")
        .is_empty());

    // 触发器与索引在升级时补齐/重建，老数据也要能搜到
    assert_eq!(
        db::search_tracks("老歌手".to_string(), 10)
            .expect("检索")
            .len(),
        1,
        "升级后应重建 FTS 索引"
    );
}

#[test]
fn migrate_v2_resets_fingerprints_and_adds_cover_column() {
    let (_lock, dir) = begin("migrate_v3");
    let path = dir.db_path();

    // v2 的库：曲目表没有 cover_path，且已有 mtime/size 指纹
    {
        let conn = rusqlite::Connection::open(&path).expect("打开 v2 库");
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
                added_at      INTEGER NOT NULL DEFAULT 0,
                file_mtime    INTEGER NOT NULL DEFAULT 0,
                file_size     INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO tracks (path, title, added_at, file_mtime, file_size)
            VALUES ('/music/a.mp3', '旧歌', 1, 123, 456);
            PRAGMA user_version = 2;
            "#,
        )
        .expect("建 v2 库");
    }

    db::init_db(path.clone()).expect("升级 v2 库");

    let tracks = db::all_tracks().expect("读取曲库");
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].cover_path, None, "老库曲目默认没有封面");

    let conn = rusqlite::Connection::open(&path).expect("重新打开");
    let (mtime, size): (i64, i64) = conn
        .query_row(
            "SELECT file_mtime, file_size FROM tracks WHERE path = '/music/a.mp3'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("读取指纹");
    assert_eq!(
        (mtime, size),
        (0, 0),
        "应清零指纹，让下次扫描重新解析并补封面"
    );
}

/// v6：老库的歌单条目要按「加入时间 → 插入顺序」回填一次 position。
#[test]
fn migrate_v6_backfills_playlist_positions() {
    let (_lock, dir) = begin("migrate_v6");
    let path = dir.db_path();

    {
        let conn = rusqlite::Connection::open(&path).expect("打开 v5 库");
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
                added_at      INTEGER NOT NULL DEFAULT 0,
                file_mtime    INTEGER NOT NULL DEFAULT 0,
                file_size     INTEGER NOT NULL DEFAULT 0,
                cover_path    TEXT    NOT NULL DEFAULT '',
                replay_gain   REAL    NOT NULL DEFAULT 0
            );
            CREATE TABLE playlists (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT    NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE playlist_items (
                playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                track_path  TEXT    NOT NULL REFERENCES tracks(path) ON DELETE CASCADE,
                added_at    INTEGER NOT NULL,
                PRIMARY KEY (playlist_id, track_path)
            );
            INSERT INTO tracks (path, title) VALUES
                ('/music/a.mp3', 'A'), ('/music/b.mp3', 'B'), ('/music/c.mp3', 'C');
            INSERT INTO playlists (id, name, created_at, updated_at) VALUES (1, 'P', 1, 1);
            -- 插入顺序与加入时间故意不一致：回填应按 added_at 排
            INSERT INTO playlist_items (playlist_id, track_path, added_at) VALUES
                (1, '/music/a.mp3', 30),
                (1, '/music/b.mp3', 10),
                (1, '/music/c.mp3', 20);
            PRAGMA user_version = 5;
            "#,
        )
        .expect("建 v5 库");
    }

    db::init_db(path.clone()).expect("升级 v5 库");

    let conn = rusqlite::Connection::open(&path).expect("重新打开");
    let mut stmt = conn
        .prepare("SELECT track_path FROM playlist_items ORDER BY position")
        .expect("查询条目");
    let ordered: Vec<String> = stmt
        .query_map([], |row| row.get(0))
        .expect("遍历条目")
        .collect::<Result<Vec<_>, _>>()
        .expect("读取条目");
    assert_eq!(
        ordered,
        vec![
            "/music/b.mp3".to_string(),
            "/music/c.mp3".to_string(),
            "/music/a.mp3".to_string()
        ],
        "应按加入时间回填 position"
    );
}

/// 中文词中间的子串也要能搜到。
///
/// FTS5 的 unicode61 不切分 CJK：「林间电台」整条是一个 token，所以前缀查询
/// `"电台"*` 永远匹配不到。这里用 LIKE 子串兜底补上，顺带覆盖英文词中片段。
#[test]
fn search_finds_substring_inside_word() {
    let (_lock, dir) = begin("substring");
    db::init_db(dir.db_path()).expect("初始化曲库");

    db::upsert_tracks(vec![
        track("/music/a.mp3", "夜航", Some("林间电台"), Some("夜之专辑")),
        track("/music/b.mp3", "晴天", Some("周杰伦"), Some("叶惠美")),
    ])
    .expect("写入");

    let found = db::search_tracks("电台".to_string(), 10).expect("检索");
    assert_eq!(found.len(), 1, "「电台」应命中「林间电台」");
    assert_eq!(found[0].title, "夜航");

    assert_eq!(
        db::search_tracks("之专".to_string(), 10)
            .expect("检索")
            .len(),
        1,
        "专辑名中间的片段也要命中"
    );
    assert_eq!(
        db::search_tracks("航".to_string(), 10).expect("检索").len(),
        1,
        "单字也要能搜到"
    );

    // 英文词中间的片段（FTS 前缀同样匹配不到 midnight）
    db::upsert_tracks(vec![track(
        "/music/c.mp3",
        "Midnight",
        Some("Someone"),
        None,
    )])
    .expect("写入");
    assert_eq!(
        db::search_tracks("night".to_string(), 10)
            .expect("检索")
            .len(),
        1,
        "英文词中片段也要命中"
    );

    // 多词是 AND：两个词都要出现在同一行
    assert_eq!(
        db::search_tracks("林间 电台".to_string(), 10)
            .expect("检索")
            .len(),
        1
    );
    assert!(
        db::search_tracks("林间 晴天".to_string(), 10)
            .expect("检索")
            .is_empty(),
        "跨行的两个词不应凑成一条结果"
    );

    // LIKE 通配符必须当字面量
    for query in ["%", "_", "%电%"] {
        assert!(
            db::search_tracks(query.to_string(), 10)
                .expect("检索")
                .is_empty(),
            "{query:?} 应被当字面量而不是通配符"
        );
    }
}

/// 传大小写 / 斜杠变体也要能删到。
///
/// `remove_tracks` 以前按字面 path 匹配，调用方传 `e:/music/a.mp3` 去删
/// `E:/Music/A.mp3` 会「删 0 条且不报错」。
#[test]
fn remove_tracks_matches_path_variants() {
    let (_lock, dir) = begin("remove_variant");
    db::init_db(dir.db_path()).expect("初始化曲库");
    db::upsert_tracks(vec![track(r"E:/Music/A.mp3", "夜航", None, None)]).expect("写入");

    let deleted = db::remove_tracks(vec!["e:/music/a.mp3".to_string()]).expect("删除");
    if cfg!(windows) {
        assert_eq!(deleted, 1, "归一化后应删到 1 条");
        assert!(db::all_tracks().expect("读取").is_empty());
    } else {
        // 非 Windows 路径区分大小写，保持原有语义
        assert_eq!(deleted, 0);
    }
}

/// 删曲目后立刻回收不再被引用的封面，而不是等到下次扫描
#[test]
fn remove_tracks_prunes_orphan_covers() {
    let (_lock, dir) = begin("remove_cover");
    db::init_db(dir.db_path()).expect("初始化曲库");

    let covers = dir.0.join("covers");
    fs::create_dir_all(&covers).expect("建封面目录");
    let cover = covers.join("deadbeef.jpg");
    fs::write(&cover, b"fake-jpeg").expect("写封面");

    let mut item = track("/music/a.mp3", "夜航", None, None);
    item.cover_path = Some(cover.to_string_lossy().into_owned());
    db::upsert_tracks(vec![item]).expect("写入");
    assert!(cover.exists(), "写入后封面应存在");

    assert_eq!(
        db::remove_tracks(vec!["/music/a.mp3".to_string()]).expect("删除"),
        1
    );
    assert!(!cover.exists(), "删除曲目后不再被引用的封面应被回收");
}

#[test]
fn hide_moves_track_into_hidden_list_and_unhide_restores_it() {
    let (_lock, dir) = begin("hide");
    db::init_db(dir.db_path()).expect("初始化曲库");
    db::upsert_tracks(vec![
        track("/music/hide.mp3", "要隐藏的", Some("周杰伦"), Some("专辑")),
        track("/music/keep.mp3", "留下的", None, None),
    ])
    .expect("入库");

    let hidden = db::hide_tracks(vec!["/music/hide.mp3".to_string()]).expect("隐藏");
    assert_eq!(hidden, 1);
    assert_eq!(db::all_tracks().expect("读曲库").len(), 1, "曲库里只剩一首");

    let listed = db::hidden_tracks().expect("读隐藏列表");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].title, "要隐藏的");
    assert_eq!(listed[0].artist, "周杰伦");
    assert_eq!(listed[0].album, "专辑");

    // 扫描时按 path_key 跳过，所以这里比的是归一化后的集合
    let keys = db::hidden_path_keys_for_test().expect("读排除集合");
    assert_eq!(keys.len(), 1);

    let restored = db::unhide_tracks(vec!["/music/hide.mp3".to_string()]).expect("恢复");
    assert_eq!(restored, 1);
    assert!(db::hidden_tracks().expect("读隐藏列表").is_empty());
    let all = db::all_tracks().expect("读曲库");
    assert_eq!(all.len(), 2);
    assert!(all.iter().any(|item| item.path == "/music/hide.mp3"));
}

#[test]
fn hiding_unknown_path_is_a_no_op() {
    let (_lock, dir) = begin("hide_missing");
    db::init_db(dir.db_path()).expect("初始化曲库");
    db::upsert_tracks(vec![track("/music/a.mp3", "a", None, None)]).expect("入库");

    let hidden = db::hide_tracks(vec!["/music/nope.mp3".to_string()]).expect("隐藏");
    assert_eq!(hidden, 0);
    assert_eq!(db::all_tracks().expect("读曲库").len(), 1);
    assert!(db::hidden_tracks().expect("读隐藏列表").is_empty());
}

/// 隐藏不能动用户数据。
///
/// v7 的实现是「元数据搬走 + 从 tracks 删行」，而收藏 / 歌单 / 播放历史 /
/// 听歌时长全部 `ON DELETE CASCADE` 挂在 `tracks(path)` 上：隐藏一首歌等于把
/// 它的收藏、歌单条目、播放历史和听歌时长一起删了，恢复只能还原一条空壳记录。
/// 现在改成 `tracks.hidden` 标记位，行留着，关系自然也在。
#[test]
fn hiding_keeps_collections_and_playtime() {
    let (_lock, dir) = begin("hide_keeps");
    db::init_db(dir.db_path()).expect("初始化曲库");
    let path = "/music/hide.mp3".to_string();
    db::upsert_tracks(vec![track(&path, "要隐藏的", Some("周杰伦"), Some("专辑"))]).expect("入库");

    let playlist = collections::create_playlist("我的歌单".to_string()).expect("建歌单");
    collections::add_track_to_playlist(playlist.id, path.clone()).expect("加进歌单");
    collections::set_favorite(path.clone(), true).expect("收藏");
    collections::record_play(path.clone()).expect("记一次播放");
    collections::record_play_time(path.clone(), 20261029, 42).expect("记时长");

    assert_eq!(db::hide_tracks(vec![path.clone()]).expect("隐藏"), 1);
    assert!(
        db::all_tracks().expect("读曲库").is_empty(),
        "曲库列表里看不到"
    );
    assert!(
        db::search_tracks("要隐藏".to_string(), 10)
            .expect("检索")
            .is_empty(),
        "搜索也不该再命中"
    );

    // 列表里不再出现（收藏 / 歌单 / 历史都按 hidden 过滤），但行都还在
    assert!(
        collections::list_favorites().expect("读收藏").is_empty(),
        "收藏列表不该再出现"
    );
    assert!(
        collections::is_favorite(path.clone()).expect("读收藏"),
        "收藏那一行必须留着，否则恢复就找不回来了"
    );
    assert!(
        collections::playlist_tracks(playlist.id)
            .expect("读歌单")
            .is_empty(),
        "歌单列表里不该再出现"
    );
    assert!(
        !collections::add_track_to_playlist(playlist.id, path.clone()).expect("再加一次"),
        "说「已经在歌单里」就证明条目没被删掉"
    );
    assert_eq!(
        collections::list_playlists().expect("读歌单列表")[0].track_count,
        0,
        "歌单曲目数只数看得见的"
    );
    assert!(
        collections::recent_tracks(10).expect("读历史").is_empty(),
        "播放历史里不该再出现"
    );
    assert_eq!(
        collections::play_stats().expect("读统计").total_plays,
        1,
        "播放次数是聚合值，隐藏不该让统计变小"
    );
    assert_eq!(
        collections::play_stats().expect("读统计").total_seconds,
        42,
        "听歌时长要留着"
    );

    // 隐藏的是「正在播放」那首时，播放器还在继续写：这些操作不能报错
    collections::set_favorite(path.clone(), false).expect("隐藏后仍可改收藏");
    collections::record_play(path.clone()).expect("隐藏后仍可记播放");
    collections::record_play_time(path.clone(), 20261029, 8).expect("隐藏后仍可记时长");

    // 恢复：标记翻回去，一切原样
    assert_eq!(db::unhide_tracks(vec![path.clone()]).expect("恢复"), 1);
    let all = db::all_tracks().expect("读曲库");
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].title, "要隐藏的");
    assert_eq!(
        collections::playlist_tracks(playlist.id)
            .expect("读歌单")
            .len(),
        1,
        "恢复后歌单条目回到原位"
    );
    assert_eq!(
        collections::recent_tracks(10).expect("读历史").len(),
        1,
        "恢复后播放历史还在"
    );
    assert_eq!(
        collections::play_stats().expect("读统计").total_plays,
        2,
        "隐藏期间记的那次播放也要在"
    );
    assert_eq!(
        collections::play_stats().expect("读统计").total_seconds,
        50,
        "隐藏期间记的时长也要留着"
    );
}

/// v7 → v8：老库里已被隐藏的曲目从 `hidden_tracks` 搬回 `tracks` 并置位。
#[test]
fn migrate_v8_moves_v7_hidden_rows_back_into_tracks() {
    let (_lock, dir) = begin("migrate_v8");
    let path = dir.db_path();

    {
        let conn = rusqlite::Connection::open(&path).expect("打开 v7 库");
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
                added_at      INTEGER NOT NULL DEFAULT 0,
                file_mtime    INTEGER NOT NULL DEFAULT 0,
                file_size     INTEGER NOT NULL DEFAULT 0,
                cover_path    TEXT    NOT NULL DEFAULT '',
                replay_gain   REAL    NOT NULL DEFAULT 0
            );
            CREATE TABLE hidden_tracks (
                path          TEXT    PRIMARY KEY,
                title         TEXT    NOT NULL DEFAULT '',
                artist        TEXT    NOT NULL DEFAULT '',
                album         TEXT    NOT NULL DEFAULT '',
                duration_secs REAL    NOT NULL DEFAULT 0,
                hidden_at     INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO tracks (path, title) VALUES ('/music/keep.mp3', '留下的');
            INSERT INTO hidden_tracks (path, title, artist, album, duration_secs, hidden_at)
                VALUES ('/music/hide.mp3', '藏起来的', '歌手', '专辑', 180, 1000);
            PRAGMA user_version = 7;
            "#,
        )
        .expect("建 v7 库");
    }

    db::init_db(path.clone()).expect("升级 v7 库");

    let hidden = db::hidden_tracks().expect("读隐藏列表");
    assert_eq!(hidden.len(), 1, "老库里的隐藏记录要能被列出来");
    assert_eq!(hidden[0].path, "/music/hide.mp3");
    assert_eq!(hidden[0].title, "藏起来的");
    assert_eq!(hidden[0].artist, "歌手");
    assert_eq!(hidden[0].hidden_at, 1000);

    let all = db::all_tracks().expect("读曲库");
    assert_eq!(all.len(), 1, "搬回来但仍是隐藏状态，不该出现在列表里");

    // 老表用完即弃，避免两处状态并存
    let conn = rusqlite::Connection::open(&path).expect("重新打开");
    let legacy: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'hidden_tracks'",
            [],
            |row| row.get(0),
        )
        .expect("查表");
    assert_eq!(legacy, 0, "v7 的 hidden_tracks 表应被移除");
    drop(conn);

    assert_eq!(
        db::unhide_tracks(vec!["/music/hide.mp3".to_string()]).expect("恢复"),
        1
    );
    assert_eq!(db::all_tracks().expect("读曲库").len(), 2, "恢复后回到列表");
}

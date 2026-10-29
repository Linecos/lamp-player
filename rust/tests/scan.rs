//! 扫描链路测试：目录遍历 → 标签解析 → 入库 → 检索 → 增量与清理。
//!
//! 用例自己生成最小可解析的 WAV（无标签），所以不依赖仓库里带音频样本。

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

// 与下方 cfg(windows) 用例一起编译，非 Windows 上没有用武之地
#[cfg(windows)]
use rust_lib_lamp_player::api::collections;
#[cfg(windows)]
use rust_lib_lamp_player::api::model::Track;
use rust_lib_lamp_player::api::{db, scan};
use rust_lib_lamp_player::scanner;

/// 曲库连接是进程内单例，涉及 DB 的用例必须串行
static DB_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

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

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "lamp_scan_{}_{}_{}",
        tag,
        std::process::id(),
        nanos
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("创建临时目录");
    dir
}

#[test]
fn collects_audio_recursively_and_ignores_other_files() {
    let root = unique_dir("collect");
    write_wav(&root.join("a.wav"), 0.5);
    write_wav(&root.join("sub").join("b.WAV"), 1.0); // 扩展名大小写不敏感
    fs::write(root.join("notes.txt"), b"not audio").unwrap();
    fs::write(root.join("sub").join("cover.jpg"), b"not audio").unwrap();
    fs::write(root.join("legacy.wma"), b"not parsed").unwrap(); // lofty 不支持 ASF，扫描层不接收

    let collected = scanner::collect_tracks(&root).expect("扫描应成功");

    assert_eq!(collected.scanned, 2, "只统计命中扩展名的文件");
    assert_eq!(collected.unchanged, 0);
    assert_eq!(collected.failed, 0);
    assert_eq!(collected.walk_errors, 0);
    assert_eq!(collected.seen.len(), 2, "候选文件都要记入 seen");
    assert_eq!(collected.tracks.len(), 2);

    let mut titles: Vec<&str> = collected
        .tracks
        .iter()
        .map(|t| t.track.title.as_str())
        .collect();
    titles.sort_unstable();
    assert_eq!(titles, vec!["a", "b"], "无标签时用文件名兜底");

    for item in &collected.tracks {
        assert!(item.track.path.ends_with(".wav") || item.track.path.ends_with(".WAV"));
        assert!(item.track.duration_secs > 0.4, "时长应被解析出来");
        assert!(item.track.added_at > 0);
        assert!(item.track.artist.is_none());
        assert!(item.size > 0, "应记录文件大小");
        assert!(item.mtime_ns > 0, "应记录修改时间");
    }

    fs::remove_dir_all(&root).ok();
}

#[test]
fn missing_directory_is_an_error() {
    let missing = std::env::temp_dir().join("lamp_scan_definitely_missing_dir");
    assert!(scanner::collect_tracks(&missing).is_err());
}

#[test]
fn scan_folder_is_incremental_and_prunes_deleted_files() {
    // 全局连接是单例，涉及 DB 的用例都需要拿锁串行
    let _guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let root = unique_dir("pipeline");
    let db_path = root.join("library.db");
    db::init_db(db_path.to_string_lossy().into_owned()).expect("初始化曲库");

    let music = root.join("music");
    write_wav(&music.join("本地音乐.wav"), 0.5);

    let report = scan::scan_folder(music.to_string_lossy().into_owned()).expect("扫描应成功");
    assert_eq!(report.scanned, 1);
    assert_eq!(report.unchanged, 0);
    assert_eq!(report.upserted, 1);
    assert_eq!(report.failed, 0);
    assert_eq!(report.walk_errors, 0);
    assert_eq!(report.pruned, 0);
    assert!(report.elapsed_ms >= 0);

    let tracks = db::all_tracks().expect("读取曲库");
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].title, "本地音乐");

    // FTS5 对 CJK 不分词，只能前缀匹配：搜「本地」能命中
    let hits = db::search_tracks("本地".to_string(), 10).expect("检索");
    assert_eq!(hits.len(), 1, "中文前缀应命中");

    // 再扫一次：文件没变，不重新解析、不产生重复记录
    let again = scan::scan_folder(music.to_string_lossy().into_owned()).expect("重复扫描");
    assert_eq!(again.scanned, 1);
    assert_eq!(again.unchanged, 1);
    assert_eq!(again.upserted, 0);
    assert_eq!(db::all_tracks().expect("读取曲库").len(), 1);

    // 删掉文件再扫：记录被清理
    fs::remove_file(music.join("本地音乐.wav")).expect("删除测试音频");
    let after_delete = scan::scan_folder(music.to_string_lossy().into_owned()).expect("清理扫描");
    assert_eq!(after_delete.scanned, 0);
    assert_eq!(after_delete.pruned, 1);
    assert!(db::all_tracks().expect("读取曲库").is_empty());

    db::close_db().expect("关闭曲库");
    fs::remove_dir_all(&root).ok();
}

/// v3：扫描时提取内嵌封面并写入曲库同级的 covers/ 缓存。
#[test]
fn scan_extracts_embedded_cover_and_prunes_unused_files() {
    use lofty::config::WriteOptions;
    use lofty::file::{AudioFile, TaggedFileExt};
    use lofty::picture::{MimeType, Picture, PictureType};
    use lofty::tag::{Accessor, Tag, TagType};

    let _guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let root = unique_dir("cover");
    let db_path = root.join("library.db");
    db::init_db(db_path.to_string_lossy().into_owned()).expect("初始化曲库");

    let music = root.join("music");
    let song = music.join("带封面.wav");
    write_wav(&song, 0.5);

    // 1×1 透明 PNG
    const PNG: &[u8] = &[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f,
        0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc,
        0xcf, 0xc0, 0x50, 0x0f, 0x00, 0x04, 0x85, 0x01, 0x80, 0x84, 0xa9, 0x8c, 0x21, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ];

    let mut tagged = lofty::read_from_path(&song).expect("读取测试音频");
    let mut tag = Tag::new(TagType::Id3v2);
    tag.set_title("带封面".to_string());
    tag.push_picture(
        Picture::unchecked(PNG.to_vec())
            .pic_type(PictureType::CoverFront)
            .mime_type(MimeType::Png)
            .build(),
    );
    tagged.insert_tag(tag);
    tagged
        .save_to_path(&song, WriteOptions::default())
        .expect("写入内嵌封面");

    let report = scan::scan_folder(music.to_string_lossy().into_owned()).expect("扫描");
    assert_eq!(report.upserted, 1);
    assert_eq!(report.failed, 0);

    let tracks = db::all_tracks().expect("读取曲库");
    assert_eq!(tracks.len(), 1);
    let cover = tracks[0].cover_path.clone().expect("应提取到封面");
    assert_eq!(
        fs::read(&cover).expect("读取封面缓存"),
        PNG,
        "缓存内容应与内嵌图一致"
    );
    assert!(
        cover.replace('\\', "/").contains("/covers/"),
        "封面应放在曲库目录的 covers/ 下: {cover}"
    );

    // 封面缓存被清理、音频本身没变：重扫应重新解析并补回封面
    fs::remove_file(&cover).expect("删除封面缓存");
    let healed = scan::scan_folder(music.to_string_lossy().into_owned()).expect("补扫");
    assert_eq!(
        healed.upserted, 1,
        "封面缺失的曲目应被重新解析，而不是按指纹跳过"
    );
    let healed_tracks = db::all_tracks().expect("读取曲库");
    let healed_cover = healed_tracks[0].cover_path.clone().expect("应重新提取封面");
    assert_eq!(
        fs::read(&healed_cover).expect("读取补回的封面"),
        PNG,
        "补回的封面内容应与内嵌图一致"
    );

    // 删掉曲目再扫：曲目记录与无人引用的封面都应被清理
    fs::remove_file(&song).expect("删除测试音频");
    let after = scan::scan_folder(music.to_string_lossy().into_owned()).expect("清理扫描");
    assert_eq!(after.pruned, 1);
    assert!(!Path::new(&cover).exists(), "无引用的封面应被清理");

    db::close_db().expect("关闭曲库");
    fs::remove_dir_all(&root).ok();
}

/// 老版本可能把正斜杠路径写进库；重新扫描后应按归一化 key 合并成一条。
#[cfg(windows)]
#[test]
fn scan_merges_legacy_separator_variants() {
    let _guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let root = unique_dir("legacy_sep");
    let db_path = root.join("library.db");
    db::init_db(db_path.to_string_lossy().into_owned()).expect("初始化曲库");

    let music = root.join("music");
    write_wav(&music.join("song.wav"), 0.5);
    // 用 canonicalize 后的目录构造旧记录：只差分隔符，模拟老版本存下的正斜杠路径
    // （temp 目录的短路径 8.3 形式属于另一类差异，不在本用例范围内）
    let canonical = dunce::canonicalize(&music)
        .expect("解析真实路径")
        .to_string_lossy()
        .into_owned();
    let legacy = format!("{}/song.wav", canonical.replace('\\', "/"));

    // 先塞一条正斜杠的旧记录（指纹为 0，因此不会被当成 unchanged）
    db::upsert_tracks(vec![Track {
        path: legacy.clone(),
        title: "旧记录".to_string(),
        artist: None,
        album: None,
        duration_secs: 1.0,
        track_num: None,
        added_at: 1,
        cover_path: None,
        replay_gain: 0.0,
    }])
    .expect("写入旧记录");
    assert_eq!(db::all_tracks().expect("读取曲库").len(), 1);

    let playlist = collections::create_playlist("Legacy".to_string()).expect("新建歌单");
    collections::add_track_to_playlist(playlist.id, legacy.clone()).expect("旧路径加入歌单");
    collections::set_favorite(legacy.clone(), true).expect("收藏旧路径");
    collections::record_play(legacy.clone()).expect("记录旧路径历史");

    let report = scan::scan_folder(canonical).expect("扫描");
    assert_eq!(report.upserted, 1);
    assert_eq!(report.pruned, 0, "旧记录应被合并，而不是当成已删除");

    let all = db::all_tracks().expect("读取曲库");
    assert_eq!(all.len(), 1, "不应留下正斜杠孪生行");
    assert_eq!(
        all[0].path.replace('/', "\\").to_lowercase(),
        legacy.replace('/', "\\").to_lowercase()
    );
    assert_eq!(all[0].title, "song", "应保留本次扫描解析出的标题");

    // 路径合并不能把用户数据级联删掉，引用应迁到新路径
    let favorites = collections::list_favorites().expect("收藏列表");
    assert_eq!(favorites.len(), 1, "收藏应保留");
    assert_eq!(favorites[0].path, all[0].path);
    let items = collections::playlist_tracks(playlist.id).expect("歌单曲目");
    assert_eq!(items.len(), 1, "歌单条目应保留");
    assert_eq!(items[0].path, all[0].path);
    let recent = collections::recent_tracks(10).expect("播放历史");
    assert_eq!(recent.len(), 1, "播放历史应保留");
    assert_eq!(recent[0].path, all[0].path);

    db::close_db().expect("关闭曲库");
    fs::remove_dir_all(&root).ok();
}

/// Windows 文件系统不区分大小写：同一目录换大小写/正斜杠写法重扫，
/// 应被视为同一批文件——不重复入库、不重复解析、不误清理。
#[cfg(windows)]
#[test]
fn scan_matches_paths_across_case_and_separator_changes() {
    let _guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let root = unique_dir("casing");
    let db_path = root.join("library.db");
    db::init_db(db_path.to_string_lossy().into_owned()).expect("初始化曲库");

    let music = root.join("music");
    write_wav(&music.join("song.wav"), 0.5);

    let first = scan::scan_folder(music.to_string_lossy().into_owned()).expect("首次扫描");
    assert_eq!(first.upserted, 1);

    // 换成全小写 + 正斜杠的写法重扫
    let tilted = music.to_string_lossy().to_lowercase().replace('\\', "/");
    let again = scan::scan_folder(tilted.clone()).expect("重扫");
    assert_eq!(again.scanned, 1);
    assert_eq!(again.unchanged, 1, "应命中已有指纹，跳过解析");
    assert_eq!(again.upserted, 0, "不应产生重复记录");
    assert_eq!(again.pruned, 0, "不应误清理");
    assert_eq!(db::all_tracks().expect("读取曲库").len(), 1);

    // 同样写法删文件后清理也应生效
    fs::remove_file(music.join("song.wav")).expect("删除测试音频");
    let after_delete = scan::scan_folder(tilted.clone()).expect("清理扫描");
    assert_eq!(after_delete.pruned, 1);
    assert!(db::all_tracks().expect("读取曲库").is_empty());

    db::close_db().expect("关闭曲库");
    fs::remove_dir_all(&root).ok();
}

/// 隐藏之后重扫：不重新解析（指纹还在），也不会被重新加回列表。
///
/// v7 的隐藏是把行搬进 hidden_tracks 再删掉，隐藏曲目因此从增量指纹里消失，
/// 每次扫描都要重新读标签、重新抽封面——抽出来的封面还会在扫描结束时被
/// 当成残留删掉。改成标记位之后指纹还在，重扫应当全部 `unchanged`。
#[test]
fn scan_skips_hidden_tracks_without_reparsing() {
    let _guard = DB_LOCK.lock().unwrap_or_else(|err| err.into_inner());
    let root = unique_dir("hidden");
    let db_path = root.join("library.db");
    db::init_db(db_path.to_string_lossy().into_owned()).expect("初始化曲库");

    let music = root.join("music");
    write_wav(&music.join("a.wav"), 0.5);
    write_wav(&music.join("b.wav"), 0.5);

    let first = scan::scan_folder(music.to_string_lossy().into_owned()).expect("首扫");
    assert_eq!(first.upserted, 2);

    let tracks = db::all_tracks().expect("读曲库");
    let hidden_path = tracks
        .iter()
        .find(|item| item.title == "a")
        .expect("应有 a.wav")
        .path
        .clone();
    assert_eq!(db::hide_tracks(vec![hidden_path]).expect("隐藏"), 1);
    assert_eq!(db::all_tracks().expect("读曲库").len(), 1);

    let again = scan::scan_folder(music.to_string_lossy().into_owned()).expect("重扫");
    assert_eq!(again.scanned, 2, "两个文件都还在磁盘上");
    assert_eq!(again.unchanged, 2, "隐藏曲目也在指纹里，不该重新解析");
    assert_eq!(again.upserted, 0);
    assert_eq!(again.pruned, 0, "隐藏不算「磁盘上没了」");
    assert_eq!(
        db::all_tracks().expect("读曲库").len(),
        1,
        "重扫不该把它加回来"
    );
    assert_eq!(db::hidden_tracks().expect("读隐藏列表").len(), 1);

    fs::remove_dir_all(&root).ok();
}

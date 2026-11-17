//! 自定义艺术家 / 专辑封面存取测试。
//!
//! 曲库连接是进程内单例，所有用例用 `DB_LOCK` 串行执行，每个用例一个临时库。

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use image::ImageEncoder;
use rust_lib_lamp_player::api::{cover_override, db};

static DB_LOCK: Mutex<()> = Mutex::new(());

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "lamp_cover_{}_{}_{}",
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
    let dir = TempDir::new(tag);
    db::init_db(dir.db_path()).expect("初始化曲库");
    (guard, dir)
}

/// 写一张纯色小图，返回它的绝对路径。
fn write_png(dir: &Path, name: &str, rgb: [u8; 3]) -> String {
    let image = image::RgbImage::from_pixel(8, 8, image::Rgb(rgb));
    let mut out: Vec<u8> = Vec::new();
    image::codecs::png::PngEncoder::new(&mut out)
        .write_image(image.as_raw(), 8, 8, image::ExtendedColorType::Rgb8)
        .expect("编码 PNG");
    let path = dir.join(name);
    fs::write(&path, out).expect("写图片");
    path.to_string_lossy().into_owned()
}

#[test]
fn artist_cover_roundtrip() {
    let (_lock, dir) = begin("artist");
    let source = write_png(&dir.0, "cover.png", [10, 20, 30]);

    let stored = cover_override::set_cover_override(
        "artist".to_string(),
        "  林间电台  ".to_string(),
        String::new(),
        source,
    )
    .expect("设置艺术家封面");

    assert!(Path::new(&stored).is_file(), "缓存文件应当已落盘");
    assert!(
        stored.contains("custom_covers"),
        "自定义封面要落在独立目录，不能进扫描缓存：{stored}"
    );

    let list = cover_override::list_cover_overrides().expect("列出封面");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].kind, "artist");
    assert_eq!(list[0].name, "林间电台", "名称应去掉首尾空白");
    assert_eq!(list[0].artist, "", "艺术家封面不带 artist 字段");

    assert!(cover_override::clear_cover_override(
        "artist".to_string(),
        "林间电台".to_string(),
        String::new()
    )
    .expect("撤掉封面"));
    assert!(cover_override::list_cover_overrides().unwrap().is_empty());
    assert!(!Path::new(&stored).exists(), "撤掉后缓存文件要一起删");
}

#[test]
fn album_cover_keeps_artist_apart() {
    let (_lock, dir) = begin("album");
    let first = write_png(&dir.0, "a.png", [200, 10, 10]);
    let second = write_png(&dir.0, "b.png", [10, 200, 10]);

    cover_override::set_cover_override(
        "album".to_string(),
        "同名专辑".to_string(),
        "甲".to_string(),
        first,
    )
    .expect("甲的同名专辑");
    cover_override::set_cover_override(
        "album".to_string(),
        "同名专辑".to_string(),
        "乙".to_string(),
        second,
    )
    .expect("乙的同名专辑");

    let list = cover_override::list_cover_overrides().unwrap();
    assert_eq!(list.len(), 2, "同名专辑在不同艺术家下是两条，不能互相覆盖");

    // 只撤掉其中一条，另一条不受影响
    assert!(cover_override::clear_cover_override(
        "album".to_string(),
        "同名专辑".to_string(),
        "甲".to_string()
    )
    .unwrap());
    let left = cover_override::list_cover_overrides().unwrap();
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].artist, "乙");
}

#[test]
fn replacing_cover_removes_previous_file() {
    let (_lock, dir) = begin("replace");
    let first = write_png(&dir.0, "one.png", [10, 10, 200]);
    let second = write_png(&dir.0, "two.png", [200, 200, 10]);

    let old = cover_override::set_cover_override(
        "artist".to_string(),
        "林间电台".to_string(),
        String::new(),
        first,
    )
    .unwrap();
    let new = cover_override::set_cover_override(
        "artist".to_string(),
        "林间电台".to_string(),
        String::new(),
        second,
    )
    .unwrap();

    assert_ne!(old, new, "换图后应当是不同的缓存文件");
    assert!(Path::new(&new).exists());
    assert!(
        !Path::new(&old).exists(),
        "旧缓存文件要顺手删掉，别越攒越多"
    );
    assert_eq!(
        cover_override::list_cover_overrides().unwrap().len(),
        1,
        "同一个艺术家只保留一条记录"
    );
}

#[test]
fn custom_cover_survives_prune() {
    let (_lock, dir) = begin("prune");
    let source = write_png(&dir.0, "cover.png", [90, 90, 90]);
    let stored = cover_override::set_cover_override(
        "album".to_string(),
        "某专辑".to_string(),
        "某人".to_string(),
        source,
    )
    .unwrap();

    // 清理缺失曲目时会顺手回收没有被曲目引用的封面文件；
    // 自定义封面没挂在 tracks 上，必须靠「独立目录」活下来
    db::prune_missing_tracks().expect("清理缺失曲目");

    assert!(
        Path::new(&stored).exists(),
        "自定义封面不能被扫描缓存回收：{stored}"
    );
    assert_eq!(cover_override::list_cover_overrides().unwrap().len(), 1);
}

#[test]
fn rejects_bad_input() {
    let (_lock, dir) = begin("bad");

    // 未知类型
    assert!(cover_override::set_cover_override(
        "playlist".to_string(),
        "x".to_string(),
        String::new(),
        String::new()
    )
    .is_err());

    // 名称为空
    assert!(cover_override::set_cover_override(
        "album".to_string(),
        "   ".to_string(),
        "甲".to_string(),
        String::new()
    )
    .is_err());

    // 专辑缺艺术家
    assert!(cover_override::set_cover_override(
        "album".to_string(),
        "专辑".to_string(),
        String::new(),
        String::new()
    )
    .is_err());

    // 文件不存在
    assert!(cover_override::set_cover_override(
        "artist".to_string(),
        "甲".to_string(),
        String::new(),
        dir.0.join("missing.png").to_string_lossy().into_owned()
    )
    .is_err());

    // 内容不是图片（扩展名骗人）
    let fake = dir.0.join("fake.png");
    fs::write(&fake, b"not an image").unwrap();
    assert!(cover_override::set_cover_override(
        "artist".to_string(),
        "甲".to_string(),
        String::new(),
        fake.to_string_lossy().into_owned()
    )
    .is_err());

    assert!(
        cover_override::list_cover_overrides().unwrap().is_empty(),
        "失败的调用不该留下记录"
    );
}

#[test]
fn playlist_cover_uses_id_and_ignores_artist() {
    let (_lock, dir) = begin("playlist");
    let source = write_png(&dir.0, "cover.png", [40, 120, 200]);

    // 歌单用 id 当键：重命名不影响封面
    let stored = cover_override::set_cover_override(
        "playlist".to_string(),
        "42".to_string(),
        "多余的艺术家长".to_string(),
        source,
    )
    .expect("设置歌单封面");

    let list = cover_override::list_cover_overrides().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].kind, "playlist");
    assert_eq!(list[0].name, "42");
    assert_eq!(list[0].artist, "", "歌单封面不带 artist，传了也要归零");

    assert!(Path::new(&stored).is_file());
    assert!(cover_override::clear_cover_override(
        "playlist".to_string(),
        "42".to_string(),
        String::new()
    )
    .unwrap());
}

#[test]
fn clear_missing_override_is_false() {
    let (_lock, _dir) = begin("clear");
    assert!(
        !cover_override::clear_cover_override(
            "artist".to_string(),
            "没设过".to_string(),
            String::new()
        )
        .unwrap(),
        "本来没有自定义封面时返回 false，不算错误"
    );
}

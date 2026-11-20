//! 标签读写测试：新字段（作曲 / 作词 / 注释）能进能出，封面能嵌进文件。

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use rust_lib_lamp_player::api::db::{close_db, init_db};
use rust_lib_lamp_player::api::metadata::{
    audio_channels, read_track_tags, write_track_cover, write_track_tags, TrackTags,
};

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "lamp_meta_{}_{}_{}",
            tag,
            std::process::id(),
            nanos
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("创建临时目录");
        Self(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// 44.1 kHz 单声道 0.2 秒静音 WAV
fn write_wav(path: &PathBuf) {
    let sample_rate: u32 = 44100;
    let bits: u16 = 16;
    let data_len = sample_rate / 5 * u32::from(bits / 8);
    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&(sample_rate * u32::from(bits / 8)).to_le_bytes());
    buf.extend_from_slice(&(bits / 8).to_le_bytes());
    buf.extend_from_slice(&bits.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    buf.resize(44 + data_len as usize, 0);
    fs::write(path, buf).expect("写入测试音频");
}

/// 4×4 纯色 PNG（最小可解码位图，用来当封面）
fn write_png(path: &PathBuf, rgb: [u8; 3]) {
    let mut buf: Vec<u8> = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut ihdr: Vec<u8> = Vec::new();
    ihdr.extend_from_slice(&4u32.to_be_bytes());
    ihdr.extend_from_slice(&4u32.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    push_chunk(&mut buf, b"IHDR", &ihdr);
    // 每行一个 filter 字节（0 = None）+ 4 个像素的 RGB
    let mut raw: Vec<u8> = Vec::new();
    for _ in 0..4 {
        raw.extend(std::iter::repeat_n(0u8, 1));
        for _ in 0..4 {
            raw.extend_from_slice(&rgb);
        }
    }
    push_chunk(&mut buf, b"IDAT", &flate_store(&raw));
    push_chunk(&mut buf, b"IEND", &[]);
    fs::write(path, buf).expect("写入测试图片");
}

fn push_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let crc = crc32(&out[start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

/// 未压缩的 zlib 流（stored 块）：只为造一张能被解码的图，不值得引入压缩库
fn flate_store(data: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = vec![0x78, 0x01];
    let mut rest = data;
    while !rest.is_empty() {
        let take = rest.len().min(65535);
        let last = take == rest.len();
        out.push(u8::from(last));
        out.extend_from_slice(&(take as u16).to_le_bytes());
        out.extend_from_slice(&(!(take as u16)).to_le_bytes());
        out.extend_from_slice(&rest[..take]);
        rest = &rest[take..];
    }
    let mut a: u32 = 1;
    let mut b: u32 = 0;
    for byte in data {
        a = (a + u32::from(*byte)) % 65521;
        b = (b + a) % 65521;
    }
    out.extend_from_slice(&((b << 16) | a).to_be_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

#[test]
fn new_fields_round_trip() {
    let dir = TempDir::new("fields");
    let song = dir.0.join("词曲.wav");
    write_wav(&song);

    let written = write_track_tags(
        song.to_string_lossy().into_owned(),
        TrackTags {
            title: "夜航".into(),
            artist: "林间电台".into(),
            album: "深夜频道".into(),
            album_artist: "群星".into(),
            year: "2003".into(),
            track_no: "3".into(),
            disc_no: "1".into(),
            genre: "Ambient".into(),
            composer: "坂本龍一".into(),
            lyricist: "佚名".into(),
            comment: "第一行\n第二行".into(),
        },
    )
    .expect("写入标签");

    assert_eq!(written.composer, "坂本龍一");
    let read = read_track_tags(song.to_string_lossy().into_owned()).expect("读回标签");
    assert_eq!(read.lyricist, "佚名");
    assert_eq!(read.comment, "第一行\n第二行");
    assert_eq!(read.album_artist, "群星");
}

#[test]
fn channels_come_from_file_header() {
    let dir = TempDir::new("channels");
    let song = dir.0.join("声道.wav");
    write_wav(&song);

    // 测试用的 WAV 是单声道：能读出 1，说明走的是文件头而不是别的缓存
    assert_eq!(
        audio_channels(song.to_string_lossy().into_owned()).expect("读声道数"),
        1
    );
    // 空路径 / 不存在的文件都不能 panic
    assert!(audio_channels(String::new()).is_err());
    let missing = dir.0.join("不存在.wav");
    assert!(audio_channels(missing.to_string_lossy().into_owned()).is_err());
}

#[test]
fn empty_value_clears_new_fields() {
    let dir = TempDir::new("clear");
    let song = dir.0.join("清空.wav");
    write_wav(&song);
    let path = song.to_string_lossy().into_owned();

    write_track_tags(
        path.clone(),
        TrackTags {
            title: "标题".into(),
            composer: "作曲".into(),
            lyricist: "作词".into(),
            comment: "注释".into(),
            ..TrackTags::default()
        },
    )
    .expect("先写入");
    let cleared = write_track_tags(
        path.clone(),
        TrackTags {
            title: "标题".into(),
            ..TrackTags::default()
        },
    )
    .expect("再清空");

    assert_eq!(cleared.composer, "", "空值应当删键而不是写空串");
    let read = read_track_tags(path).expect("读回");
    assert_eq!(read.lyricist, "");
    assert_eq!(read.comment, "");
}

#[test]
fn cover_is_embedded_and_cached() {
    let dir = TempDir::new("cover");
    let song = dir.0.join("带封面.wav");
    write_wav(&song);
    let source = dir.0.join("cover.png");
    write_png(&source, [12, 200, 90]);

    // 缓存目录跟着曲库走：先把「曲库」指到临时目录，才拿得到真实路径
    init_db(dir.0.join("library.db").to_string_lossy().into_owned()).expect("初始化曲库");

    let cached = write_track_cover(
        song.to_string_lossy().into_owned(),
        source.to_string_lossy().into_owned(),
    )
    .expect("写入封面");

    assert!(
        std::path::Path::new(&cached).is_file(),
        "缓存文件应存在：{cached}"
    );
    // 文件里那张也还在：换台机器、丢了缓存目录，扫描时还能重新提取
    use lofty::file::TaggedFileExt;
    let tagged = lofty::read_from_path(&song).expect("解析音频");
    let pictures = tagged.primary_tag().expect("有标签").pictures();
    assert_eq!(pictures.len(), 1);
    assert!(!pictures[0].data().is_empty());

    close_db().expect("关闭曲库");
}

#[test]
fn broken_image_is_rejected() {
    let dir = TempDir::new("broken");
    let song = dir.0.join("坏图.wav");
    write_wav(&song);
    let source = dir.0.join("not-image.png");
    fs::write(&source, b"not an image").expect("写入假图");

    let error = write_track_cover(
        song.to_string_lossy().into_owned(),
        source.to_string_lossy().into_owned(),
    )
    .expect_err("不是图片就该报错");
    assert!(
        error.to_string().contains("有效的图片"),
        "错误信息要能看懂：{error}"
    );
}

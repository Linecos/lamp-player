//! 目录扫描与标签解析。
//!
//! 这是**内部模块**，不经 frb 导出给 Dart；对外只通过 `api::scan::scan_folder`。
//! 单独成模块的目的：能脱离数据库直接测试「遍历 + 解析」这段纯逻辑。

use crate::api::model::Track;
use anyhow::{Context, Result};
use image::ImageEncoder;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::tag::{Accessor, ItemKey, Tag};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;

/// 封面单张大小上限：个别文件会把整本扫描册塞进标签，没必要全部落盘。
const MAX_COVER_BYTES: usize = 20 * 1024 * 1024;

/// 支持的音频扩展名（小写，不含点）
///
/// 注意：**不含 wma**。标签解析用的 lofty 不支持 ASF/WMA，把 wma 列进来
/// 只会让每个文件走一遍注定失败的解析（`failed` 虚高且不产生记录）。
/// 若将来要支持 wma，需要另配 ASF 解析方案再加入。
pub const AUDIO_EXTENSIONS: &[&str] = &["mp3", "flac", "wav", "ogg", "m4a", "aac", "ape", "opus"];

/// 解析成功的一条曲目 + 文件指纹（增量扫描用）。
pub struct ScannedTrack {
    pub track: Track,
    /// 文件修改时间（Unix 纳秒）
    pub mtime_ns: i64,
    /// 文件大小（字节）
    pub size: i64,
}

/// 一次目录遍历的原始结果（尚未入库）
#[derive(Default)]
pub struct Collected {
    /// 新解析出来、需要入库的曲目
    pub tracks: Vec<ScannedTrack>,
    /// 遍历到的所有候选文件路径 key（归一化后，用于清理比对）
    pub seen: HashSet<String>,
    /// 命中扩展名的文件数（含未变化与解析失败的）
    pub scanned: usize,
    /// 因 mtime/size 未变而跳过的文件数
    pub unchanged: usize,
    /// 解析失败被跳过的文件数
    pub failed: usize,
    /// 遍历时读不到的条目数（权限、IO 错误等）
    pub walk_errors: usize,
}

/// 递归收集目录下的音频文件并解析元数据（全量，不做增量比对）。
pub fn collect_tracks(folder: &Path) -> Result<Collected> {
    collect_tracks_incremental(folder, &HashMap::new(), None)
}

/// 递归收集目录下的音频文件并解析元数据。
///
/// `known` 是曲库里已有的文件指纹：mtime/size 都没变的文件跳过解析，只记入
/// `seen`；单个文件解析失败只计入 `failed`，不影响整体；目录不可用时返回错误。
/// `covers_dir` 提供时把内嵌封面落盘到该目录，否则不提取封面。
///
/// 指纹与 `seen` 的 key 都经过 [`path_key`] 归一化（Windows 下大小写/斜杠等价），
/// 因此调用方传入的 `known` 必须同样用 [`path_key`] 归一化过 key。
pub fn collect_tracks_incremental(
    folder: &Path,
    known: &HashMap<String, (i64, i64)>,
    covers_dir: Option<&Path>,
) -> Result<Collected> {
    if !folder.is_dir() {
        anyhow::bail!("目录不存在或不是目录: {}", folder.display());
    }

    let mut collected = Collected::default();
    let added_at = now_secs();
    // 遍历阶段只取指纹，解析留给线程池：walkdir + metadata 是顺序 IO，
    // 解析（读标签、解封面）才是耗时的大头。
    let mut pending: Vec<Candidate> = Vec::new();

    // 不跟随软链接，避免目录环导致无限遍历
    for entry in WalkDir::new(folder).follow_links(false) {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => {
                collected.walk_errors += 1;
                continue;
            }
        };

        if !entry.file_type().is_file() {
            // 指向文件的符号链接：file_type() 是 symlink，但应当被扫描到。
            // 目录链接仍然不跟随（上面的 follow_links(false)），避免目录环。
            if !(entry.file_type().is_symlink() && entry.path().is_file()) {
                continue;
            }
        }

        let path = entry.path();
        if !is_audio_file(path) {
            continue;
        }

        // 取不到 metadata 就无法判断是否变化，计入遍历错误并跳过。
        //
        // 符号链接必须跟随目标取指纹：`entry.metadata()` 给的是链接自身，
        // 目标文件更新后链接的 mtime / size 都不变，增量扫描会一直判成
        // 「没变化」，这个文件从此再也不会被重新解析。
        let meta = if entry.file_type().is_symlink() {
            match fs::metadata(path) {
                Ok(meta) => meta,
                Err(_) => {
                    collected.walk_errors += 1;
                    continue;
                }
            }
        } else {
            match entry.metadata() {
                Ok(meta) => meta,
                Err(_) => {
                    collected.walk_errors += 1;
                    continue;
                }
            }
        };
        let (mtime_ns, size) = signature(&meta);

        let key = path_key(&path.to_string_lossy());
        collected.scanned += 1;
        collected.seen.insert(key.clone());

        if known.get(&key) == Some(&(mtime_ns, size)) {
            collected.unchanged += 1;
            continue;
        }

        pending.push(Candidate {
            path: path.to_path_buf(),
            mtime_ns,
            size,
        });
    }

    // 外挂封面按目录缓存：一个 500 首的专辑目录只有一张 folder.jpg，
    // 不缓存的话每首都 read_dir 一遍目录、再把整张图读进来算哈希
    // （8 MB 的图 × 500 次 ≈ 4 GB IO），首扫会卡在磁盘上。
    let sidecar_cache: Mutex<SidecarCache> = Mutex::new(HashMap::new());
    let (tracks, failed) = parse_candidates(&pending, added_at, covers_dir, &sidecar_cache);
    collected.tracks = tracks;
    collected.failed = failed;

    Ok(collected)
}

/// 并行解析的线程上限。
///
/// 本机（20 线程）实测 101 首真实曲库：串行 7.0s → 4 线程 2.3s → 8 线程 1.4s，
/// 再往上收益已经很小。不能只按核数开：封面归一化每条线程都要解一张原图
/// （3000px 的图瞬时几十 MB），线程越多扫描峰值内存越高。核数少的机器
/// `available_parallelism` 会给更小的值，自然降下来。
const PARSE_THREADS_MAX: usize = 8;

/// 遍历阶段收集到的待解析文件
struct Candidate {
    path: PathBuf,
    mtime_ns: i64,
    size: i64,
}

/// 并行解析候选文件，结果顺序与 `pending` 一致。
fn parse_candidates(
    pending: &[Candidate],
    added_at: i64,
    covers_dir: Option<&Path>,
    cache: &Mutex<SidecarCache>,
) -> (Vec<ScannedTrack>, usize) {
    let threads = std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1)
        .clamp(1, PARSE_THREADS_MAX)
        .min(pending.len().max(1));
    if threads <= 1 {
        return parse_range(pending, added_at, covers_dir, cache);
    }

    let chunk = pending.len().div_ceil(threads);
    let mut tracks = Vec::with_capacity(pending.len());
    let mut failed = 0;
    std::thread::scope(|scope| {
        let handles: Vec<_> = pending
            .chunks(chunk)
            .map(|slice| scope.spawn(move || parse_range(slice, added_at, covers_dir, cache)))
            .collect();
        for handle in handles {
            // 单个文件的 panic 已在 read_track_guarded 里兜住；这里再兜一层，
            // 线程真挂了也只丢这一批，不能让整个扫描崩掉
            let (mut chunk_tracks, chunk_failed) = handle.join().unwrap_or_default();
            tracks.append(&mut chunk_tracks);
            failed += chunk_failed;
        }
    });
    (tracks, failed)
}

/// 解析一段候选，返回（成功解析的曲目，失败数）
fn parse_range(
    slice: &[Candidate],
    added_at: i64,
    covers_dir: Option<&Path>,
    cache: &Mutex<SidecarCache>,
) -> (Vec<ScannedTrack>, usize) {
    let mut tracks = Vec::with_capacity(slice.len());
    let mut failed = 0;
    for candidate in slice {
        match read_track_guarded(
            &candidate.path,
            added_at,
            candidate.mtime_ns,
            candidate.size,
            covers_dir,
            cache,
        ) {
            Ok(track) => tracks.push(track),
            Err(_) => failed += 1,
        }
    }
    (tracks, failed)
}

/// 按扩展名判断是否是候选音频文件（不区分大小写）
pub fn is_audio_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            AUDIO_EXTENSIONS
                .iter()
                .any(|known| ext.eq_ignore_ascii_case(known))
        })
        .unwrap_or(false)
}

/// 单次扫描内的外挂封面缓存：目录 → 该目录命中的封面缓存路径（`None` 表示没有）
type SidecarCache = HashMap<PathBuf, Option<String>>;

/// 解析单个文件，把 panic 隔离在单个文件内。
///
/// lofty 解析损坏/恶意文件时理论上可能 panic；panic 穿过 FFI 会直接终止进程，
/// 所以这里兜一层，把它降级成 `failed`。
fn read_track_guarded(
    path: &Path,
    added_at: i64,
    mtime_ns: i64,
    size: i64,
    covers_dir: Option<&Path>,
    sidecar_cache: &Mutex<SidecarCache>,
) -> Result<ScannedTrack> {
    match catch_unwind(AssertUnwindSafe(|| {
        read_track(path, added_at, mtime_ns, size, covers_dir, sidecar_cache)
    })) {
        Ok(result) => result,
        Err(_) => anyhow::bail!("解析元数据时发生 panic: {}", path.display()),
    }
}

/// 解析单个文件；读不出标签时用文件名兜底，不产生错误。
///
/// 只有「文件打不开 / 格式不受支持」才返回错误。
fn read_track(
    path: &Path,
    added_at: i64,
    mtime_ns: i64,
    size: i64,
    covers_dir: Option<&Path>,
    sidecar_cache: &Mutex<SidecarCache>,
) -> Result<ScannedTrack> {
    let tagged = lofty::read_from_path(path)
        .with_context(|| format!("解析元数据失败: {}", path.display()))?;

    let duration_secs = tagged.properties().duration().as_secs_f64();

    // primary_tag 按容器的主标签类型取（如 FLAC → VorbisComment），取不到再退到第一个标签
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());

    let title = tag
        .and_then(|t| t.title())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| file_stem(path));

    let artist = tag
        .and_then(|t| t.artist())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let album = tag
        .and_then(|t| t.album())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let track_num = tag
        .and_then(|t| t.track())
        .and_then(|n| i32::try_from(n).ok());

    // 封面来源优先级：标签内嵌 → 同目录外挂图（cover.jpg / folder.jpg …）
    let cover_path = covers_dir.and_then(|dir| {
        tag.and_then(|t| extract_cover(t, dir))
            .or_else(|| sidecar_cover_cached(path, dir, sidecar_cache))
    });

    // ReplayGain 曲目增益，标签里通常写成 "-7.23 dB"；没有就按 0 处理。
    // 上下限夹一下：个别文件写过 +60 dB 这种离谱值，直接套用会削波到失真。
    let replay_gain = tag
        .and_then(|t| t.get_string(ItemKey::ReplayGainTrackGain))
        .and_then(parse_replay_gain)
        .unwrap_or(0.0);

    Ok(ScannedTrack {
        track: Track {
            path: path.to_string_lossy().into_owned(),
            title,
            artist,
            album,
            duration_secs,
            track_num,
            added_at,
            cover_path,
            replay_gain,
        },
        mtime_ns,
        size,
    })
}

/// 解析 ReplayGain 文本（"-7.23 dB" / "-7.23"），超出 ±24 dB 夹回范围。
fn parse_replay_gain(raw: &str) -> Option<f64> {
    let value = raw.trim().trim_end_matches("dB").trim();
    let gain = value.parse::<f64>().ok().filter(|g| g.is_finite())?;
    Some(gain.clamp(-24.0, 24.0))
}

/// 从标签里取封面并落盘，返回缓存文件的绝对路径。
///
/// 优先正封面，其次第一张；只收 Flutter 能直接解码的格式。写盘失败只丢封面，
/// 不影响曲目入库。
fn extract_cover(tag: &Tag, covers_dir: &Path) -> Option<String> {
    let picture = tag
        .get_picture_type(PictureType::CoverFront)
        .or_else(|| tag.pictures().first())?;
    store_cover(covers_dir, picture)
}

/// 把图片按内容哈希存进缓存目录：同一张专辑封面只落一份盘。
///
/// 用 FNV-1a 而不是 `DefaultHasher`，保证跨进程、跨构建的文件名稳定。
fn store_cover(covers_dir: &Path, picture: &Picture) -> Option<String> {
    let extension = cover_extension(picture)?;
    store_cover_bytes(covers_dir, picture.data(), extension)
}

/// 把图片字节按内容哈希写进缓存目录（内嵌封面与外挂图共用）。
fn store_cover_bytes(covers_dir: &Path, data: &[u8], extension: &str) -> Option<String> {
    if data.is_empty() || data.len() > MAX_COVER_BYTES {
        return None;
    }
    fs::create_dir_all(covers_dir).ok()?;
    // 先归一化再落盘：之后每次显示都是「小图」，引擎不必从 3000px 的原图解起。
    // 归一化失败（编码不支持 / 文件损坏）就退回原始字节，绝不能因此丢封面。
    let (bytes, extension) = match normalize_cover(data) {
        Some(jpeg) => (jpeg, "jpg"),
        None => (data.to_vec(), extension),
    };
    let name = format!("{:016x}.{extension}", content_hash(&bytes));
    let path = covers_dir.join(name);
    if !path.exists() {
        fs::write(&path, &bytes).ok()?;
    }
    path.to_str().map(str::to_owned)
}

/// 封面最长边上限（设备像素）。
///
/// 播放页那个大封面在 440 逻辑像素、2x 屏下也只有 880，1024 已经留了余量；
/// 再大就是白白占解码内存和磁盘。
const COVER_MAX_EDGE: u32 = 1024;

/// 小于这个就不重新编码：已经够小，重编只会掉画质。
const COVER_MAX_BYTES_KEEP: usize = 300 * 1024;

/// JPEG 编码质量：q85 在缩过的封面上肉眼与原始无差，体积只有几分之一。
const COVER_JPEG_QUALITY: u8 = 85;

/// 把原始封面缩到 [`COVER_MAX_EDGE`] 以内并统一转成 JPEG。
///
/// 返回 `None` 表示「不需要处理」或「处理失败」，调用方应原样使用原始字节：
/// - 已经是小图（边 ≤ 1024 且体积 ≤ 300KB）：不动它，避免无谓的重新编码
/// - 解码失败（少见格式 / 损坏）：交回原图，至少还能显示
///
/// 为什么要重编码而不是只缩尺寸：PNG 没有 DCT 按比例解码，引擎会先解出整张
/// 3000×3000（约 36MB）再缩到显示尺寸，那一下就是一次几十 MB 的瞬时尖峰。
/// 统一成 JPEG 后源图本身就小，解码过程也就没有这个东西了。
fn normalize_cover(data: &[u8]) -> Option<Vec<u8>> {
    let decoded = image::load_from_memory(data).ok()?;
    let oversized = decoded.width().max(decoded.height()) > COVER_MAX_EDGE;
    if !oversized && data.len() <= COVER_MAX_BYTES_KEEP {
        return None;
    }
    let scaled = if oversized {
        // thumbnail 保持长宽比，只做快速盒式缩小
        decoded.thumbnail(COVER_MAX_EDGE, COVER_MAX_EDGE)
    } else {
        decoded
    };
    let rgb = scaled.into_rgb8();
    let mut out: Vec<u8> = Vec::with_capacity(128 * 1024);
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, COVER_JPEG_QUALITY)
        .write_image(
            rgb.as_raw(),
            rgb.width(),
            rgb.height(),
            image::ExtendedColorType::Rgb8,
        )
        .ok()?;
    Some(out)
}

/// 带目录缓存的 [`sidecar_cover`]。
///
/// 同一目录下的曲目共用一张外挂封面，命中一次就够：缓存的是「找到 + 落盘」
/// 之后的缓存文件名，后续曲目直接复用，不再 `read_dir` 目录、也不再整张读图。
/// 只在单次扫描内有效——扫描期间用户换封面属极少见，下次扫描自然纠正。
///
/// 缓存要跨解析线程共享，读盘那一段放在锁外：一张 8 MB 的外挂图不该把
/// 其它线程堵在锁上。两个线程同时首次命中同一目录时最多各读一遍，结果相同。
fn sidecar_cover_cached(
    path: &Path,
    covers_dir: &Path,
    cache: &Mutex<SidecarCache>,
) -> Option<String> {
    let dir = path.parent()?;
    if let Some(cached) = lock_cache(cache).get(dir) {
        return cached.clone();
    }
    let found = sidecar_cover(path, covers_dir);
    lock_cache(cache)
        .entry(dir.to_path_buf())
        .or_insert(found)
        .clone()
}

/// 取缓存锁；锁中毒（某个解析线程 panic）时继续用，不能让一次 panic 毁掉整次扫描。
fn lock_cache(cache: &Mutex<SidecarCache>) -> MutexGuard<'_, SidecarCache> {
    cache.lock().unwrap_or_else(|err| err.into_inner())
}

/// 同目录外挂封面兜底：`cover.jpg` / `folder.jpg` / `album.png` 之类。
///
/// 抓轨工具的习惯并不统一（Windows 媒体播放器写 `Folder.jpg`，多数工具写
/// `cover.jpg`），这里按固定名单 + 大小写不敏感匹配，命中的图仍按内容哈希
/// 进缓存目录，同一张专辑只会存一份。
fn sidecar_cover(path: &Path, covers_dir: &Path) -> Option<String> {
    /// 文件名优先级：越靠前越像「这张专辑的封面」
    const NAMES: [&str; 4] = ["cover", "folder", "albumart", "album"];
    const EXTS: [&str; 4] = ["jpg", "jpeg", "png", "gif"];

    let dir = path.parent()?;
    let mut best: Option<(usize, usize, PathBuf)> = None;
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let candidate = entry.path();
        if !candidate.is_file() {
            continue;
        }
        let (Some(stem), Some(ext)) = (candidate.file_stem(), candidate.extension()) else {
            continue;
        };
        let stem = stem.to_string_lossy().to_ascii_lowercase();
        let ext = ext.to_string_lossy().to_ascii_lowercase();
        let (Some(name_rank), Some(ext_rank)) = (
            NAMES.iter().position(|name| *name == stem),
            EXTS.iter().position(|known| *known == ext),
        ) else {
            continue;
        };
        // 名字优先、其次格式（jpg 比 gif 常见，解码也更快）
        let rank = (name_rank, ext_rank, candidate);
        if best
            .as_ref()
            .is_none_or(|current| (rank.0, rank.1) < (current.0, current.1))
        {
            best = Some((rank.0, rank.1, rank.2));
        }
    }

    let (_, _, file) = best?;
    let data = fs::read(&file).ok()?;
    // 扩展名不可信（用户可能把 png 存成 .jpg），按文件头再认一次
    let extension = sniff_image_extension(&data)?;
    store_cover_bytes(covers_dir, &data, extension)
}

/// 封面文件扩展名；不支持的格式返回 `None`（存下来也显示不了）。
fn cover_extension(picture: &Picture) -> Option<&'static str> {
    match picture.mime_type() {
        Some(MimeType::Jpeg) => Some("jpg"),
        Some(MimeType::Png) => Some("png"),
        Some(MimeType::Gif) => Some("gif"),
        Some(MimeType::Bmp) => Some("bmp"),
        // 标签里的 MIME 经常缺失或写错，按文件头再认一次
        _ => sniff_image_extension(picture.data()),
    }
}

fn sniff_image_extension(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpg")
    } else if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if data.starts_with(b"GIF8") {
        Some("gif")
    } else if data.starts_with(b"BM") {
        Some("bmp")
    } else {
        None
    }
}

fn content_hash(data: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in data {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// 文件名（去掉扩展名）作为标题兜底
fn file_stem(path: &Path) -> String {
    path.file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

/// 取文件指纹：修改时间（纳秒）+ 大小；取不到修改时间时 mtime 记 0（下次必重新解析）。
fn signature(meta: &std::fs::Metadata) -> (i64, i64) {
    let mtime_ns = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX))
        .unwrap_or(0);
    let size = i64::try_from(meta.len()).unwrap_or(i64::MAX);
    (mtime_ns, size)
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 路径归一化 key：同一文件在库里的不同写法要能对上号。
///
/// Windows 文件系统不区分大小写，`/` 与 `\` 等价，所以 `E:\Music`、
/// `e:\music`、`E:/Music` 是同一批文件；不归一化的话增量指纹全部 miss、
/// 清理比对不上，还会因 `path UNIQUE` 是区分大小写而产生重复记录。
/// 其它平台路径本就严格区分，原样返回。
///
/// 曲库侧取指纹（`file_signatures`）与清理（`prune_tracks_under`）使用同一口径。
#[must_use]
pub(crate) fn path_key(path: &str) -> String {
    path_key_with(path, cfg!(windows))
}

/// [`path_key`] 的可测试版本：`windows` 由调用方传入，
/// 这样在任意平台上都能验证两种归一化规则。
fn path_key_with(path: &str, windows: bool) -> String {
    if windows {
        path.replace('/', "\\").to_lowercase()
    } else {
        path.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        content_hash, lock_cache, normalize_cover, parse_replay_gain, path_key_with, sidecar_cover,
        sidecar_cover_cached, store_cover, store_cover_bytes, COVER_MAX_EDGE,
    };
    use image::ImageEncoder;
    use lofty::picture::{MimeType, Picture, PictureType};
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn replay_gain_parses_tag_text() {
        // 标签里的常见写法
        assert_eq!(parse_replay_gain("-7.23 dB"), Some(-7.23));
        assert_eq!(parse_replay_gain("+3.5dB"), Some(3.5));
        assert_eq!(parse_replay_gain(" 0 "), Some(0.0));
        // 离谱值夹回 ±24 dB，垃圾值按「没有标签」处理
        assert_eq!(parse_replay_gain("60 dB"), Some(24.0));
        assert_eq!(parse_replay_gain("loud"), None);
        assert_eq!(parse_replay_gain(""), None);
    }

    #[test]
    fn path_key_normalizes_only_on_windows() {
        assert_eq!(path_key_with("E:/Music/A.mp3", true), "e:\\music\\a.mp3");
        assert_eq!(path_key_with("/Music/A.mp3", false), "/Music/A.mp3");
    }

    #[test]
    fn content_hash_is_stable() {
        // FNV-1a 64 的公开测试向量；换实现时这一条会先失败
        assert_eq!(content_hash(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(content_hash(b"a"), 0xaf63_dc4c_8601_ec8c);
    }

    fn picture(data: &[u8], mime: Option<MimeType>) -> Picture {
        let mut builder = Picture::unchecked(data.to_vec()).pic_type(PictureType::CoverFront);
        if let Some(mime) = mime {
            builder = builder.mime_type(mime);
        }
        builder.build()
    }

    fn temp_dir(tag: &str) -> PathBuf {
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
        dir
    }

    #[test]
    fn oversized_cover_is_downscaled_and_reencoded_as_jpeg() {
        // 造一张 1600×1600 的 PNG：模拟曲库里那种 3000px 的原始封面。
        // 用噪声而不是渐变：渐变 PNG 压得比 JPEG 还小，比体积会失真。
        let mut seed: u32 = 0x1234_5678;
        let big = image::RgbImage::from_fn(1600, 1600, |_, _| {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let b = (seed >> 24) as u8;
            image::Rgb([b, b.wrapping_add(37), b.wrapping_add(91)])
        });
        let mut png: Vec<u8> = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png)
            .write_image(big.as_raw(), 1600, 1600, image::ExtendedColorType::Rgb8)
            .expect("编码 png");

        let out = normalize_cover(&png).expect("超尺寸的封面应该被归一化");
        assert!(out.starts_with(&[0xFF, 0xD8, 0xFF]), "应重编码成 JPEG");
        let back = image::load_from_memory(&out).expect("归一化结果应能解码");
        assert_eq!(
            back.width().max(back.height()),
            COVER_MAX_EDGE,
            "最长边应缩到上限"
        );
        assert!(out.len() < png.len(), "归一化后体积应该更小");
    }

    #[test]
    fn small_cover_is_left_untouched() {
        let small = image::RgbImage::from_pixel(64, 64, image::Rgb([10, 20, 30]));
        let mut png: Vec<u8> = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png)
            .write_image(small.as_raw(), 64, 64, image::ExtendedColorType::Rgb8)
            .expect("编码 png");

        // 已经够小：不重新编码，避免白白掉画质
        assert!(normalize_cover(&png).is_none());
    }

    #[test]
    fn broken_cover_bytes_fall_back_to_raw() {
        // 解不出来时不能让封面消失：store_cover_bytes 会退回原始字节
        let dir = temp_dir("broken_cover");
        let covers = dir.join("covers");
        let path = store_cover_bytes(&covers, &[0xFF, 0xD8, 0xFF, 0x01], "jpg")
            .expect("损坏的图也要能存下来");
        assert!(std::path::Path::new(&path).exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn sidecar_cover_prefers_cover_jpg_and_is_case_insensitive() {
        let dir = temp_dir("sidecar");
        let covers = dir.join("covers");
        fs::write(
            dir.join("album.png"),
            [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'],
        )
        .expect("写 png");
        let track = dir.join("a.mp3");
        fs::write(&track, b"not-really-audio").expect("写曲目占位");

        // 只有 album.png 时也认；命中后写进缓存目录
        let picked = sidecar_cover(&track, &covers).expect("应找到外挂封面");
        assert!(std::path::Path::new(&picked).exists(), "封面应写进缓存目录");

        // 大小写不敏感的 folder 也算，但 cover 优先
        fs::write(dir.join("Folder.JPG"), [0xFF, 0xD8, 0xFF, 0x11]).expect("写 Folder.JPG");
        let folder_only = sidecar_cover(&track, &covers).expect("应找到 Folder.JPG");
        fs::write(dir.join("cover.jpg"), [0xFF, 0xD8, 0xFF, 0x22]).expect("写 cover.jpg");
        let preferred = sidecar_cover(&track, &covers).expect("应找到 cover.jpg");
        assert_ne!(
            folder_only, preferred,
            "cover.jpg 的优先级要高于 Folder.JPG"
        );

        // 没有可用图片时返回 None，不要写到缓存目录外面去
        let empty = temp_dir("sidecar_empty");
        fs::write(empty.join("a.mp3"), b"x").expect("写曲目占位");
        assert!(sidecar_cover(&empty.join("a.mp3"), &covers).is_none());

        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&empty);
    }

    /// 同一目录的多首曲目只该扫一次封面：500 首的专辑目录若不缓存，
    /// 每首都 read_dir + 整张读图（8 MB × 500 ≈ 4 GB IO）。
    #[test]
    fn sidecar_cover_cache_spares_repeated_directory_scans() {
        let dir = temp_dir("sidecar_cache");
        let covers = dir.join("covers");
        let track = dir.join("a.mp3");
        fs::write(&track, b"x").expect("写曲目占位");
        let cover = dir.join("cover.jpg");
        fs::write(&cover, [0xFF, 0xD8, 0xFF, 0x33]).expect("写 cover.jpg");

        let cache = Mutex::new(HashMap::new());
        let first = sidecar_cover_cached(&track, &covers, &cache).expect("首次应命中");

        // 删掉原图：缓存生效时第二次仍返回同一结果，说明没有再读盘
        fs::remove_file(&cover).expect("删除原图");
        assert_eq!(
            Some(first),
            sidecar_cover_cached(&track, &covers, &cache),
            "同一目录第二次应走缓存",
        );

        // 没有封面的目录也要记下来，否则同目录每首歌都会重扫一遍
        let empty = temp_dir("sidecar_cache_empty");
        let bare = empty.join("b.mp3");
        fs::write(&bare, b"x").expect("写曲目占位");
        assert!(sidecar_cover_cached(&bare, &covers, &cache).is_none());
        assert!(
            lock_cache(&cache).contains_key(empty.as_path()),
            "空结果也应缓存"
        );

        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&empty);
    }

    #[test]
    fn cover_is_stored_once_and_deduplicated_by_content() {
        let dir = temp_dir("store");
        let data: &[u8] = b"\xFF\xD8\xFF\xE0fake-jpeg-payload";

        let with_mime =
            store_cover(&dir, &picture(data, Some(MimeType::Jpeg))).expect("应写入封面");
        // MIME 缺失时靠文件头识别，哈希相同 → 复用同一个文件
        let sniffed = store_cover(&dir, &picture(data, None)).expect("应复用封面");
        assert_eq!(with_mime, sniffed);
        assert!(with_mime.ends_with(".jpg"));
        assert_eq!(fs::read(&with_mime).expect("读取封面"), data);
        assert_eq!(
            fs::read_dir(&dir).expect("列目录").count(),
            1,
            "同内容只应落一份盘"
        );

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn unsupported_or_empty_covers_are_skipped() {
        let dir = temp_dir("skip");
        assert!(
            store_cover(&dir, &picture(b"RIFF-not-an-image", None)).is_none(),
            "无法识别的格式不应落盘"
        );
        assert!(
            store_cover(&dir, &picture(b"", Some(MimeType::Png))).is_none(),
            "空数据不应落盘"
        );

        fs::remove_dir_all(&dir).ok();
    }
}

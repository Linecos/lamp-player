//! 自定义艺术家 / 专辑封面（schema v9）。
//!
//! 扫描得到的封面是「自动」的：专辑取曲目内嵌图或旁载图，艺术家取其第一首
//! 有封面的曲目。实际使用中总有换一张的诉求——合辑被拆成好几位艺术家、
//! 内嵌图是唱片公司水印、或者单纯想用官方封面。这里允许按「艺术家名 /
//! 专辑名 + 艺术家」指定一张本地图片，导入时复制进曲库旁的 `custom_covers/`。
//!
//! **为什么不放进 `covers/`**：那个目录是扫描缓存，`prune_unused_covers` 会
//! 删掉所有没有被 `tracks.cover_path` 引用的文件。自定义封面不挂在任何曲目
//! 上，进去就会被当成残留清掉——下次打开就变回原封面，用户会以为没生效。
//!
//! 键为什么不用 `albumGroupKey`：那个键用 `\u{0}` 连接艺术家与专辑，而 SQLite
//! 的 TEXT 以 NUL 结尾，含 NUL 的字符串存进去会被截断。所以拆成 `name` +
//! `artist` 两列，艺术家记录留空 `artist`。

use crate::api::db::{covers_dir, with_conn};
use crate::scanner::store_cover_bytes;
use anyhow::{bail, Context};
use rusqlite::{params, OptionalExtension};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// 封面归属：艺术家
const KIND_ARTIST: &str = "artist";
/// 封面归属：专辑
const KIND_ALBUM: &str = "album";

/// 单张原图最大读取字节。手机直出照片约 5–10 MB，32 MB 留足余量；
/// 再大基本是误选了别的东西，读进内存也只有坏处。
const MAX_SOURCE_BYTES: u64 = 32 * 1024 * 1024;

/// 一条自定义封面记录。
pub struct CoverOverride {
    /// `artist` 或 `album`
    pub kind: String,
    /// 艺术家名（kind=artist）或专辑名（kind=album）
    pub name: String,
    /// 专辑所属的艺术家；艺术家封面为空串
    pub artist: String,
    /// `custom_covers/` 下的缓存文件绝对路径
    pub path: String,
    pub updated_at: i64,
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// 自定义封面目录：与封面缓存同级（`<支持目录>/custom_covers`）。
fn custom_covers_dir() -> anyhow::Result<PathBuf> {
    let cache = covers_dir()?;
    Ok(cache.with_file_name("custom_covers"))
}

fn check_kind(kind: &str) -> anyhow::Result<()> {
    if kind != KIND_ARTIST && kind != KIND_ALBUM {
        bail!("未知的封面类型：{kind}（只支持 artist 与 album）");
    }
    Ok(())
}

/// 规范艺术家参数：艺术家封面不吃这个字段，传什么都归零，
/// 免得同一个艺术家在库里存出两行。
fn normalize_artist(kind: &str, artist: &str) -> String {
    if kind == KIND_ALBUM {
        artist.trim().to_owned()
    } else {
        String::new()
    }
}

fn read_existing(kind: &str, name: &str, artist: &str) -> anyhow::Result<Option<String>> {
    with_conn(|conn| {
        Ok(conn
            .query_row(
                "SELECT path FROM cover_overrides \
                  WHERE kind = ?1 AND name = ?2 AND artist = ?3",
                params![kind, name, artist],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    })
}

/// 给某位艺术家 / 某张专辑指定一张本地图片作封面。
///
/// - `kind`：`artist` 或 `album`
/// - `name`：艺术家名，或专辑名
/// - `artist`：专辑所属艺术家（kind=artist 时忽略）
/// - `source_path`：用户选中的图片绝对路径
///
/// 图片会被解码校验、缩到 1024 长边、按内容哈希去重后落到 `custom_covers/`，
/// 返回缓存文件的绝对路径。同一目标重复调用就是「换一张」，旧文件顺手删掉。
pub fn set_cover_override(
    kind: String,
    name: String,
    artist: String,
    source_path: String,
) -> anyhow::Result<String> {
    check_kind(&kind)?;
    let name = name.trim().to_owned();
    if name.is_empty() {
        bail!("艺术家名 / 专辑名为空，无法指定封面");
    }
    let artist = normalize_artist(&kind, &artist);
    if kind == KIND_ALBUM && artist.is_empty() {
        // 同名专辑在不同艺术家下是两张，缺了艺术家就不知道该盖哪一张
        bail!("指定专辑封面时必须带上所属艺术家");
    }

    let source = Path::new(&source_path);
    if !source.is_file() {
        bail!("找不到图片文件：{source_path}");
    }
    let size = fs::metadata(source)?.len();
    if size == 0 {
        bail!("图片文件是空的：{source_path}");
    }
    if size > MAX_SOURCE_BYTES {
        bail!(
            "图片太大（{} MB），请选 32 MB 以内的图片",
            size / 1024 / 1024
        );
    }

    let data = fs::read(source)?;
    // 先真解一次：扩展名可以随手改，坏图存进去只会让界面一直显示占位图标，
    // 用户还找不到原因。格式也按内容认，不按扩展名——把 PNG 存成 .jpg 的
    // 情况很常见，按扩展名落盘会让后续解码失败。
    image::load_from_memory(&data).context("这个文件不是有效的图片")?;
    let extension = match image::guess_format(&data) {
        Ok(image::ImageFormat::Png) => "png",
        Ok(image::ImageFormat::Gif) => "gif",
        Ok(image::ImageFormat::WebP) => "webp",
        Ok(image::ImageFormat::Bmp) => "bmp",
        _ => "jpg",
    };

    let dir = custom_covers_dir()?;
    let stored = store_cover_bytes(&dir, &data, extension)
        .context("保存封面失败：图片格式不受支持或体积超限")?;

    let previous = read_existing(&kind, &name, &artist)?;

    with_conn(|conn| {
        conn.execute(
            "INSERT INTO cover_overrides (kind, name, artist, path, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT(kind, name, artist) \
             DO UPDATE SET path = excluded.path, updated_at = excluded.updated_at",
            params![kind, name, artist, stored, now_secs()],
        )?;
        Ok(())
    })?;

    // 换了图：旧缓存文件已经没人引用，顺手删掉，免得用户反复换图时越攒越多
    if let Some(previous) = previous {
        if previous != stored {
            let _ = fs::remove_file(&previous);
        }
    }

    Ok(stored)
}

/// 撤掉自定义封面，恢复成扫描出来的那张（艺术家回到首字母、专辑回到内嵌图）。
///
/// 返回是否真的删掉了一条记录：本来就没有自定义封面时返回 false，不算错误。
pub fn clear_cover_override(kind: String, name: String, artist: String) -> anyhow::Result<bool> {
    check_kind(&kind)?;
    let name = name.trim().to_owned();
    let artist = normalize_artist(&kind, &artist);

    let previous = read_existing(&kind, &name, &artist)?;
    let removed = with_conn(|conn| {
        Ok(conn.execute(
            "DELETE FROM cover_overrides WHERE kind = ?1 AND name = ?2 AND artist = ?3",
            params![kind, name, artist],
        )? > 0)
    })?;

    if removed {
        if let Some(path) = previous {
            let _ = fs::remove_file(&path);
        }
    }
    Ok(removed)
}

/// 列出全部自定义封面。
///
/// 缓存文件被用户手动删掉时跳过这条：数据库里还留着记录，但路径已经不
/// 存在，返回给界面只会让那张卡片一直转圈。下次重新指定会被 upsert 覆盖。
pub fn list_cover_overrides() -> anyhow::Result<Vec<CoverOverride>> {
    let rows = with_conn(|conn| {
        let mut stmt = conn.prepare_cached(
            "SELECT kind, name, artist, path, updated_at FROM cover_overrides \
             ORDER BY updated_at DESC",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(CoverOverride {
                kind: row.get(0)?,
                name: row.get(1)?,
                artist: row.get(2)?,
                path: row.get(3)?,
                updated_at: row.get(4)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;

    Ok(rows
        .into_iter()
        .filter(|item| Path::new(&item.path).is_file())
        .collect())
}

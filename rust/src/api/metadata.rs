//! 标签元数据读写：曲目右键「修改元数据」的落盘端。
//!
//! 读的是**文件标签本身**，不是曲库缓存：曲库只存标题 / 艺术家 / 专辑 / 曲目号，
//! 编辑窗要显示的年份、流派、专辑艺术家、碟号库里根本没有。写完把归一化后的值
//! 回传，调用方再用 [`crate::api::db::upsert_tracks`] 刷新库里那一条。

use anyhow::{bail, Context, Result};
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::ItemKey;
use lofty::tag::Tag;

/// 编辑窗里可改的标签字段。
///
/// 全部用字符串承载：标签里这些值本来就不保证是数字（`2003-05-01` 这种日期、
/// `03/12` 这种曲目号、`Disc 1` 这种碟号都真实存在），强行解析成数字会在保存
/// 时把内容静默丢掉一半。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrackTags {
    /// 标题；空字符串表示「标签里没有」
    pub title: String,
    pub artist: String,
    pub album: String,
    /// 专辑艺术家（合辑 / 原声带里和曲目艺术家不同）
    pub album_artist: String,
    /// 年份；`RecordingDate`，允许 `2003` 或 `2003-05-01`
    pub year: String,
    /// 曲目号；原样保存，`03/12` 这种「第 3 首，共 12 首」也照抄
    pub track_no: String,
    pub disc_no: String,
    pub genre: String,
}

/// 读取一个文件的标签。
///
/// 没有任何标签（或文件打不开）时：前者返回全空结构、后者返回错误——
/// 编辑窗需要区分「这歌没标签」与「这文件读不了」。
///
/// # Errors
/// 路径为空、文件无法解析（格式不支持 / 损坏）时返回错误。
pub fn read_track_tags(path: String) -> Result<TrackTags> {
    if path.trim().is_empty() {
        bail!("音频路径为空");
    }
    let tagged = lofty::read_from_path(&path).with_context(|| format!("解析元数据失败: {path}"))?;
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else {
        return Ok(TrackTags::default());
    };
    Ok(TrackTags {
        title: text_of(tag, ItemKey::TrackTitle),
        artist: text_of(tag, ItemKey::TrackArtist),
        album: text_of(tag, ItemKey::AlbumTitle),
        album_artist: text_of(tag, ItemKey::AlbumArtist),
        // ID3v2.4 是 TDRC（RecordingDate），老文件可能只有 TYER → Year
        year: {
            let date = text_of(tag, ItemKey::RecordingDate);
            if date.is_empty() {
                text_of(tag, ItemKey::Year)
            } else {
                date
            }
        },
        track_no: text_of(tag, ItemKey::TrackNumber),
        disc_no: text_of(tag, ItemKey::DiscNumber),
        genre: text_of(tag, ItemKey::Genre),
    })
}

/// 把字段写回文件标签，返回**写入后重新读出来**的值。
///
/// 重新读一遍是有意的：不同格式的标签对值会做归一化（数字补零、多值合并、
/// 不支持的键被丢掉），调用方拿回读的结果去刷新曲库和界面，才不会出现
/// 「界面显示 3，文件里其实是 03」这种错位。
///
/// 空字符串表示「清掉这个标签」，不会写一个空值进去。
///
/// # Errors
/// 路径为空、文件无法解析、标签格式不支持某个键、写盘失败时返回错误。
/// lofty 先写临时文件再替换，失败不会留下半截文件。
pub fn write_track_tags(path: String, tags: TrackTags) -> Result<TrackTags> {
    if path.trim().is_empty() {
        bail!("音频路径为空");
    }
    let mut tagged =
        lofty::read_from_path(&path).with_context(|| format!("解析元数据失败: {path}"))?;
    if tagged.primary_tag_mut().is_none() {
        let tag_type = tagged.primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
    }
    let tag = tagged.primary_tag_mut().context("无法为该格式创建标签")?;

    apply(tag, ItemKey::TrackTitle, &tags.title);
    apply(tag, ItemKey::TrackArtist, &tags.artist);
    apply(tag, ItemKey::AlbumTitle, &tags.album);
    apply(tag, ItemKey::AlbumArtist, &tags.album_artist);
    apply(tag, ItemKey::RecordingDate, &tags.year);
    apply(tag, ItemKey::TrackNumber, &tags.track_no);
    apply(tag, ItemKey::DiscNumber, &tags.disc_no);
    apply(tag, ItemKey::Genre, &tags.genre);

    tagged
        .save_to_path(&path, WriteOptions::default())
        .with_context(|| format!("写入标签失败: {path}"))?;

    // 标签已经落盘；重读失败不该把「写成功」变成错误，退回入参即可
    Ok(read_track_tags(path).unwrap_or(tags))
}

/// 单个键的写入：空值 → 删除该键，非空 → 覆盖
fn apply(tag: &mut Tag, key: ItemKey, value: &str) {
    let value = value.trim();
    if value.is_empty() {
        tag.remove_key(key);
    } else {
        tag.insert_text(key, value.to_string());
    }
}

/// 取某个键的文本；没有就返回空字符串（界面统一按「空 = 没填」处理）
fn text_of(tag: &Tag, key: ItemKey) -> String {
    tag.get_string(key)
        .map(str::trim)
        .unwrap_or_default()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::apply;
    use lofty::prelude::ItemKey;
    use lofty::tag::Tag;

    #[test]
    fn empty_value_removes_the_key() {
        let mut tag = Tag::new(lofty::tag::TagType::Id3v2);
        tag.insert_text(ItemKey::TrackTitle, "旧标题".to_string());
        apply(&mut tag, ItemKey::TrackTitle, "   ");
        assert_eq!(tag.get_string(ItemKey::TrackTitle), None, "空值应当删键");
    }

    #[test]
    fn value_is_trimmed_before_write() {
        let mut tag = Tag::new(lofty::tag::TagType::Id3v2);
        apply(&mut tag, ItemKey::TrackTitle, "  新标题  ");
        assert_eq!(tag.get_string(ItemKey::TrackTitle), Some("新标题"));
    }
}

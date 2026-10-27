//! ReplayGain 标签写入：多选「计算 ReplayGain」的落盘端。
//!
//! 分析在 [`crate::bass::analyze`]（EBU R128）里做，这里只负责把结果写回
//! 文件标签 `REPLAYGAIN_TRACK_GAIN`——增益跟着文件走，重新扫描和别的播放器
//! 都能读到。

use anyhow::{bail, Context, Result};
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::{ItemKey, Tag};

/// ReplayGain 增益的取值范围（dB），与扫描时的夹取范围一致
const GAIN_LIMIT: f64 = 24.0;

/// 把曲目增益写进文件标签（`REPLAYGAIN_TRACK_GAIN`，形如 `-7.23 dB`）
///
/// 已有该标签就覆盖，没有标签则新建一个主标签。写失败（文件只读、格式不支持
/// 写标签）返回错误，不会产生半截文件：lofty 先写临时文件再替换。
///
/// # Errors
/// 路径为空、增益不是有限值、文件解析失败或标签不支持 ReplayGain 时返回错误。
pub fn write_replay_gain(path: String, gain_db: f64) -> Result<()> {
    if path.is_empty() {
        bail!("音频路径为空");
    }
    if !gain_db.is_finite() {
        bail!("ReplayGain 增益必须是有限值");
    }
    let gain = gain_db.clamp(-GAIN_LIMIT, GAIN_LIMIT);

    let mut tagged =
        lofty::read_from_path(&path).with_context(|| format!("解析元数据失败: {path}"))?;
    if tagged.primary_tag_mut().is_none() {
        let tag_type = tagged.primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
    }
    let tag = tagged.primary_tag_mut().context("无法为该格式创建标签")?;
    // 有的标签类型（如部分容器的主标签）不收这个键，插不进去要报错而不是静默丢
    if !tag.insert_text(ItemKey::ReplayGainTrackGain, format!("{gain:.2} dB")) {
        bail!("该文件的标签格式不支持 ReplayGain");
    }
    tagged
        .save_to_path(&path, WriteOptions::default())
        .with_context(|| format!("写入标签失败: {path}"))?;
    Ok(())
}

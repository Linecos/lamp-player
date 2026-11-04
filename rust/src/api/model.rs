/// 曲目数据模型，flutter_rust_bridge 会自动生成对应 Dart 类
#[derive(Clone, Debug)]
pub struct Track {
    /// 文件绝对路径（唯一键）
    pub path: String,
    /// 标题（无标签时取文件名）
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    /// 时长（秒）
    pub duration_secs: f64,
    /// 专辑内曲目号
    pub track_num: Option<i32>,
    /// 入库时间戳
    pub added_at: i64,
    /// 内嵌封面的缓存文件路径；没有封面或提取失败时为空
    pub cover_path: Option<String>,
    /// ReplayGain 曲目增益（dB）；标签里没有时为 0
    pub replay_gain: f64,
}

/// 歌单摘要（列表用）；曲目通过 `collections::playlist_tracks` 单独取。
#[derive(Clone, Debug)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    /// 曲目数
    pub track_count: i32,
    /// 封面：取最新加入、且确实有封面的那首曲目的封面；空歌单或都没封面时是 None
    pub cover_path: Option<String>,
    /// 创建时间戳（Unix 秒）
    pub created_at: i64,
    /// 最近一次改名 / 增删曲目的时间戳（Unix 秒）
    pub updated_at: i64,
}

/// 听歌总览（统计页顶部）。
#[derive(Clone, Debug)]
pub struct PlayStats {
    /// 累计播放秒数；只统计 v4 之后有 `play_sessions` 记录的部分
    pub total_seconds: i64,
    /// 累计播放次数（含 v4 之前的历史）
    pub total_plays: i64,
    /// 有过播放记录的曲目数
    pub track_count: i64,
    /// 有播放记录的天数
    pub active_days: i64,
}

/// 单曲播放次数（排行榜用）。
#[derive(Clone, Debug)]
pub struct TrackPlayStat {
    pub track: Track,
    pub plays: i64,
}

/// 某位艺术家的累计播放次数（排行榜用）。
///
/// `artist` 是标签里的原始字符串：`A/B` 这种合唱标签由界面层再拆分、按人合并，
/// 拆法属于展示规则，不在 SQL 里复制一份。
#[derive(Clone, Debug)]
pub struct ArtistPlayStat {
    pub artist: String,
    pub plays: i64,
    /// 这个标签下听过多少首
    pub track_count: i64,
    /// 他播得最多的那首的封面，用来当头像；没有封面是 None
    pub cover_path: Option<String>,
}

/// 某一天的播放时长。
#[derive(Clone, Debug)]
pub struct DailyPlaytime {
    /// 本地日期，形如 `20261026`
    pub day: i32,
    pub seconds: i64,
}

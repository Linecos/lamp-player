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
}

import '../../rust/api/collections.dart' as collections;
import '../../rust/api/model.dart';

/// 听歌统计数据源。
///
/// 抽接口只为测试不依赖原生库；生产路径永远走 [RustListeningStatsRepository]。
abstract interface class ListeningStatsRepository {
  /// 总览：累计时长 / 次数 / 曲目数 / 活跃天数
  Future<PlayStats> playStats();

  /// 播放次数排行，最多 100 首
  Future<List<TrackPlayStat>> topTracks({int limit = 100});

  /// 自 [sinceDay]（`yyyyMMdd`）起每天的播放秒数，只含有记录的天
  Future<List<DailyPlaytime>> dailyPlaytime(int sinceDay);
}

class RustListeningStatsRepository implements ListeningStatsRepository {
  const RustListeningStatsRepository();

  @override
  Future<PlayStats> playStats() => collections.playStats();

  @override
  Future<List<TrackPlayStat>> topTracks({int limit = 100}) =>
      collections.topTracks(limit: limit);

  @override
  Future<List<DailyPlaytime>> dailyPlaytime(int sinceDay) =>
      collections.dailyPlaytime(sinceDay: sinceDay);
}

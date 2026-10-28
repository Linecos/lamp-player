import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/common.dart';
import '../../rust/api/model.dart';
import 'listening_stats_repository.dart';

/// 听歌统计：累计时长、播放次数排行、每日热力图。
///
/// 时长与热力图只统计有 `play_sessions` 记录的部分（schema v4 之后），
/// 次数沿用 `play_history.play_count`，包含更早的历史。
class ListeningStatsPage extends StatefulWidget {
  const ListeningStatsPage({super.key, this.repository});

  /// 数据源；不传则走 Rust，测试注入假实现。
  final ListeningStatsRepository? repository;

  @override
  State<ListeningStatsPage> createState() => _ListeningStatsPageState();
}

class _ListeningStatsPageState extends State<ListeningStatsPage> {
  /// 热力图覆盖的周数（GitHub 风格约半年）
  static const int _weeks = 26;

  late final ListeningStatsRepository _repository =
      widget.repository ?? const RustListeningStatsRepository();
  late Future<_StatsBundle> _future = _load();

  Future<_StatsBundle> _load() async {
    final DateTime start = _heatmapStart(DateTime.now(), _weeks);
    // 三个查询互不依赖，并行发起；用 record 的 wait 保证任一失败都会被捕获，
    // 不会留下未 await 的 future 变成 unhandled error。
    final (
      PlayStats stats,
      List<TrackPlayStat> top,
      List<DailyPlaytime> daily,
    ) = await (
      _repository.playStats(),
      _repository.topTracks(),
      _repository.dailyPlaytime(_dayKey(start)),
    ).wait;
    return _StatsBundle(stats: stats, top: top, daily: daily);
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      appBar: AppBar(
        // 默认 BackButton 只有 48×48，改成 56 更好点；图标与位置不变
        leading: IconButton(
          key: const ValueKey<String>('stats-back'),
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 56, height: 56),
        ),
        leadingWidth: 56,
        title: const Text('听歌统计'),
        backgroundColor: scheme.surfaceContainerLow,
      ),
      body: FutureBuilder<_StatsBundle>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<_StatsBundle> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingState(message: '正在统计…');
          }
          if (snapshot.hasError) {
            return ErrorRetry(
              title: '统计读取失败',
              error: snapshot.error!,
              onRetry: _reload,
            );
          }
          final _StatsBundle bundle = snapshot.data!;
          return _buildBody(context, bundle);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, _StatsBundle bundle) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(child: _overview(context, bundle.stats)),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: _heatmapCard(context, bundle.daily),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Text(
                  '播放排行',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '最多 100 首',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (bundle.top.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: EmptyState(
                icon: Icons.bar_chart,
                title: '还没有播放记录',
                message: '播放几首歌之后，这里会按次数排出你最常听的曲目。',
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: bundle.top.length,
            itemBuilder: (BuildContext context, int index) =>
                _RankRow(rank: index + 1, stat: bundle.top[index]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _overview(BuildContext context, PlayStats stats) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '累计听歌',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _formatSpan(stats.totalSeconds),
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              _Metric(label: '播放次数', value: '${stats.totalPlays}'),
              _Metric(label: '听过曲目', value: '${stats.trackCount} 首'),
              _Metric(label: '活跃天数', value: '${stats.activeDays} 天'),
            ],
          ),
          if (stats.totalSeconds == 0) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '时长与热力图从本版本开始统计，之前的播放只计次数。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _heatmapCard(BuildContext context, List<DailyPlaytime> daily) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Map<int, int> byDay = <int, int>{
      for (final DailyPlaytime item in daily) item.day: item.seconds,
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '每日播放时长',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '近 $_weeks 周',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _Heatmap(byDay: byDay, weeks: _weeks),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Text(
                '少',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              for (int level = 0; level <= 4; level += 1) ...<Widget>[
                _HeatCell(color: _heatColor(scheme, level)),
                const SizedBox(width: 3),
              ],
              const SizedBox(width: 3),
              Text(
                '多',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatsBundle {
  const _StatsBundle({
    required this.stats,
    required this.top,
    required this.daily,
  });

  final PlayStats stats;
  final List<TrackPlayStat> top;
  final List<DailyPlaytime> daily;
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// GitHub 贡献图风格：每列一周，从上到下周一 → 周日。
class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.byDay, required this.weeks});

  final Map<int, int> byDay;
  final int weeks;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DateTime today = DateTime.now();
    final DateTime start = _heatmapStart(today, weeks);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int week = 0; week < weeks; week += 1)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Column(
              children: <Widget>[
                for (int weekday = 0; weekday < 7; weekday += 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: _dayCell(
                      scheme,
                      start.add(Duration(days: week * 7 + weekday)),
                      today,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dayCell(ColorScheme scheme, DateTime date, DateTime today) {
    if (date.isAfter(today)) {
      return const SizedBox(width: 12, height: 12);
    }
    final int seconds = byDay[_dayKey(date)] ?? 0;
    return Tooltip(
      message: '${date.month} 月 ${date.day} 日 · ${_formatSpan(seconds)}',
      waitDuration: const Duration(milliseconds: 400),
      child: _HeatCell(color: _heatColor(scheme, _heatLevel(seconds))),
    );
  }
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({required this.rank, required this.stat});

  final int rank;
  final TrackPlayStat stat;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track track = stat.track;
    final bool top3 = rank <= 3;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: top3 ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: top3 ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AlbumCover(path: track.coverPath, size: 40, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    Text(
                      _subtitleOf(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${stat.plays} 次',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitleOf(Track track) {
    final String artist = track.artist ?? '未知艺术家';
    final String? album = track.album;
    return album == null ? artist : '$artist · $album';
  }
}

/// `yyyyMMdd` 整数；与 Rust 侧 `play_sessions.day` 保持同一编码。
int _dayKey(DateTime date) => date.year * 10000 + date.month * 100 + date.day;

DateTime _weekStart(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

/// 热力图第一格：本周一往前推 `weeks - 1` 周，保证最后一列就是本周（含今天）。
DateTime _heatmapStart(DateTime today, int weeks) =>
    _weekStart(today).subtract(Duration(days: (weeks - 1) * 7));

/// 0 表示没有播放；1..4 按累计时长分级（<15 分钟 / <1 小时 / <2 小时 / 更多）。
int _heatLevel(int seconds) {
  if (seconds <= 0) {
    return 0;
  }
  if (seconds < 15 * 60) {
    return 1;
  }
  if (seconds < 60 * 60) {
    return 2;
  }
  if (seconds < 2 * 60 * 60) {
    return 3;
  }
  return 4;
}

Color _heatColor(ColorScheme scheme, int level) {
  return switch (level) {
    <= 0 => scheme.surfaceContainerHighest,
    1 => scheme.primary.withValues(alpha: 0.25),
    2 => scheme.primary.withValues(alpha: 0.45),
    3 => scheme.primary.withValues(alpha: 0.7),
    _ => scheme.primary,
  };
}

String _formatSpan(int seconds) {
  if (seconds <= 0) {
    return '0 分钟';
  }
  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  if (hours <= 0) {
    return '$minutes 分钟';
  }
  return minutes > 0 ? '$hours 小时 $minutes 分钟' : '$hours 小时';
}

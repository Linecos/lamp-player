import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/common.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart' show splitArtistTag;
import 'listening_stats_repository.dart';

/// 听歌统计：累计时长、播放次数排行、每日热力图。
///
/// 时长与热力图只统计有 `play_sessions` 记录的部分（schema v4 之后），
/// 次数沿用 `play_history.play_count`，包含更早的历史。
class ListeningStatsPage extends StatefulWidget {
  const ListeningStatsPage({
    super.key,
    this.repository,
    this.onPlayTrack,
    this.onOpenArtist,
  });

  /// 数据源；不传则走 Rust，测试注入假实现。
  final ListeningStatsRepository? repository;

  /// 点排行里的歌：整份榜单当播放队列传出去，点了哪首就从哪首开始
  final void Function(List<Track> queue, Track track)? onPlayTrack;

  /// 点排行里的艺术家（已拆好的单个名字）：跳到曲库的艺术家详情
  final ValueChanged<String>? onOpenArtist;

  @override
  State<ListeningStatsPage> createState() => _ListeningStatsPageState();
}

class _ListeningStatsPageState extends State<ListeningStatsPage> {
  /// 一次取满一年：热力图显示多少周由窗口宽度决定，改窗口不必重新查库
  /// （一年也就 371 行，代价可以忽略）
  static const int _maxWeeks = 53;

  late final ListeningStatsRepository _repository =
      widget.repository ?? const RustListeningStatsRepository();
  late Future<_StatsBundle> _future = _load();

  /// 下半部分看哪一套排行
  RankTab _tab = RankTab.songs;

  Future<_StatsBundle> _load() async {
    final DateTime start = _heatmapStart(DateTime.now(), _maxWeeks);
    // 三个查询互不依赖，并行发起；用 record 的 wait 保证任一失败都会被捕获，
    // 不会留下未 await 的 future 变成 unhandled error。
    final (
      PlayStats stats,
      List<TrackPlayStat> top,
      List<ArtistPlayStat> artists,
      List<DailyPlaytime> daily,
    ) = await (
      _repository.playStats(),
      _repository.topTracks(),
      _repository.topArtists(),
      _repository.dailyPlaytime(_dayKey(start)),
    ).wait;
    return _StatsBundle(stats: stats, top: top, artists: artists, daily: daily);
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

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 宽窗口把总览与热力图并排：热力图能铺满一整年，页面也不会被拉成
        // 一条长卷；窄窗口仍上下堆叠
        final bool sideBySide = constraints.maxWidth >= 1040;
        // 卡片内宽：页面左右 16 内边距，卡片自身左右 20 内边距
        const double pagePadding = 32;
        const double cardPadding = 40;
        final double heatmapWidth = sideBySide
            ? constraints.maxWidth - pagePadding - 340 - 16 - cardPadding
            : constraints.maxWidth - pagePadding - cardPadding;
        final Widget overview = _overview(context, bundle.stats, bundle.daily);
        final Widget heatmap = _heatmapCard(
          context,
          bundle.daily,
          width: heatmapWidth,
          // 并排时把卡片撑到和左边一样高，两张卡底边才对齐；否则热力图下方
          // 会空出一块，只有格子放大到 18 的全屏才凑巧接近
          fill: sideBySide,
        );
        final Widget head = sideBySide
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(width: 340, child: overview),
                    const SizedBox(width: 16),
                    Expanded(child: heatmap),
                  ],
                ),
              )
            : Column(
                children: <Widget>[
                  overview,
                  const SizedBox(height: 16),
                  heatmap,
                ],
              );

        return CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(child: head),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: <Widget>[
                    _RankTabs(
                      selected: _tab,
                      onChanged: (RankTab tab) => setState(() => _tab = tab),
                    ),
                    const Spacer(),
                    Text(
                      _tab == RankTab.songs ? '最多 100 首' : '最多 100 位',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ..._rankingSlivers(bundle),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  /// 排行榜的两套列表：常听歌曲 / 常听艺术家
  List<Widget> _rankingSlivers(_StatsBundle bundle) {
    if (_tab == RankTab.songs) {
      if (bundle.top.isEmpty) {
        return <Widget>[
          _emptyRank(
            icon: Icons.bar_chart,
            title: '还没有播放记录',
            message: '播放几首歌之后，这里会按次数排出你最常听的曲目。',
          ),
        ];
      }
      final int most = _maxPlays(
        bundle.top.map((TrackPlayStat stat) => stat.plays.toInt()),
      );
      return <Widget>[
        SliverList.builder(
          itemCount: bundle.top.length,
          itemBuilder: (BuildContext context, int index) {
            final TrackPlayStat stat = bundle.top[index];
            return _RankRow(
              key: ValueKey<String>('rank-song-${stat.track.path}'),
              rank: index + 1,
              stat: stat,
              maxPlays: most,
              // 点一行就播这首，队列是整份榜单：接着往下听到的就是榜上下一首
              onTap: widget.onPlayTrack == null
                  ? null
                  : () => widget.onPlayTrack!(<Track>[
                      for (final TrackPlayStat item in bundle.top) item.track,
                    ], stat.track),
            );
          },
        ),
      ];
    }

    final List<_ArtistEntry> artists = _mergeArtists(bundle.artists);
    if (artists.isEmpty) {
      return <Widget>[
        _emptyRank(
          icon: Icons.person_outline,
          title: '还没有艺术家记录',
          message: '播放几首歌之后，这里会按艺术家排出你听得最多的名单。',
        ),
      ];
    }
    final int most = _maxPlays(
      artists.map((_ArtistEntry entry) => entry.plays),
    );
    return <Widget>[
      SliverList.builder(
        itemCount: artists.length,
        itemBuilder: (BuildContext context, int index) {
          final _ArtistEntry entry = artists[index];
          return _ArtistRankRow(
            key: ValueKey<String>('rank-artist-${entry.name}'),
            rank: index + 1,
            entry: entry,
            maxPlays: most,
            onTap: widget.onOpenArtist == null
                ? null
                : () => widget.onOpenArtist!(entry.name),
          );
        },
      ),
    ];
  }

  static Widget _emptyRank({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: EmptyState(icon: icon, title: title, message: message),
      ),
    );
  }

  /// 把 SQL 的「标签原样」拆开、按人合并。
  ///
  /// 合唱曲（`A/B`）的播放次数会同时计入两位，和曲库「艺术家」分区的口径一致；
  /// 封面取他播放最多的那张（raw 已按次数倒序，第一次见到即最能代表）。
  static List<_ArtistEntry> _mergeArtists(List<ArtistPlayStat> raw) {
    final Map<String, _ArtistEntry> byName = <String, _ArtistEntry>{};
    for (final ArtistPlayStat stat in raw) {
      // 空字符串是「没有封面」，交出去会让后面的候选盖不上
      final String? cover = (stat.coverPath ?? '').isEmpty
          ? null
          : stat.coverPath;
      for (final String name in splitArtistTag(stat.artist)) {
        final _ArtistEntry? existing = byName[name];
        if (existing == null) {
          byName[name] = _ArtistEntry(
            name: name,
            plays: stat.plays.toInt(),
            trackCount: stat.trackCount.toInt(),
            coverPath: cover,
          );
        } else {
          existing.plays += stat.plays.toInt();
          existing.trackCount += stat.trackCount.toInt();
          existing.coverPath ??= cover;
        }
      }
    }
    final List<_ArtistEntry> merged = byName.values.toList()
      ..sort((_ArtistEntry a, _ArtistEntry b) => b.plays.compareTo(a.plays));
    return merged.take(100).toList();
  }

  static int _maxPlays(Iterable<int> values) {
    int most = 1;
    for (final int plays in values) {
      if (plays > most) {
        most = plays;
      }
    }
    return most;
  }

  Widget _overview(
    BuildContext context,
    PlayStats stats,
    List<DailyPlaytime> daily,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final _Recent recent = _recentOf(daily);

    return Container(
      key: const ValueKey<String>('stats-overview'),
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
          // 并排布局里这一栏只有 340 宽，'1234 小时 56 分钟' 这种量级会顶出去；
          // 缩放而不是省略号：数字被截掉比小一号更糟
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _formatSpan(stats.totalSeconds),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              _Metric(label: '播放次数', value: '${stats.totalPlays}'),
              _MetricDivider(color: scheme.outlineVariant),
              _Metric(label: '听过曲目', value: '${stats.trackCount} 首'),
              _MetricDivider(color: scheme.outlineVariant),
              _Metric(label: '活跃天数', value: '${stats.activeDays} 天'),
            ],
          ),
          if (recent.hasData) ...<Widget>[
            const SizedBox(height: 16),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                _Metric(
                  label: '本周',
                  value: _formatCompactSpan(recent.weekSeconds),
                ),
                _MetricDivider(color: scheme.outlineVariant),
                _Metric(
                  label: '本月',
                  value: _formatCompactSpan(recent.monthSeconds),
                ),
                _MetricDivider(color: scheme.outlineVariant),
                _Metric(label: '连续听歌', value: '${recent.streakDays} 天'),
              ],
            ),
          ],
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

  Widget _heatmapCard(
    BuildContext context,
    List<DailyPlaytime> daily, {
    required double width,
    required bool fill,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Map<int, int> byDay = <int, int>{
      for (final DailyPlaytime item in daily) item.day: item.seconds,
    };

    // 周几标签列（26 + 6）要先扣掉，剩下才是网格能用的宽度
    final double gridWidth = width - _weekdayColumnWidth;
    // 格子 12 + 间距 3：宽度能放多少周就显示多少周，最多一年。
    // 固定 26 周的时候，1280 窗口下一整张卡片只有左边三分之一有内容
    final int weeks = ((gridWidth + 3) / 15).floor().clamp(13, _maxWeeks);
    // 周数已经顶到一年还没占满宽度（超宽窗口）：把格子放大到 18，
    // 否则右边会留出一大片和左边不对称的空白
    final double cell = weeks == _maxWeeks
        ? ((gridWidth + 3) / weeks - 3).clamp(12.0, 18.0)
        : 12;

    return Container(
      key: const ValueKey<String>('stats-heatmap'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Builder(
        builder: (BuildContext context) {
          int bestSeconds = 0;
          int bestDay = 0;
          byDay.forEach((int day, int seconds) {
            if (seconds > bestSeconds) {
              bestSeconds = seconds;
              bestDay = day;
            }
          });
          final DateTime bestDate = DateTime(
            bestDay ~/ 10000,
            (bestDay ~/ 100) % 100,
            bestDay % 100,
          );

          return Column(
            mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
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
                  const SizedBox(width: 8),
                  Text(
                    weeks >= 52 ? '近一年' : '近 $weeks 周',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  // 图例紧跟着搬进标题行：原来它独自挂在卡片右下角，
                  // 卡片一宽就跟热力图离得很远，看不出是同一个东西的图例
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
              const SizedBox(height: 14),
              // 和左边的总览卡等高时，把网格 + 脚注当成一块在剩余高度里居中：
              // 余量全部堆在两处之一（贴着标题或贴着底边）都像是漏排了
              if (fill)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _heatGrid(byDay, weeks, cell),
                        if (bestSeconds > 0)
                          _bestDayLine(bestSeconds, bestDate),
                      ],
                    ),
                  ),
                )
              else ...<Widget>[
                _heatGrid(byDay, weeks, cell),
                if (bestSeconds > 0) _bestDayLine(bestSeconds, bestDate),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 网格本体（可横向滚动）：周几 / 月份轴在 `_Heatmap` 里
Widget _heatGrid(Map<int, int> byDay, int weeks, double cell) {
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: _Heatmap(byDay: byDay, weeks: weeks, cell: cell),
  );
}

/// 「最长的一天」脚注：跟着网格走，不单独贴到卡片底边
Widget _bestDayLine(int bestSeconds, DateTime bestDate) {
  return Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Builder(
      builder: (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        return Text(
          '最长的一天：${_formatSpan(bestSeconds)}'
          '（${bestDate.month} 月 ${bestDate.day} 日）',
          key: const ValueKey<String>('stats-best-day'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
      },
    ),
  );
}

/// 近 7 天 / 本月 / 连续天数：全部由热力图那份日数据算，不必再查库
class _Recent {
  const _Recent({
    required this.weekSeconds,
    required this.monthSeconds,
    required this.streakDays,
  });

  final int weekSeconds;
  final int monthSeconds;
  final int streakDays;

  bool get hasData => weekSeconds > 0 || monthSeconds > 0 || streakDays > 0;
}

/// 分隔线：三个指标被 Expanded 均分到整行，不画线时宽窗口下会显得散
class _MetricDivider extends StatelessWidget {
  const _MetricDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 30,
      margin: const EdgeInsets.only(right: 16),
      color: color.withValues(alpha: 0.7),
    );
  }
}

class _StatsBundle {
  const _StatsBundle({
    required this.stats,
    required this.top,
    required this.artists,
    required this.daily,
  });

  final PlayStats stats;
  final List<TrackPlayStat> top;
  final List<ArtistPlayStat> artists;
  final List<DailyPlaytime> daily;
}

/// 合并后的艺术家排行项（一行）
class _ArtistEntry {
  _ArtistEntry({
    required this.name,
    required this.plays,
    required this.trackCount,
    this.coverPath,
  });

  final String name;
  int plays;
  int trackCount;
  String? coverPath;
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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

/// GitHub 贡献图风格：每列一周，从上到下周一 → 周日；顶部标月份，左侧标周几。
class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.byDay, required this.weeks, this.cell = 12});

  final Map<int, int> byDay;
  final int weeks;

  /// 单格边长：宽窗口下会放大，免得右侧空一片
  final double cell;

  /// 格子间距
  static const double _gap = 3;

  /// 月份行高度：左侧周几标签要空出这一段，才能和网格首行对齐
  static const double _monthRowHeight = 18;

  /// 周几只标一 / 三 / 五，与 GitHub 一致；空串占位保持七行等高
  static const List<String> _weekdays = <String>['一', '', '三', '', '五', '', ''];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime today = DateTime.now();
    final DateTime start = _heatmapStart(today, weeks);
    final double step = cell + _gap;
    final double gridWidth = weeks * step - _gap;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: _monthRowHeight),
          child: Column(
            children: <Widget>[
              for (int weekday = 0; weekday < 7; weekday += 1)
                SizedBox(
                  width: _weekdayColumnWidth - 6,
                  height: step,
                  child: Text(
                    _weekdays[weekday],
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: gridWidth,
              height: _monthRowHeight,
              child: Stack(
                children: _monthLabels(start, step, gridWidth, theme, scheme),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int week = 0; week < weeks; week += 1)
                  Padding(
                    padding: const EdgeInsets.only(right: _gap),
                    child: Column(
                      children: <Widget>[
                        for (int weekday = 0; weekday < 7; weekday += 1)
                          Padding(
                            padding: const EdgeInsets.only(bottom: _gap),
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
            ),
          ],
        ),
      ],
    );
  }

  /// 月份标签：只在换月的那一列挂一个，贴到右边缘放不下就跳过。
  ///
  /// 第一列不标——它通常是上月延续下来的半截，「11 月」挂在两周前的位置
  /// 反而误导。
  List<Widget> _monthLabels(
    DateTime start,
    double step,
    double gridWidth,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    const double labelWidth = 40;
    final List<Widget> labels = <Widget>[];
    int lastMonth = start.month;
    for (int week = 1; week < weeks; week += 1) {
      final DateTime monday = start.add(Duration(days: week * 7));
      if (monday.month == lastMonth) {
        continue;
      }
      lastMonth = monday.month;
      if (step * week > gridWidth - labelWidth) {
        continue;
      }
      labels.add(
        Positioned(
          left: step * week,
          top: 0,
          child: Text(
            '${monday.month} 月',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return labels;
  }

  Widget _dayCell(ColorScheme scheme, DateTime date, DateTime today) {
    if (date.isAfter(today)) {
      return SizedBox(width: cell, height: cell);
    }
    final int seconds = byDay[_dayKey(date)] ?? 0;
    return Tooltip(
      message: '${date.month} 月 ${date.day} 日 · ${_formatSpan(seconds)}',
      waitDuration: const Duration(milliseconds: 400),
      child: _HeatCell(
        color: _heatColor(scheme, _heatLevel(seconds)),
        size: cell,
      ),
    );
  }
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({required this.color, this.size = 12});

  final Color color;

  /// 边长：图例固定 12，网格跟着窗口宽度放大
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size / 4),
      ),
    );
  }
}

/// 排行榜的两套视图
enum RankTab {
  songs('常听歌曲', Icons.library_music_outlined),
  artists('常听艺术家', Icons.person_outline);

  const RankTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 分段切换：外框一个圆角胶囊，选中那段描边 + 主题色底
class _RankTabs extends StatelessWidget {
  const _RankTabs({required this.selected, required this.onChanged});

  final RankTab selected;
  final ValueChanged<RankTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        // 用比页面底色亮一档的「轨道」色：只靠描边的话，未选中那段在深色
        // 主题下几乎看不见，整块读起来像只有一个按钮
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final RankTab tab in RankTab.values) _tab(context, tab),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, RankTab tab) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool active = tab == selected;
    final Color foreground = active ? scheme.primary : scheme.onSurfaceVariant;

    return InkWell(
      key: ValueKey<String>('rank-tab-${tab.name}'),
      borderRadius: BorderRadius.circular(11),
      onTap: active ? null : () => onChanged(tab),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? scheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: active
                ? scheme.primary.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(tab.icon, size: 16, color: foreground),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: foreground,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 排行行：序号 + 头像 + 标题/副标题 + 次数，背后一条占比条。
///
/// 歌曲和艺术家只差头像形状与副标题，其余共用，免得两份排版各改各的。
class _RankTile extends StatelessWidget {
  const _RankTile({
    required this.rank,
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.plays,
    required this.maxPlays,
    this.onTap,
  });

  final int rank;
  final Widget avatar;
  final String title;
  final String subtitle;

  /// 这一行自己的播放次数与榜首的次数（用来算占比条）
  final int plays;
  final int maxPlays;

  /// 点这一行做什么；为空时整行不可点（测试里不注入回调）
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool top3 = rank <= 3;
    final double share = (plays / maxPlays).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: <Widget>[
            // 占比条：一眼看出这行比下面多听了多少，也把宽窗口下右侧那一大片
            // 空白填上（原来只有一个小「N 次」孤零零飘在右边缘）
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: share,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            Padding(
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
                  avatar,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge,
                        ),
                        Text(
                          subtitle,
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
                  SizedBox(
                    width: 76,
                    child: Text(
                      '$plays 次',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 墨水层铺在最上面：占比条画在内容之下，InkWell 放更深处的话
            // 悬停高亮会被那条背景挡住
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(14),
                  hoverColor: scheme.onSurface.withValues(alpha: 0.06),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    super.key,
    required this.rank,
    required this.stat,
    required this.maxPlays,
    this.onTap,
  });

  final int rank;
  final TrackPlayStat stat;

  /// 榜首的播放次数：用来算每行的占比条长度
  final int maxPlays;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Track track = stat.track;
    return _RankTile(
      rank: rank,
      avatar: AlbumCover(path: track.coverPath, size: 40, radius: 12),
      title: track.title,
      subtitle: _subtitleOf(track),
      plays: stat.plays.toInt(),
      maxPlays: maxPlays,
      onTap: onTap,
    );
  }

  static String _subtitleOf(Track track) {
    final String artist = track.artist ?? '未知艺术家';
    final String? album = track.album;
    return album == null ? artist : '$artist · $album';
  }
}

class _ArtistRankRow extends StatelessWidget {
  const _ArtistRankRow({
    super.key,
    required this.rank,
    required this.entry,
    required this.maxPlays,
    this.onTap,
  });

  final int rank;
  final _ArtistEntry entry;
  final int maxPlays;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _RankTile(
      rank: rank,
      // 头像用他播得最多的那张封面，裁成圆的：一排方形专辑图里，圆形一眼
      // 就能区分「这是人不是歌」
      avatar: ClipOval(
        child: AlbumCover(path: entry.coverPath, size: 40, radius: 20),
      ),
      title: entry.name,
      subtitle: '听过 ${entry.trackCount} 首',
      plays: entry.plays,
      maxPlays: maxPlays,
      onTap: onTap,
    );
  }
}

/// 左侧周几标签列的总宽（标签 26 + 与网格的 6 间距）
const double _weekdayColumnWidth = 32;

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

/// 最近 7 天 / 本月 / 连续天数，全部由热力图那份日数据算出来，不再查库。
///
/// 连续天数从今天往前数；今天还没听就从昨天开始数（否则上午打开统计，
/// 昨天攒的连续记录会显示成 0）。
_Recent _recentOf(List<DailyPlaytime> daily) {
  final Map<int, int> byDay = <int, int>{
    for (final DailyPlaytime item in daily) item.day: item.seconds,
  };
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);

  int week = 0;
  for (int back = 0; back < 7; back += 1) {
    week += byDay[_dayKey(today.subtract(Duration(days: back)))] ?? 0;
  }

  final int monthKey = now.year * 100 + now.month;
  int month = 0;
  byDay.forEach((int day, int seconds) {
    if (day ~/ 100 == monthKey) {
      month += seconds;
    }
  });

  int streak = 0;
  DateTime cursor = today;
  if ((byDay[_dayKey(cursor)] ?? 0) <= 0) {
    cursor = cursor.subtract(const Duration(days: 1));
  }
  while ((byDay[_dayKey(cursor)] ?? 0) > 0) {
    streak += 1;
    cursor = cursor.subtract(const Duration(days: 1));
    if (streak > 3650) {
      break;
    }
  }

  return _Recent(weekSeconds: week, monthSeconds: month, streakDays: streak);
}

/// 指标格里的小时长：带分钟的全写会撑破一列（'12 小时 34 分钟'），
/// 这里只留一位小数，够看出量级
String _formatCompactSpan(int seconds) {
  if (seconds <= 0) {
    return '0 分钟';
  }
  if (seconds < 3600) {
    return '${(seconds / 60).round()} 分钟';
  }
  final double hours = seconds / 3600;
  final String text = hours >= 10
      ? hours.round().toString()
      : hours.toStringAsFixed(1);
  final String trimmed = text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text;
  return '$trimmed 小时';
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

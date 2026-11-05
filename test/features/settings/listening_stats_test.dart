import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/settings/listening_stats_view.dart';
import 'package:lamp_player/src/features/settings/listening_stats_repository.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

class _FakeStatsRepository implements ListeningStatsRepository {
  _FakeStatsRepository({
    this.stats = const PlayStats(
      totalSeconds: 0,
      totalPlays: 0,
      trackCount: 0,
      activeDays: 0,
    ),
    this.top = const <TrackPlayStat>[],
    this.artists = const <ArtistPlayStat>[],
    this.daily = const <DailyPlaytime>[],
    this.error,
  });

  PlayStats stats;
  List<TrackPlayStat> top;
  List<ArtistPlayStat> artists;
  List<DailyPlaytime> daily;
  Object? error;

  int loadCalls = 0;
  int? lastSinceDay;

  @override
  Future<PlayStats> playStats() async {
    loadCalls += 1;
    if (error != null) {
      throw error!;
    }
    return stats;
  }

  @override
  Future<List<TrackPlayStat>> topTracks({int limit = 100}) async {
    if (error != null) {
      throw error!;
    }
    return top;
  }

  @override
  Future<List<ArtistPlayStat>> topArtists({int limit = 100}) async {
    if (error != null) {
      throw error!;
    }
    return artists;
  }

  @override
  Future<List<DailyPlaytime>> dailyPlaytime(int sinceDay) async {
    lastSinceDay = sinceDay;
    if (error != null) {
      throw error!;
    }
    return daily;
  }
}

Future<void> _pump(
  WidgetTester tester,
  ListeningStatsRepository repository, {
  Size size = const Size(900, 1200),
  void Function(List<Track> queue, Track track)? onPlayTrack,
  ValueChanged<String>? onOpenArtist,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: ListeningStatsView(
          repository: repository,
          onPlayTrack: onPlayTrack,
          onOpenArtist: onOpenArtist,
          onBack: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

int _dayKey(DateTime date) => date.year * 10000 + date.month * 100 + date.day;

void main() {
  testWidgets('展示累计时长、指标与播放排行', (WidgetTester tester) async {
    final _FakeStatsRepository repository = _FakeStatsRepository(
      stats: const PlayStats(
        totalSeconds: 45240,
        totalPlays: 128,
        trackCount: 42,
        activeDays: 17,
      ),
      top: <TrackPlayStat>[
        TrackPlayStat(track: sampleTrack(title: '夜航'), plays: 12),
        TrackPlayStat(track: sampleTrack(title: '潮汐'), plays: 7),
      ],
    );

    await _pump(tester, repository);

    expect(find.text('听歌统计'), findsOneWidget);
    expect(find.text('12 小时 34 分钟'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
    expect(find.text('42 首'), findsOneWidget);
    expect(find.text('17 天'), findsOneWidget);

    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('12 次'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);
    expect(find.text('7 次'), findsOneWidget);
    expect(
      find.byType(AlbumCover),
      findsNWidgets(2),
      reason: '每一行都带封面（没有封面时回退图标）',
    );
    // 排名序号
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('没有时长数据时提示只统计本版本之后', (WidgetTester tester) async {
    final _FakeStatsRepository repository = _FakeStatsRepository(
      stats: const PlayStats(
        totalSeconds: 0,
        totalPlays: 5,
        trackCount: 3,
        activeDays: 0,
      ),
    );

    await _pump(tester, repository);

    expect(find.text('0 分钟'), findsOneWidget);
    expect(find.textContaining('从本版本开始统计'), findsOneWidget);
    expect(find.text('还没有播放记录'), findsOneWidget);
  });

  testWidgets('热力图按天取数并渲染格子', (WidgetTester tester) async {
    final DateTime today = DateTime.now();
    final _FakeStatsRepository repository = _FakeStatsRepository(
      daily: <DailyPlaytime>[
        DailyPlaytime(day: _dayKey(today), seconds: 3600),
        DailyPlaytime(
          day: _dayKey(today.subtract(const Duration(days: 1))),
          seconds: 60,
        ),
      ],
    );

    await _pump(tester, repository);

    expect(find.text('每日播放时长'), findsOneWidget);
    // 900 宽下能放下 53 周（一年），超过就别再拉长了
    expect(find.text('近一年'), findsOneWidget);
    expect(repository.lastSinceDay, isNotNull);
    expect(
      repository.lastSinceDay!,
      lessThan(_dayKey(today.subtract(const Duration(days: 350)))),
      reason: '一次取满一年，改窗口宽度不必重新查库',
    );
    expect(
      repository.lastSinceDay!,
      lessThanOrEqualTo(_dayKey(today)),
      reason: '起始日期不能晚于今天',
    );
    // 有数据的当天带时长提示
    expect(
      find.byTooltip('${today.month} 月 ${today.day} 日 · 1 小时'),
      findsOneWidget,
    );
  });

  testWidgets('读取失败展示重试，重试后恢复', (WidgetTester tester) async {
    final _FakeStatsRepository repository = _FakeStatsRepository(
      stats: const PlayStats(
        totalSeconds: 600,
        totalPlays: 2,
        trackCount: 1,
        activeDays: 1,
      ),
      error: StateError('数据库忙'),
    );

    await _pump(tester, repository);

    expect(find.text('统计读取失败'), findsOneWidget);

    repository.error = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('10 分钟'), findsOneWidget);
  });

  testWidgets('近期指标由热力图那份日数据算出，不再查库', (WidgetTester tester) async {
    final DateTime today = DateTime.now();
    final _FakeStatsRepository repository = _FakeStatsRepository(
      daily: <DailyPlaytime>[
        DailyPlaytime(day: _dayKey(today), seconds: 3600),
        DailyPlaytime(
          day: _dayKey(today.subtract(const Duration(days: 1))),
          seconds: 1800,
        ),
        DailyPlaytime(
          day: _dayKey(today.subtract(const Duration(days: 2))),
          seconds: 600,
        ),
      ],
    );

    await _pump(tester, repository);

    // 按 key 取值再比：'本周' 和 '本月' 在月初可能刚好相等，用文本唯一性
    // 断言会在跨月那几天偶发失败
    String metricValue(String key) {
      final Finder metric = find.byKey(ValueKey<String>(key));
      return tester
          .widget<Text>(
            find.descendant(of: metric, matching: find.byType(Text)).first,
          )
          .data!;
    }

    expect(metricValue('stats-week'), '1.7 小时', reason: '近 7 天合计 6000 秒');
    expect(metricValue('stats-streak'), '3 天', reason: '今天起连听三天');
    expect(find.text('本周'), findsOneWidget);
    expect(find.text('本月'), findsOneWidget);
    expect(find.text('连续听歌'), findsOneWidget);
    expect(repository.loadCalls, 1, reason: '不再为近期指标多查一次库');
  });

  testWidgets('今天还没听时，连续天数从昨天往前数', (WidgetTester tester) async {
    final DateTime today = DateTime.now();
    final _FakeStatsRepository repository = _FakeStatsRepository(
      daily: <DailyPlaytime>[
        DailyPlaytime(
          day: _dayKey(today.subtract(const Duration(days: 1))),
          seconds: 1800,
        ),
        DailyPlaytime(
          day: _dayKey(today.subtract(const Duration(days: 2))),
          seconds: 1200,
        ),
      ],
    );

    await _pump(tester, repository);

    expect(find.text('2 天'), findsOneWidget, reason: '昨天、前天各听一天');
  });

  testWidgets('排行榜每行带播放次数占比条', (WidgetTester tester) async {
    final _FakeStatsRepository repository = _FakeStatsRepository(
      top: <TrackPlayStat>[
        TrackPlayStat(track: sampleTrack(title: '夜航'), plays: 12),
        TrackPlayStat(track: sampleTrack(title: '潮汐'), plays: 3),
      ],
    );

    await _pump(tester, repository);

    final List<FractionallySizedBox> bars = tester
        .widgetList<FractionallySizedBox>(
          find.byKey(const ValueKey<String>('rank-share-bar')),
        )
        .toList();
    expect(bars, hasLength(2), reason: '每行一条');
    expect(bars.first.widthFactor, closeTo(1.0, 0.001), reason: '榜首占满');
    expect(bars.last.widthFactor, closeTo(0.25, 0.001), reason: '3 / 12');
  });

  testWidgets('热力图铺满卡片右侧，不会切掉一条要横向滚才露出来', (WidgetTester tester) async {
    for (final Size size in <Size>[
      const Size(700, 900),
      const Size(900, 900),
      const Size(1280, 900),
      const Size(1600, 900),
      const Size(1920, 900),
    ]) {
      await _pump(tester, _FakeStatsRepository(), size: size);
      final Finder grid = find.descendant(
        of: find.byKey(const ValueKey<String>('stats-heatmap')),
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        ),
      );
      expect(grid, findsOneWidget, reason: '$size 下应有一层横向滚动');
      final ScrollableState state = tester.state<ScrollableState>(grid);
      expect(
        state.position.maxScrollExtent,
        lessThan(1),
        reason: '$size 下网格比视口宽，右侧会被切掉',
      );
    }
  });

  testWidgets('宽窗口总览与热力图并排，窄窗口上下堆叠', (WidgetTester tester) async {
    await _pump(tester, _FakeStatsRepository(), size: const Size(1280, 900));

    final Rect overview = tester.getRect(
      find.byKey(const ValueKey<String>('stats-overview')),
    );
    final Rect heatmap = tester.getRect(
      find.byKey(const ValueKey<String>('stats-heatmap')),
    );
    expect(overview.top, closeTo(heatmap.top, 0.5), reason: '同一行');
    expect(heatmap.left, greaterThan(overview.right), reason: '热力图在右侧');
    expect(
      heatmap.width,
      greaterThan(overview.width),
      reason: '横向空间优先给热力图，才铺得开一整年',
    );

    await _pump(tester, _FakeStatsRepository(), size: const Size(900, 900));
    final Rect narrowOverview = tester.getRect(
      find.byKey(const ValueKey<String>('stats-overview')),
    );
    final Rect narrowHeatmap = tester.getRect(
      find.byKey(const ValueKey<String>('stats-heatmap')),
    );
    expect(
      narrowHeatmap.top,
      greaterThan(narrowOverview.bottom),
      reason: '窄窗口仍然上下堆叠',
    );
  });

  testWidgets('热力图带周几与月份轴', (WidgetTester tester) async {
    final DateTime today = DateTime.now();
    final _FakeStatsRepository repository = _FakeStatsRepository(
      daily: <DailyPlaytime>[DailyPlaytime(day: _dayKey(today), seconds: 3600)],
    );

    await _pump(tester, repository);

    // 周几只标一 / 三 / 五，和 GitHub 一样
    expect(find.text('一'), findsOneWidget);
    expect(find.text('三'), findsOneWidget);
    expect(find.text('五'), findsOneWidget);
    expect(find.text('二'), findsNothing, reason: '中间几行留空，不挤');

    // 月份标签：形如「10 月」，至少要有两个（一年的跨度）
    final Iterable<String> months = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text text) => text.data ?? '')
        .where((String data) => RegExp(r'^\d{1,2} 月$').hasMatch(data));
    expect(months.length, greaterThanOrEqualTo(2));
    expect(months.toSet().length, months.length, reason: '每个月只标一次，不该重复');
  });

  testWidgets('并排布局下两张卡片底边对齐', (WidgetTester tester) async {
    await _pump(tester, _FakeStatsRepository(), size: const Size(1280, 900));

    final Rect overview = tester.getRect(
      find.byKey(const ValueKey<String>('stats-overview')),
    );
    final Rect heatmap = tester.getRect(
      find.byKey(const ValueKey<String>('stats-heatmap')),
    );
    expect(
      heatmap.bottom,
      closeTo(overview.bottom, 0.5),
      reason: '热力图比总览矮的时候不能让它自己短一截，否则卡片下方空一块',
    );
  });

  testWidgets('默认看歌曲排行，切到艺术家后换成艺术家列表', (WidgetTester tester) async {
    final _FakeStatsRepository repository = _FakeStatsRepository(
      top: <TrackPlayStat>[
        TrackPlayStat(track: sampleTrack(title: '夜航'), plays: 12),
      ],
      artists: <ArtistPlayStat>[
        const ArtistPlayStat(
          artist: 'Bao The Whale/Overspace',
          plays: 62,
          trackCount: 3,
        ),
        const ArtistPlayStat(artist: '林间电台', plays: 40, trackCount: 5),
      ],
    );

    await _pump(tester, repository);

    expect(find.text('常听歌曲'), findsOneWidget);
    expect(find.text('常听艺术家'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget, reason: '默认是歌曲排行');
    expect(find.text('最多 100 首'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('rank-tab-artists')));
    await tester.pumpAndSettle();

    expect(find.text('夜航'), findsNothing, reason: '切走之后歌曲列表不再渲染');
    expect(find.text('最多 100 位'), findsOneWidget);
    // 合唱标签拆成两位，播放次数各自算满
    expect(find.text('Bao The Whale'), findsOneWidget);
    expect(find.text('Overspace'), findsOneWidget);
    expect(find.text('62 次'), findsNWidgets(2));
    expect(find.text('听过 3 首'), findsNWidgets(2));
    expect(find.text('林间电台'), findsOneWidget);
    expect(find.text('听过 5 首'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('rank-tab-songs')));
    await tester.pumpAndSettle();
    expect(find.text('夜航'), findsOneWidget, reason: '切回来还在，不用重新加载');
    expect(find.text('Bao The Whale'), findsNothing);
  });

  testWidgets('切换排行时选中框滑过去，两段等宽', (WidgetTester tester) async {
    await _pump(tester, _FakeStatsRepository());
    final Finder songs = find.byKey(const ValueKey<String>('rank-tab-songs'));
    final Finder artists = find.byKey(
      const ValueKey<String>('rank-tab-artists'),
    );
    expect(
      tester.getSize(artists).width,
      closeTo(tester.getSize(songs).width, 0.5),
      reason: '两段等宽，滑块才只需平移、不必同时改尺寸',
    );

    final Finder chip = find
        .descendant(
          of: find.byKey(const ValueKey<String>('rank-tab-indicator')),
          matching: find.byType(DecoratedBox),
        )
        .first;
    expect(
      tester.getRect(chip).left,
      closeTo(tester.getRect(songs).left, 0.5),
      reason: '默认贴在「常听歌曲」上',
    );

    await tester.tap(artists);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final Rect mid = tester.getRect(chip);
    expect(
      mid.left,
      greaterThan(tester.getRect(songs).left),
      reason: '滑到中途，不是一帧跳过去',
    );
    expect(mid.left, lessThan(tester.getRect(artists).left), reason: '此时还没到终点');

    await tester.pumpAndSettle();
    expect(
      tester.getRect(chip).left,
      closeTo(tester.getRect(artists).left, 0.5),
      reason: '停下时正对「常听艺术家」',
    );
    expect(
      tester.getRect(chip).width,
      closeTo(tester.getRect(artists).width, 0.5),
    );
  });

  testWidgets('没有艺术家记录时给出空状态', (WidgetTester tester) async {
    await _pump(tester, _FakeStatsRepository());

    await tester.tap(find.byKey(const ValueKey<String>('rank-tab-artists')));
    await tester.pumpAndSettle();

    expect(find.text('还没有艺术家记录'), findsOneWidget);
    expect(find.text('还没有播放记录'), findsNothing);
  });

  testWidgets('点排行里的歌：整份榜单当队列，从这首开始', (WidgetTester tester) async {
    final Track a = sampleTrack(title: '夜航');
    final Track b = sampleTrack(title: '潮汐');
    final _FakeStatsRepository repository = _FakeStatsRepository(
      top: <TrackPlayStat>[
        TrackPlayStat(track: a, plays: 12),
        TrackPlayStat(track: b, plays: 3),
      ],
    );
    List<Track>? queue;
    Track? played;

    await _pump(
      tester,
      repository,
      onPlayTrack: (List<Track> tracks, Track track) {
        queue = tracks;
        played = track;
      },
    );

    await tester.tap(find.byKey(ValueKey<String>('rank-song-${b.path}')));
    await tester.pumpAndSettle();

    expect(played?.title, '潮汐');
    expect(queue?.map((Track track) => track.title).toList(), <String>[
      '夜航',
      '潮汐',
    ], reason: '队列是整份榜单，接着往下听就是榜上的下一首');
  });

  testWidgets('点艺术家行：把拆好的名字传出去', (WidgetTester tester) async {
    final _FakeStatsRepository repository = _FakeStatsRepository(
      artists: <ArtistPlayStat>[
        const ArtistPlayStat(
          artist: 'Bao The Whale/Overspace',
          plays: 62,
          trackCount: 3,
        ),
      ],
    );
    final List<String> opened = <String>[];

    await _pump(tester, repository, onOpenArtist: opened.add);
    await tester.tap(find.byKey(const ValueKey<String>('rank-tab-artists')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('rank-artist-Overspace')),
    );
    await tester.pumpAndSettle();

    expect(opened, <String>['Overspace'], reason: '合唱标签已经拆开，传的是单个名字');
  });

  testWidgets('返回按钮热区放大到 56×56', (WidgetTester tester) async {
    await _pump(tester, _FakeStatsRepository());

    final Size size = tester.getSize(
      find.byKey(const ValueKey<String>('stats-back')),
    );
    expect(size.width, 56);
    expect(size.height, 56, reason: '默认 BackButton 只有 48，不好点');
    expect(find.byTooltip('返回设置'), findsOneWidget);
  });
}

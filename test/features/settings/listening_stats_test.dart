import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/settings/listening_stats_page.dart';
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
    this.daily = const <DailyPlaytime>[],
    this.error,
  });

  PlayStats stats;
  List<TrackPlayStat> top;
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
  ListeningStatsRepository repository,
) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: ListeningStatsPage(repository: repository),
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
    expect(find.text('近 26 周'), findsOneWidget);
    expect(repository.lastSinceDay, isNotNull);
    expect(
      repository.lastSinceDay!,
      greaterThan(_dayKey(today.subtract(const Duration(days: 200)))),
      reason: '只查近 26 周，不要全表扫',
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
}

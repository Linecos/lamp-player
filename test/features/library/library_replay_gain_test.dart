import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

Future<void> _enterSelectionAndSelectAll(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('library-selection-toggle')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('全选'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('多选「计算 ReplayGain」：确认后逐首写入并重扫受影响目录', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..analyzedGain = -6.5;
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
    );

    await _enterSelectionAndSelectAll(tester);
    expect(find.byTooltip('计算 ReplayGain'), findsOneWidget);

    await tester.tap(find.byTooltip('计算 ReplayGain'));
    await tester.pumpAndSettle();
    expect(find.textContaining('计算 2 首曲目的 ReplayGain'), findsOneWidget);

    await tester.tap(find.text('开始计算'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains.length, 2, reason: '每首都要写入一次');
    expect(repository.writtenGains.values, everyElement(-6.5));
    expect(repository.scannedFolders, isNotEmpty, reason: '写标签后要重扫受影响目录');
    expect(find.textContaining('已写入 2 首'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing, reason: '进度框应已关闭');
  });

  testWidgets('确认框点取消不写任何文件', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: true),
    );

    await _enterSelectionAndSelectAll(tester);
    await tester.tap(find.byTooltip('计算 ReplayGain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains, isEmpty);
    expect(repository.scannedFolders, isEmpty);
  });

  testWidgets('文件只读写不进去时报失败数，其余曲目照常进行', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: true),
    );
    repository.writeGainError = StateError('文件只读');

    await _enterSelectionAndSelectAll(tester);
    await tester.tap(find.byTooltip('计算 ReplayGain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始计算'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains, isEmpty);
    expect(find.textContaining('2 首失败'), findsOneWidget);
  });

  testWidgets('没选曲目时按钮不可点', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.byKey(const ValueKey<String>('library-selection-toggle')),
    );
    await tester.pumpAndSettle();

    final IconButton button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.graphic_eq),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('增益未知时起播不中途改音量，算完写进缓存，下次起播带上', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..analyzedGain = -6.5;
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      // 关掉启动补算，模拟「还没算到这首就点了」
      prefetchReplayGain: false,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(
          coverBackfillAttempted: true,
          replayGain: true,
        ),
      ),
    );

    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();

    // play 带的是 0（当时还没有增益）而不是 -6.5：证明起播没等分析
    expect(playback.playedPaths, <String>['/music/夜航.mp3']);
    expect(playback.playedGains, <double>[0]);
    // 起播完成后补算，但**不**改当前输出（那会先响 1~2 秒再突然变小）
    expect(playback.analyzedPaths, <String>['/music/夜航.mp3']);
    expect(playback.setGainCalls, isEmpty);

    // 再播同一首：增益已在缓存里，起播直接带上
    await tester.tap(find.text('夜航').first);
    await tester.pumpAndSettle();
    expect(playback.playedGains.last, -6.5);
    expect(playback.analyzedPaths, <String>['/music/夜航.mp3']);
  });

  testWidgets('补算完成前已切歌：旧曲增益只进缓存，不套到新曲上', (WidgetTester tester) async {
    final Completer<void> gate = Completer<void>();
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..analyzedGain = -6.5;
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      prefetchReplayGain: false,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(
          coverBackfillAttempted: true,
          replayGain: true,
        ),
      ),
    );
    playback.analyzeGate = gate;

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.tap(find.text('潮汐'));
    // 不 settle：夜航的分析还挂在 gate 上
    await tester.pump();
    expect(playback.playedPaths, <String>['/music/夜航.mp3', '/music/潮汐.mp3']);

    gate.complete();
    await tester.pumpAndSettle();

    // 两条分析各自落进自己的缓存：再次起播时各带各的增益，互不串台
    expect(playback.setGainCalls, isEmpty);
    await tester.tap(find.text('夜航').first);
    await tester.pumpAndSettle();
    expect(playback.playedGains.last, -6.5);
  });

  testWidgets('启动后后台补算：点歌时增益已就绪，起播直接带上', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..analyzedGain = -7.5;
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(
          coverBackfillAttempted: true,
          replayGain: true,
        ),
      ),
    );

    // 没点任何歌，曲库里缺增益的曲目已经被逐首算完
    // 补算不挂在帧上，多 pump 几次让它跑完
    for (int i = 0; i < 50 && playback.analyzedPaths.length < 2; i += 1) {
      await tester.pump();
    }
    expect(playback.analyzedPaths.toSet(), <String>{
      '/music/夜航.mp3',
      '/music/潮汐.mp3',
    });
    expect(playback.playedPaths, isEmpty);

    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(playback.playedGains, <double>[-7.5]);
  });
}

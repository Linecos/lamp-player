import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

Future<void> _enterSelectionAndSelectAll(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('library-selection-toggle')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('track-select-all')));
  await tester.pumpAndSettle();
}

/// 在已勾选的行上点右键，菜单对整批生效
Future<void> _rightClickRow(WidgetTester tester, String title) async {
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.down(tester.getCenter(find.text(title)));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 起一次计算，卡在第一首解码中途，量进度框的宽度。
/// 进度框里那行「第几首 / 共几首：歌名」原先没有定宽：内容取自身宽度，
/// 弹出时能一路顶到窗口宽度，换个窗口尺寸又是另一个样子。
Future<double> _progressDialogWidth(WidgetTester tester, String title) async {
  final Completer<void> gate = Completer<void>();
  final FakePlaybackService playback = FakePlaybackService(
    isAvailable: true,
    durationSecs: 180,
  )..analyzeGate = gate;
  await pumpLibrary(
    tester,
    tracks: <Track>[sampleTrack(title: title)],
    playback: playback,
  );

  await tester.tap(
    find.byKey(const ValueKey<String>('library-selection-toggle')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
  await _rightClickRow(tester, title);
  await tester.tap(find.text('计算 ReplayGain…'));
  await tester.pumpAndSettle();

  await tester.tap(find.text('开始计算'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  final Finder dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget, reason: '等解码时进度框要开着');
  // 量可见的弹窗表面：AlertDialog 外面那层是 inset 盒，永远是整窗宽
  final Finder surface = find
      .descendant(of: dialog, matching: find.byType(Material))
      .first;
  final double width = tester.getSize(surface).width;

  await tester.pumpWidget(const SizedBox());
  return width;
}

void main() {
  testWidgets('进度框是定宽的，不随歌名长短或窗口宽度变形', (WidgetTester tester) async {
    final double shortName = await _progressDialogWidth(tester, '雨');
    final double longName = await _progressDialogWidth(
      tester,
      '这是一首名字特别特别长的歌曲，长到足以把整个弹窗横向撑开',
    );

    // 内容定宽 420 + AlertDialog 自己的 24×2 内边距
    final double expected = replayGainDialogWidth + 48;
    expect(shortName, closeTo(expected, 1), reason: '不定宽时会被顶到窗口宽度');
    expect(longName, closeTo(expected, 1), reason: '长标题只该省略号，不该撑开弹窗');
  });

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

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('计算 ReplayGain（2 首）…'));
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
    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('计算 ReplayGain（2 首）…'));
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
    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('计算 ReplayGain（2 首）…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始计算'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains, isEmpty);
    expect(find.textContaining('2 首失败'), findsOneWidget);
  });

  testWidgets('只勾一首时右键算单首，不进入批量确认', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..analyzedGain = -6.5;
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(
      find.byKey(const ValueKey<String>('library-selection-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('计算 ReplayGain…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('计算这 1 首的 ReplayGain'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
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

  testWidgets('参考响度改了按新目标现算：不重新解码', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', loudnessLufs: -25.5),
        sampleTrack(title: '潮汐', loudnessLufs: -25.5),
      ],
      playback: playback,
      prefetchReplayGain: false,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(
          coverBackfillAttempted: true,
          replayGain: true,
          replayGainReference: -14,
        ),
      ),
    );

    await tester.tap(find.text('夜航').first);
    await tester.pumpAndSettle();
    // -14 − (-25.5) = +11.5，曲库里存的还是同一份测量值
    expect(playback.playedGains, <double>[11.5]);
    expect(playback.analyzedPaths, isEmpty, reason: '已经有测量值，不该再解码');
  });

  testWidgets('峰值类型：采样峰值与真实峰值分别限幅', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(
          title: '夜航',
          loudnessLufs: -30,
          samplePeak: 0.9,
          truePeak: 0.6,
        ),
      ],
      playback: playback,
      prefetchReplayGain: false,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(
          coverBackfillAttempted: true,
          replayGain: true,
          replayGainReference: -14,
          replayGainTruePeak: true,
        ),
      ),
    );

    await tester.tap(find.text('夜航').first);
    await tester.pumpAndSettle();
    // 目标 +16 dB 被真峰值 0.6（≈ -4.44 dBFS）压到 +4.44
    expect(playback.playedGains.single, closeTo(4.437, 0.01));
  });
}

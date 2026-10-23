import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/common/audio/volume_curve.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
  testWidgets('播放引擎不可用时禁用播放按钮并给出提示', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    final IconButton playButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow),
    );
    expect(playButton.onPressed, isNull);
    expect(find.textContaining('播放引擎不可用'), findsWidgets);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('播放引擎不可用'), findsWidgets);
    // 仍然只展示曲目信息，不伪造播放状态
    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('引擎可用时点击曲目会调用播放并可暂停', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths, <String>['/music/夜航.mp3']);
    expect(find.widgetWithIcon(IconButton, Icons.pause), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.pause));
    await tester.pump();
    expect(playback.pauseCalls, 1);

    // 卸载页面，确保轮询定时器被 dispose 取消
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('播放成功会写入播放历史', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final List<Track> history = await repository.loadRecentTracks();
    expect(history.map((Track track) => track.path), <String>['/music/夜航.mp3']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('自然播完后自动切到下一首', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths, <String>['/music/夜航.mp3']);

    // 模拟 BASS 自然播完：状态 stopped、位置停在结尾
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();

    expect(playback.playedPaths, <String>[
      '/music/夜航.mp3',
      '/music/潮汐.mp3',
    ], reason: '自然播完应自动播放队列下一首');
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('单曲队列播完后按播放从头重播而不是 resume', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: <Track>[sampleTrack(title: '夜航')],
      playback: playback,
    );

    await tester.tap(find.text('夜航').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths.length, 1);

    // 队列只有一首且未开循环：播完就停在末尾
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byIcon(Icons.play_arrow),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.widgetWithIcon(IconButton, Icons.play_arrow),
      ),
    );
    await tester.pump();

    expect(playback.playedPaths.length, 2, reason: '应重新 play 而不是 resume');
    expect(playback.resumeCalls, 0);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byIcon(Icons.pause),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('播放全部从第一首开始，可继续下一首', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('播放全部'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths, <String>['/music/夜航.mp3']);

    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths.last, '/music/潮汐.mp3');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('空格暂停 / 继续，Ctrl+F 聚焦搜索', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.pauseCalls, 1, reason: '空格应暂停');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.resumeCalls, 1, reason: '再按空格应继续');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final TextField search = tester.widget<TextField>(find.byType(TextField));
    expect(search.focusNode?.hasFocus, isTrue, reason: 'Ctrl+F 应聚焦搜索框');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('搜索框内按空格不会切换播放', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(playback.pauseCalls, 0, reason: '输入空格不应触发暂停');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('右键「下一首播放」把曲目插到当前曲目之后', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    // 先播潮汐（队列是 夜航、潮汐，当前在潮汐）
    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('夜航').first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths.last, '/music/夜航.mp3');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('队列面板可查看并跳播', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('queue-item-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('queue-item-1')));
    await tester.pumpAndSettle();

    expect(playback.playedPaths.last, '/music/潮汐.mp3');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('启动时恢复音量、分区、循环与上次播放', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    final FakeSessionStore session = FakeSessionStore(
      snapshot: const SessionSnapshot(
        volume: 0.4,
        lastTrackPath: '/music/潮汐.mp3',
        lastPositionSecs: 42,
        repeat: LoopMode.all,
        section: 'favorites',
        railExpanded: false,
      ),
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
    );

    expect(find.text('还没有收藏'), findsOneWidget, reason: '应恢复到收藏分区');
    expect(find.byTooltip('展开导航栏'), findsOneWidget, reason: '侧栏应保持收起');
    expect(find.byTooltip('循环播放：列表'), findsOneWidget);
    expect(
      playback.volumeCalls.last,
      closeTo(volumeToAmplitude(0.4), 0.001),
      reason: '会话里存的是滑块值，发给引擎时要走感知曲线',
    );

    // 上次播放的曲目显示在播放条上，但不会自动出声
    expect(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('潮汐')),
      findsOneWidget,
    );
    expect(find.text('00:42'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.widgetWithIcon(IconButton, Icons.play_arrow),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths.single, '/music/潮汐.mp3');
    expect(playback.seekCalls, contains(42.0), reason: '应从上次位置继续');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('静音后把音量写回会话', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(isAvailable: true);
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
    );

    await tester.tap(find.byTooltip('静音'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(session.snapshot.volume, 0);
    expect(session.saveCalls, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('拖动进度条松手后调用 seek', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.drag(
      find.byKey(const ValueKey<String>('player-progress')),
      const Offset(120, 0),
    );
    await tester.pump();

    expect(playback.seekCalls, hasLength(1));
    expect(playback.seekCalls.single, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('拖动期间轮询不会把进度拉回去', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      positionSecs: 10,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 播放中位置在前，拖到后段后让轮询跑一轮，进度不应被写回 10 秒
    await tester.drag(
      find.byKey(const ValueKey<String>('player-progress')),
      const Offset(160, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('00:10'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('调节音量调用 setVolume，静音后图标切换', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(isAvailable: true);
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    final Rect slider = tester.getRect(
      find.byKey(const ValueKey<String>('player-volume')),
    );
    await tester.tapAt(
      Offset(slider.left + slider.width * 0.25, slider.center.dy),
    );
    await tester.pump();
    // 音量调用有 80ms 合并窗口
    await tester.pump(const Duration(milliseconds: 120));

    expect(playback.volumeCalls, isNotEmpty);
    expect(playback.volumeCalls.last, lessThan(1));
    expect(playback.volumeCalls.last, greaterThan(0));
    expect(
      playback.volumeCalls.last,
      lessThan(0.05),
      reason: '滑块 25% 左右应压到约 -36 dB，而不是线性 0.25',
    );

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();

    expect(playback.volumeCalls.last, 0);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await tester.tap(find.byTooltip('取消静音'));
    await tester.pump();

    expect(playback.volumeCalls.last, greaterThan(0));
    expect(find.byIcon(Icons.volume_off), findsNothing);
  });

  testWidgets('连续拖动音量按窗口合并，只发一次 setVolume', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(isAvailable: true);
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    final Slider slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('player-volume')),
        matching: find.byType(Slider),
      ),
    );
    final int initialCalls = playback.volumeCalls.length;
    for (int step = 1; step <= 10; step += 1) {
      slider.onChanged!(step / 10);
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(
      playback.volumeCalls,
      hasLength(initialCalls),
      reason: '合并窗口内不应逐次调用',
    );

    await tester.pump(const Duration(milliseconds: 120));
    expect(
      playback.volumeCalls,
      hasLength(initialCalls + 1),
      reason: '一个窗口只发一次',
    );
    expect(playback.volumeCalls.last, closeTo(1.0, 0.001));
  });

  testWidgets('轮询失败一次后仍会重试，不会冻结进度', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      positionSecs: 12,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('00:12'), findsOneWidget);

    playback.positionError = StateError('瞬时失败');
    playback.positionSecs = 42;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('00:42'), findsNothing, reason: '失败时保持旧值');

    playback.positionError = null;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('00:42'), findsOneWidget, reason: '恢复后应继续轮询');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('最后一首点下一首时不会把界面切成已播完', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    // 播最后一首，然后手动点「下一首」
    await tester.tap(find.text('潮汐').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(playback.playedPaths, <String>[
      '/music/潮汐.mp3',
    ], reason: '队列到头时不该换曲');
    expect(
      playback.current,
      rust.PlaybackState.playing,
      reason: '手动点下一首时音频还在放，不能当成自然播完',
    );
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byIcon(Icons.pause),
      ),
      findsOneWidget,
      reason: '按钮仍应显示暂停，否则会出现「显示已停、声音还在」',
    );
    expect(find.text('已经是最后一首'), findsOneWidget);
  });

  testWidgets('队列面板可移除当前曲目并清空队列', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();

    // 移除当前曲目：后一首顶上来并继续播放
    await tester.tap(find.byTooltip('从队列移除').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('queue-item-1')), findsNothing);
    expect(playback.playedPaths.last, '/music/潮汐.mp3');

    await tester.tap(find.text('清空队列'));
    await tester.pumpAndSettle();
    expect(find.text('清空播放队列？'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.textContaining('队列还是空的'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('尚未播放')),
      findsOneWidget,
      reason: '清空队列后播放条应回到未播放状态',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('播放失败后会刷新输出信息', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..playError = StateError('设备被其他程序占用');
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
    final int before = playback.outputInfoCalls;

    await tester.tap(find.text('夜航').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('播放失败'), findsOneWidget);
    expect(
      playback.outputInfoCalls,
      greaterThan(before),
      reason: '失败后引擎可能已回落共享，设置页要拿到最新状态',
    );
  });
}

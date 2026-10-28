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

/// 鼠标移到音量图标上，唤出竖条浮层（播放条的音量条改成悬停后才出现）
Future<void> _hoverVolume(WidgetTester tester) async {
  final Finder icon = find.byWidgetPredicate(
    (Widget widget) =>
        widget is Icon &&
        (widget.icon == Icons.volume_up ||
            widget.icon == Icons.volume_down ||
            widget.icon == Icons.volume_off),
  );
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer();
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(icon));
  await tester.pumpAndSettle();
}

/// 按住 Ctrl 按一下某个键（曲库页的方向键组合都走 Ctrl）
Future<void> _pressWithCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

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

  testWidgets('方向键快进快退，Ctrl+左右切歌，Ctrl+上下调音量', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(playback.seekCalls, <double>[5.0], reason: '→ 应快进 5 秒');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(playback.seekCalls.last, 0.0, reason: '← 应退回开头（进度不足 5 秒）');

    await _pressWithCtrl(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths, <String>[
      '/music/夜航.mp3',
      '/music/潮汐.mp3',
    ], reason: 'Ctrl+→ 应切到下一首');

    await _pressWithCtrl(tester, LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths.last, '/music/夜航.mp3', reason: 'Ctrl+← 应回到上一首');

    await _pressWithCtrl(tester, LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(playback.volumeCalls.last, lessThan(1), reason: 'Ctrl+↓ 应调低音量');

    await _pressWithCtrl(tester, LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      playback.volumeCalls.last,
      closeTo(1.0, 0.001),
      reason: 'Ctrl+↑ 应调回满音量',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('播放到一半点上一首直接切上一首，不再回本曲开头', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      positionSecs: 60,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('潮汐'));
    await tester.pump();
    // 等一次位置轮询，让进度落在 60 秒（旧逻辑会因此只做 seek(0)）
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byTooltip('上一首 (Ctrl+←)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths, <String>[
      '/music/潮汐.mp3',
      '/music/夜航.mp3',
    ], reason: '播放到一半点上一首，应直接切到上一首');
    expect(playback.seekCalls, isEmpty, reason: '不该只是回到本曲开头');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('Ctrl+上下调音量时弹出音量浮层，过一会儿自动收起', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(isAvailable: true);
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    expect(
      find.byKey(const ValueKey<String>('player-volume')),
      findsNothing,
      reason: '没悬停也不调音量时浮层不该出现',
    );

    await _pressWithCtrl(tester, LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('player-volume')),
      findsOneWidget,
      reason: '键盘调音量应弹出浮层，方便看到百分比',
    );
    expect(find.text('95%'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('player-volume')),
      findsNothing,
      reason: '鼠标不在上面，停留一会儿后自动收起',
    );

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

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(playback.seekCalls, isEmpty, reason: '输入框里的方向键应留给光标移动');

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
    expect(find.byTooltip('播放模式：列表循环'), findsOneWidget);
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

  testWidgets('恢复进度时 seek 失败仍按播放中处理', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
      positionSecs: 42,
    )..seekError = StateError('seek 失败');
    final FakeSessionStore session = FakeSessionStore(
      snapshot: const SessionSnapshot(
        lastTrackPath: '/music/潮汐.mp3',
        lastPositionSecs: 42,
      ),
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.widgetWithIcon(IconButton, Icons.play_arrow),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 引擎已经在出声：不能把界面切回「已暂停」，否则图标反向、进度条冻结
    expect(playback.playedPaths, <String>['/music/潮汐.mp3']);
    expect(playback.current, rust.PlaybackState.playing);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byIcon(Icons.pause),
      ),
      findsOneWidget,
      reason: 'seek 失败不应影响播放状态',
    );
    expect(find.textContaining('从上次位置继续失败'), findsOneWidget);

    // 轮询应已启动：引擎位置变化能刷新到界面
    playback.positionSecs = 7;
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('00:07'), findsOneWidget, reason: '进度轮询应继续工作');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('快捷键不响应长按重复事件', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: true),
    );

    final CallbackShortcuts shortcuts = tester.widget<CallbackShortcuts>(
      find.byType(CallbackShortcuts).first,
    );
    final Iterable<SingleActivator> activators = shortcuts.bindings.keys
        .whereType<SingleActivator>();
    expect(activators, isNotEmpty);
    expect(
      activators.every(
        (SingleActivator activator) => !activator.includeRepeats,
      ),
      isTrue,
      reason: '长按空格 / 方向键会连续触发播放暂停与切歌',
    );
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

    await _hoverVolume(tester);
    final Rect slider = tester.getRect(
      find.byKey(const ValueKey<String>('player-volume')),
    );
    // 点滑块正中：两侧内缩对称，映射出的值恒为 0.5，不受滑块宽度影响
    await tester.tapAt(slider.center);
    await tester.pump();
    // 音量调用有 80ms 合并窗口
    await tester.pump(const Duration(milliseconds: 120));

    expect(playback.volumeCalls, isNotEmpty);
    expect(playback.volumeCalls.last, lessThan(1));
    expect(playback.volumeCalls.last, greaterThan(0));
    expect(
      playback.volumeCalls.last,
      closeTo(0.125, 0.02),
      reason: '滑块中点应压到约 0.125（三次曲线），而不是线性 0.5',
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

    await _hoverVolume(tester);
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

    // 标题栏放「清空 / 关闭」，随机 / 循环挪到底部
    expect(find.byTooltip('清空队列'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byTooltip('随机播放'), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('清空队列')).dy,
      lessThan(tester.getCenter(find.byTooltip('随机播放')).dy),
      reason: '清空 / 关闭在顶部，随机 / 循环在底部',
    );

    // 移除当前曲目：后一首顶上来并继续播放
    await tester.tap(find.byTooltip('从队列移除').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('queue-item-1')), findsNothing);
    expect(playback.playedPaths.last, '/music/潮汐.mp3');

    await tester.tap(find.byTooltip('清空队列'));
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

  testWidgets('自然播完遇到打不开的曲目会继续跳到下一首', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..failingPaths.add('/music/潮汐.mp3');
    await pumpLibrary(
      tester,
      tracks: <Track>[
        // 专辑名和曲名区分开，否则 `find.text('夜航')` 会同时命中专辑列
        sampleTrack(title: '夜航', album: '专辑一'),
        sampleTrack(title: '潮汐', album: '专辑二'),
        sampleTrack(title: '灯下', album: '专辑三'),
      ],
      playback: playback,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths, <String>['/music/夜航.mp3']);

    // 模拟自然播完：状态 stopped、位置停在结尾
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    await tester.pump();

    expect(playback.playedPaths, <String>[
      '/music/夜航.mp3',
      '/music/灯下.mp3',
    ], reason: '潮汐打不开，应自动跳到再下一首');
    expect(find.textContaining('已跳过 1 首'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byIcon(Icons.pause),
      ),
      findsOneWidget,
      reason: '跳过之后应停在能播放的曲目上',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('连续多首播放失败达到上限后停止自动跳过', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    // 打开列表循环，保证每次失败后队列都还有「下一首」
    // 顺序 → 随机 → 列表循环
    await tester.tap(find.byTooltip('播放模式：顺序播放'));
    await tester.pump();
    await tester.tap(find.byTooltip('播放模式：随机播放'));
    await tester.pump();
    expect(find.byTooltip('播放模式：列表循环'), findsOneWidget);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths, <String>['/music/夜航.mp3']);

    // 播完后整库都打不开
    playback.failingPaths.addAll(<String>['/music/夜航.mp3', '/music/潮汐.mp3']);
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));
    for (int step = 0; step < 6; step += 1) {
      await tester.pump();
    }

    expect(playback.playedPaths, <String>[
      '/music/夜航.mp3',
    ], reason: '播放失败的曲目不应记入播放');
    expect(find.textContaining('连续 5 首播放失败'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byIcon(Icons.play_arrow),
      ),
      findsOneWidget,
      reason: '达到上限后应停下，而不是无限空转',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('播放中按增量累计听歌时长，暂停时写库', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 300,
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 每拍推进 2.5 秒（小于 seek 过滤阈值 3 秒），累计到 15 秒后应自动写库
    for (int step = 1; step <= 7; step += 1) {
      playback.positionSecs = step * 2.5;
      await tester.pump(const Duration(milliseconds: 550));
    }

    final String key = repository.playedSeconds.keys.firstWhere(
      (String item) => item.endsWith('/music/夜航.mp3'),
      orElse: () => '',
    );
    expect(key, isNotEmpty, reason: '播放 15 秒后应写一次库');
    expect(repository.playedSeconds[key], greaterThanOrEqualTo(15));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('拖动进度跳变不会被计入听歌时长', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 300,
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 一次 120 秒的跳变应当被过滤，不计入时长
    playback.positionSecs = 120;
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 550));

    expect(
      repository.playedSeconds.values.fold<int>(0, (int a, int b) => a + b),
      lessThan(3),
      reason: '大跨度跳变不是听过的时长',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

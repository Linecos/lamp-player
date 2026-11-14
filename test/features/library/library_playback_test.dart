import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/common/audio/volume_curve.dart';
import 'package:lamp_player/src/common/ui_clock.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/now_playing_page.dart';
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

    final InkWell playButton = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('player-play-pause')),
    );
    expect(playButton.onTap, isNull);
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
    expect(
      find.byKey(const ValueKey<String>('player-play-pause')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('player-play-pause')));
    await tester.pump();
    expect(playback.pauseCalls, 1);

    // 卸载页面，确保轮询定时器被 dispose 取消
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('启动时预加载上次曲目，进度条可拖且拖动是真 seek', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    // 上次退出时停在第 40 秒：启动后引擎里就该有一首装好、定位到 40 的曲目
    final FakeSessionStore store = FakeSessionStore(
      snapshot: const SessionSnapshot(
        coverBackfillAttempted: true,
        lastTrackPath: '/music/夜航.mp3',
        lastPositionSecs: 40,
      ),
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: store,
    );

    expect(playback.preloadedPaths, <String>['/music/夜航.mp3']);
    expect(playback.current, rust.PlaybackState.paused, reason: '装进引擎但停在暂停态');
    expect(playback.positionSecs, 40, reason: '预加载直接定位到上次位置');
    expect(playback.playedPaths, isEmpty, reason: '预加载不是播放，不该进播放历史');

    final Finder progress = find.byKey(
      const ValueKey<String>('player-progress'),
    );
    final Slider slider = tester.widget<Slider>(
      find.descendant(of: progress, matching: find.byType(Slider)),
    );
    expect(slider.onChanged, isNotNull, reason: '引擎里有曲目，进度条不该变灰');

    slider.onChangeEnd!(120);
    await tester.pump();

    expect(playback.seekCalls, <double>[
      120.0,
    ], reason: '引擎里已经有曲目了，拖动就是真 seek，不用攒续播点');

    await tester.tap(find.byKey(const ValueKey<String>('player-play-pause')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.resumeCalls, 1, reason: '引擎停在位置上，按播放直接继续');
    expect(playback.playedPaths, isEmpty, reason: '不需要重新加载曲目');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('暂停态拖到的位置会落盘，重启后仍停在那里', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    final FakeSessionStore store = FakeSessionStore(
      snapshot: const SessionSnapshot(
        coverBackfillAttempted: true,
        lastTrackPath: '/music/夜航.mp3',
        lastPositionSecs: 40,
      ),
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: store,
    );

    // 直接给秒数而不是拖动像素：滑块宽度随窗口变，拖 160px 会一路顶到曲尾，
    // 断言就成了「顶到 180 也算过」，测不出到底存的是不是拖到的那个点
    final Slider slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('player-progress')),
        matching: find.byType(Slider),
      ),
    );
    slider.onChangeEnd!(120);
    // 落盘走 400ms 合并窗口
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(playback.playedPaths, isEmpty, reason: '拖动不等于起播');
    expect(
      store.snapshot.lastPositionSecs,
      120.0,
      reason: '拖到的位置要落盘，否则关掉再开又回到上次保存的位置',
    );

    // 关掉再开一遍：先卸掉整棵树，否则同类型同位置的 widget 会复用同一个
    // State，走的还是内存里的值，测不出「重启」
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final FakePlaybackService second = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: second,
      sessionStore: store,
    );

    expect(second.preloadedPaths, <String>['/music/夜航.mp3']);
    expect(second.positionSecs, 120.0, reason: '重启后预加载直接落在落盘的位置');

    await tester.tap(find.byKey(const ValueKey<String>('player-play-pause')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(second.resumeCalls, 1, reason: '从预加载停住的位置接着播');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('重启后恢复上次的播放队列，而不是整个曲库', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    // 上次是从只有「潮汐」的队列里放的（比如歌单），重启后不该变成整个曲库
    final FakeSessionStore store = FakeSessionStore(
      snapshot: const SessionSnapshot(
        coverBackfillAttempted: true,
        lastTrackPath: '/music/潮汐.mp3',
        lastPositionSecs: 30,
        queuePaths: <String>['/music/潮汐.mp3'],
        queueIndex: 0,
      ),
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: store,
    );

    expect(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('潮汐')),
      findsOneWidget,
    );
    expect(find.text('00:30'), findsOneWidget, reason: '位置也照旧续上');
    expect(playback.preloadedPaths, <String>['/music/潮汐.mp3']);

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('queue-item-1')),
      findsNothing,
      reason: '队列应只有存档里的那一首，不该用整个曲库重排',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('队列里已被删掉的曲目跳过，当前曲目缺失就从 0 开始', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    // 下标 1 的那首文件没了：当前曲目跟着顶上来的「夜航」，位置不能沿用旧的
    final FakeSessionStore store = FakeSessionStore(
      snapshot: const SessionSnapshot(
        coverBackfillAttempted: true,
        lastTrackPath: '/music/已删除.mp3',
        lastPositionSecs: 42,
        queuePaths: <String>['/music/夜航.mp3', '/music/已删除.mp3'],
        queueIndex: 1,
      ),
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: store,
    );

    expect(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
      findsOneWidget,
    );
    expect(find.text('00:00'), findsOneWidget, reason: '换成了另一首，不能跳到上次的位置');
    expect(playback.preloadedPaths, <String>['/music/夜航.mp3']);

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('queue-item-1')),
      findsNothing,
      reason: '对不上的路径直接跳过',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('起播后把队列路径与下标写进会话', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    final FakeSessionStore store = FakeSessionStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: store,
    );

    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final List<String>? paths = store.snapshot.queuePaths;
    expect(
      paths,
      containsAll(<String>['/music/夜航.mp3', '/music/潮汐.mp3']),
      reason: '从曲库起播时整个曲库就是队列',
    );
    final int? index = store.snapshot.queueIndex;
    expect(index, isNotNull);
    expect(paths![index!], '/music/潮汐.mp3', reason: '下标要指向正在播的那首');

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

    // 拼音序下潮汐是第一首，夜航是第二首
    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths, <String>['/music/潮汐.mp3']);

    // 模拟 BASS 自然播完：状态 stopped、位置停在结尾
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();

    expect(playback.playedPaths, <String>[
      '/music/潮汐.mp3',
      '/music/夜航.mp3',
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
        matching: find.byKey(const ValueKey<String>('player-play-pause')),
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

    // 标题排序按拼音：潮汐(chaoxi) 在 夜航(yehang) 之前
    expect(playback.playedPaths, <String>['/music/潮汐.mp3']);

    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths.last, '/music/夜航.mp3');

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

  testWidgets('搜索框有焦点时空格让给输入，退出后再恢复', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final int pausesBefore = playback.pauseCalls;

    // 光标进搜索框
    await _pressWithCtrl(tester, LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );

    // 空格必须从绑定表里摘掉：CallbackShortcuts 一旦命中就把事件标成已处理，
    // 输入框就永远收不到空格（用户看到的就是「打不出空格」）
    final CallbackShortcuts shortcuts = tester.widget<CallbackShortcuts>(
      find.byType(CallbackShortcuts).first,
    );
    expect(
      shortcuts.bindings.keys.whereType<SingleActivator>().any(
        (SingleActivator activator) =>
            activator.trigger == LogicalKeyboardKey.space,
      ),
      isFalse,
      reason: '输入期间不该再绑空格',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.pauseCalls, pausesBefore, reason: '输入中的空格不能再触发暂停');

    // 离开输入框，快捷键恢复
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.pauseCalls, pausesBefore + 1, reason: '退出搜索后空格应该又能暂停');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('方向键快进快退，Ctrl+左右切歌，Ctrl+上下调音量', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('潮汐'));
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
      '/music/潮汐.mp3',
      '/music/夜航.mp3',
    ], reason: 'Ctrl+→ 应切到下一首');

    await _pressWithCtrl(tester, LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths.last, '/music/潮汐.mp3', reason: 'Ctrl+← 应回到上一首');

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

    // 从队列最后一首（夜航）往回退
    await tester.tap(find.text('夜航'));
    await tester.pump();
    // 等一次位置轮询，让进度落在 60 秒（旧逻辑会因此只做 seek(0)）
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byTooltip('上一首 (Ctrl+←)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.playedPaths, <String>[
      '/music/夜航.mp3',
      '/music/潮汐.mp3',
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

    // 搜索框平时收着（顶栏只剩一个放大镜）：点开后它会向左展开并自动聚焦。
    // 展开是 220ms 的宽度动画，等它走完再按键
    await tester.tap(
      find.byKey(const ValueKey<String>('library-search-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: '点放大镜应当直接聚焦，省掉用户再点一次',
    );
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

    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('queue-item-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('queue-item-1')));
    await tester.pumpAndSettle();

    expect(playback.playedPaths.last, '/music/夜航.mp3');

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
    // 引擎里已经装好并停在 42 秒处
    expect(playback.preloadedPaths, <String>['/music/潮汐.mp3']);
    expect(playback.current, rust.PlaybackState.paused);
    expect(playback.positionSecs, 42);

    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byKey(const ValueKey<String>('player-play-pause')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(playback.resumeCalls, 1, reason: '从上次位置继续，不需要重新加载');

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
        matching: find.byKey(const ValueKey<String>('player-play-pause')),
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

  testWidgets('播放页的静音按钮要同时改图标和引擎', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 600,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
    );
    await tester.pumpAndSettle();

    final Finder page = find.byType(NowPlayingPage);
    expect(page, findsOneWidget);

    await tester.tap(
      find.descendant(
        of: page,
        matching: find.byKey(const ValueKey<String>('now-playing-mute')),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(of: page, matching: find.byIcon(Icons.volume_off)),
      findsOneWidget,
      reason: '点击后图标要变成静音（播放页读的是 NowPlayingData，快照不推就永远不变）',
    );
    expect(playback.volumeCalls.last, 0);

    await tester.tap(
      find.descendant(
        of: page,
        matching: find.byKey(const ValueKey<String>('now-playing-mute')),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(of: page, matching: find.byIcon(Icons.volume_off)),
      findsNothing,
      reason: '再点一次回到静音前的音量',
    );
    expect(playback.volumeCalls.last, greaterThan(0));
    await tester.pumpAndSettle();
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

    // 播最后一首（拼音序下夜航在最后），然后手动点「下一首」
    await tester.tap(find.text('夜航').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(playback.playedPaths, <String>[
      '/music/夜航.mp3',
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

    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();

    // 标题栏只放「清空 / 关闭」；随机 / 循环在播放条与正在播放页有入口，弹窗里不再重复
    expect(find.byTooltip('清空队列'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byTooltip('随机播放'), findsNothing);
    expect(find.byTooltip('循环播放：关'), findsNothing);

    // 移除当前曲目：后一首顶上来并继续播放
    await tester.tap(find.byTooltip('从队列移除').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('queue-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('queue-item-1')), findsNothing);
    expect(playback.playedPaths.last, '/music/夜航.mp3');

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

  testWidgets('自然播完遇到打不开的曲目会继续跳到下一首', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..failingPaths.add('/music/灯下.mp3');
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

    // 拼音序：潮汐 → 灯下 → 夜航；灯下打不开，从潮汐播完应跳过它落到夜航
    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths, <String>['/music/潮汐.mp3']);

    // 模拟自然播完：状态 stopped、位置停在结尾
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    await tester.pump();

    expect(playback.playedPaths, <String>[
      '/music/潮汐.mp3',
      '/music/夜航.mp3',
    ], reason: '灯下打不开，应自动跳到再下一首');
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

  testWidgets('seek 失败时进度条退回原来的位置', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 300,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 先让引擎停在 40 秒，界面跟着走一拍
    playback.positionSecs = 40;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('00:40'), findsWidgets);

    playback.seekError = StateError('设备已拔');
    // 键盘快进 5 秒（→ 默认是「快进 5 秒」）
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.textContaining('跳转失败'), findsWidgets);
    expect(
      find.text('00:40'),
      findsWidgets,
      reason: '引擎没跳成，界面也不能停在 00:45 这个假位置',
    );
    expect(find.text('00:45'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('打开 / 收起播放页的转场期间装饰动画停表', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 600,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
    );
    await tester.pump();
    expect(UiClock.isPaused, isTrue, reason: '转场期间流光 / 封面旋转 / 逐字歌词都该停表，只留转场本身');

    await tester.pumpAndSettle();
    expect(UiClock.isPaused, isFalse, reason: '转场结束必须恢复，否则整页动画冻住');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(UiClock.isPaused, isTrue, reason: '收起转场同样停表');

    await tester.pumpAndSettle();
    expect(UiClock.isPaused, isFalse);
  });

  testWidgets('转场还没走完时按 Esc 不会打断动画', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 600,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final Finder pageHeader = find.byKey(
      const ValueKey<String>('now-playing-header'),
    );
    await tester.tap(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // 打开动画走到一半就按 Esc：这一次要被忽略，否则动画半路掉头
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(pageHeader, findsOneWidget, reason: '转场没走完，收起请求先攒着不办');

    await tester.pumpAndSettle();
    expect(pageHeader, findsOneWidget, reason: '动画照常走完，页面仍然打开');

    // 动画结束之后再按才有反应
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(pageHeader, findsNothing);
  });

  testWidgets('睡眠定时在关掉播放页之后仍然到点暂停', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 600,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 点播放条上的曲名进正在播放页
    await tester.tap(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsOneWidget,
    );

    // 设 15 分钟，并关掉「顺延到曲目结束」——这里测的是到点就停
    await tester.tap(find.byKey(const ValueKey<String>('now-playing-sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-extend-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-preset-15')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();

    // 关掉播放页：定时器必须活在页面之外
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsNothing,
    );
    expect(playback.pauseCalls, 0);

    await tester.pump(const Duration(minutes: 15, seconds: 1));

    expect(playback.pauseCalls, 1, reason: '到点要暂停，哪怕播放页早就关了（这正是边听边睡的用法）');
  });
}

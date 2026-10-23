import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/app/title_bar.dart';
import 'package:lamp_player/src/common/audio/volume_curve.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/features/settings/music_folder_store.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

Future<FakeLibraryRepository> pumpLibrary(
  WidgetTester tester, {
  List<Track>? tracks,
  FakePlaybackService? playback,
  DirectoryPicker? directoryPicker,
  MusicFolderStore? folderStore,
  SessionStore? sessionStore,
  void Function(FakeLibraryRepository repo)? configure,
  Future<void> Function(FakeLibraryRepository repo)? seed,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final FakeLibraryRepository repository = FakeLibraryRepository(
    tracks: tracks,
  );
  configure?.call(repository);
  if (seed != null) {
    await seed(repository);
  }

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: LibraryPage(
        repository: repository,
        playbackService: playback ?? FakePlaybackService(),
        directoryPicker: directoryPicker,
        musicFolderStore: folderStore,
        sessionStore: sessionStore ?? FakeSessionStore(),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return repository;
}

List<Track> twoTracks() => <Track>[
  sampleTrack(title: '夜航', artist: '林间电台', album: '夜之专辑'),
  sampleTrack(title: '潮汐', artist: '海岸线', album: '玻璃海', durationSecs: 200),
];

void main() {
  testWidgets('展示曲目列表与数量', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    expect(find.text('2 首音乐'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);
    expect(find.text('夜之专辑'), findsOneWidget);
    // 两行都在虚拟列表里
    expect(find.text('03:00'), findsWidgets);
  });

  testWidgets('空曲库展示空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: const <Track>[]);

    expect(find.text('曲库还是空的'), findsOneWidget);
    expect(find.text('重新读取'), findsOneWidget);
  });

  testWidgets('升级后缺封面时自动补扫已添加目录一次', (WidgetTester tester) async {
    final FakeMusicFolderStore folders = FakeMusicFolderStore(
      folders: <String>[r'D:\Music'],
    );
    final FakeSessionStore session = FakeSessionStore(
      snapshot: const SessionSnapshot(coverBackfillAttempted: false),
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      folderStore: folders,
      sessionStore: session,
    );

    expect(repository.scannedFolders, <String>[r'D:\Music']);
    expect(session.snapshot.coverBackfillAttempted, isTrue);
    expect(find.byType(SnackBar), findsNothing, reason: '补扫应静默进行');
  });

  testWidgets('已尝试过补扫时启动不再自动扫描', (WidgetTester tester) async {
    final FakeMusicFolderStore folders = FakeMusicFolderStore(
      folders: <String>[r'D:\Music'],
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      folderStore: folders,
    );

    expect(repository.scannedFolders, isEmpty);
  });

  testWidgets('空曲库可添加音乐目录并触发扫描', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: const <Track>[],
      directoryPicker: () async => ' /music ',
    );

    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(repository.scannedFolders, <String>['/music']);
    expect(repository.loadCalls, 2, reason: '扫描后应重新读取曲库');
    expect(find.textContaining('扫描完成'), findsOneWidget);
  });

  testWidgets('读取失败展示错误态，重试后恢复', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      configure: (FakeLibraryRepository repo) {
        repo.loadError = Exception('数据库打不开');
      },
    );

    expect(find.text('曲库读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    repository.loadError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('夜航'), findsOneWidget);
  });

  testWidgets('搜索输入防抖 300ms 后才发起请求', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );

    await tester.enterText(find.byType(TextField), '夜');
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.searchCalls, 0, reason: '防抖窗口内不应请求');

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(repository.searchCalls, 1);
    expect(repository.lastQuery, '夜');
    expect(find.text('找到 1 首'), findsOneWidget);
    expect(find.text('潮汐'), findsNothing);
  });

  testWidgets('清空搜索恢复完整列表', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.enterText(find.byType(TextField), '夜');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('潮汐'), findsNothing);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    expect(find.text('2 首音乐'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);
  });

  testWidgets('搜索无结果展示空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.enterText(find.byType(TextField), '不存在的歌');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('没有找到匹配的音乐'), findsOneWidget);
  });

  testWidgets('搜索失败展示错误态，重试后恢复', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    repository.searchError = Exception('FTS 语法错误');

    await tester.enterText(find.byType(TextField), '夜');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('搜索失败'), findsOneWidget);

    repository.searchError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('找到 1 首'), findsOneWidget);
  });

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

  testWidgets('侧边导航可收起与展开', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开导航栏'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);

    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.menu_open), findsOneWidget);
  });

  testWidgets('侧边栏顶部显示应用图标与名称，并贴住窗口顶部', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    final Finder rail = find.byType(LibraryRail);
    expect(tester.getTopLeft(rail).dy, 0, reason: '侧栏应一直画到窗口顶部');
    expect(find.text('Lamp Player'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
      findsOneWidget,
    );

    final Offset brandCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
    );
    final Offset toggleCenter = tester.getCenter(find.byTooltip('收起导航栏'));
    expect(
      brandCenter.dx,
      closeTo(toggleCenter.dx, 0.01),
      reason: '品牌图标应与折叠按钮同一中轴',
    );

    final Rect brandRect = tester.getRect(find.text('Lamp Player'));
    expect(brandRect.top, greaterThanOrEqualTo(0));
    expect(
      brandRect.bottom,
      lessThanOrEqualTo(LampTitleBar.height),
      reason: '品牌名应落在标题条高度内',
    );
  });

  testWidgets('侧边栏收起有宽度过渡动画', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    final Finder rail = find.byType(LibraryRail);
    expect(tester.getSize(rail).width, LibraryRail.expandedWidth);

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final double midWidth = tester.getSize(rail).width;
    expect(midWidth, greaterThan(LibraryRail.collapsedWidth));
    expect(midWidth, lessThan(LibraryRail.expandedWidth));

    await tester.pumpAndSettle();
    expect(tester.getSize(rail).width, LibraryRail.collapsedWidth);
  });

  testWidgets('收起侧边栏后只显示图标，并与折叠按钮对齐', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    final Finder rail = find.byType(LibraryRail);
    expect(
      tester.getSize(rail).width,
      LibraryRail.collapsedWidth,
      reason: '收起后应收窄到图标宽度',
    );
    for (final String label in <String>[
      '音乐',
      '歌单',
      '历史',
      '收藏',
      '艺术家',
      '专辑',
      '设置',
    ]) {
      expect(
        find.descendant(of: rail, matching: find.text(label)),
        findsNothing,
        reason: '收起后不应再显示「$label」',
      );
    }

    expect(find.text('Lamp Player'), findsNothing, reason: '收起后品牌名应隐藏');
    expect(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
      findsOneWidget,
      reason: '收起后品牌图标应保留',
    );

    final Offset toggleCenter = tester.getCenter(find.byTooltip('展开导航栏'));
    final Offset musicCenter = tester.getCenter(
      find.descendant(of: rail, matching: find.byIcon(Icons.music_note)),
    );
    final Offset brandCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
    );
    expect(musicCenter.dx, closeTo(toggleCenter.dx, 0.01), reason: '应在同一中轴');
    expect(
      brandCenter.dx,
      closeTo(toggleCenter.dx, 0.01),
      reason: '品牌图标也应在同一中轴',
    );
  });

  testWidgets('点击侧边栏切换分区有淡入淡出过渡', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    expect(find.text('2 首音乐'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('2 首音乐'), findsOneWidget, reason: '旧分区应在淡出');
    expect(find.text('曲目数量'), findsOneWidget, reason: '新分区应已挂载');

    await tester.pumpAndSettle();
    expect(find.text('2 首音乐'), findsNothing);
    expect(find.text('曲目数量'), findsOneWidget);
  });

  testWidgets('从详情点击当前分区返回列表也有过渡', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        ...twoTracks(),
        sampleTrack(title: '灯下', artist: '林间电台', album: '夜之专辑'),
      ],
    );
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('林间电台'));
    await tester.pumpAndSettle();
    expect(find.text('1 张专辑 · 2 首音乐'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('艺术家')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('1 张专辑 · 2 首音乐'), findsOneWidget, reason: '详情应在淡出');
    expect(find.text('2 位艺术家'), findsOneWidget, reason: '列表应已挂载');

    await tester.pumpAndSettle();
    expect(find.text('1 张专辑 · 2 首音乐'), findsNothing);
    expect(find.text('2 位艺术家'), findsOneWidget);
  });

  testWidgets('侧边栏包含七个入口', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    for (final String label in <String>[
      '音乐',
      '歌单',
      '历史',
      '收藏',
      '艺术家',
      '专辑',
      '设置',
    ]) {
      expect(
        find.descendant(
          of: find.byType(LibraryRail),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: '侧边栏缺少「$label」',
      );
    }
  });

  testWidgets('歌单分区可新建歌单并展示卡片', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);

    expect(find.text('还没有歌单'), findsOneWidget);
    expect(find.text('0 个歌单'), findsOneWidget);

    await createPlaylistThroughUi(tester, '深夜通勤');

    expect(find.text('深夜通勤'), findsOneWidget);
    expect(find.text('1 个歌单'), findsOneWidget);
    expect(find.byTooltip('歌单操作'), findsOneWidget);
  });

  testWidgets('新建歌单校验空名与重名', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);

    await tester.tap(find.text('新建歌单').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('歌单名不能为空'), findsOneWidget);

    await tester.enterText(playlistNameField, '通勤');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('通勤'), findsOneWidget);

    await tester.tap(find.text('新建歌单').first);
    await tester.pumpAndSettle();
    await tester.enterText(playlistNameField, '通勤');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('已有同名歌单'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('歌单详情可添加曲目、从歌单移除', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);
    await createPlaylistThroughUi(tester, '通勤');

    await tester.tap(find.text('通勤'));
    await tester.pumpAndSettle();
    expect(find.text('歌单还是空的'), findsOneWidget);

    await tester.tap(find.text('添加音乐').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byTooltip('添加到歌单'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('夜航'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从歌单中移除'));
    await tester.pumpAndSettle();

    expect(find.text('歌单还是空的'), findsOneWidget);
  });

  testWidgets('歌单卡片可删除歌单', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);
    await createPlaylistThroughUi(tester, '通勤');

    await tester.tap(find.byTooltip('歌单操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除歌单'));
    await tester.pumpAndSettle();

    expect(find.text('删除「通勤」？'), findsOneWidget);
    await tester.tap(find.text('删除歌单'));
    await tester.pumpAndSettle();

    expect(find.text('还没有歌单'), findsOneWidget);
    expect(find.text('0 个歌单'), findsOneWidget);
  });

  testWidgets('收藏分区空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openFavorites(tester);

    expect(find.text('0 首收藏'), findsOneWidget);
    expect(find.text('还没有收藏'), findsOneWidget);
  });

  testWidgets('在音乐列表收藏后可出现在收藏页，取消后回到空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(find.byTooltip('收藏').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await openFavorites(tester);
    expect(find.text('1 首收藏'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();

    expect(find.text('还没有收藏'), findsOneWidget);
    expect(find.text('0 首收藏'), findsOneWidget);
  });

  testWidgets('历史分区空态且清空按钮禁用', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openHistory(tester);

    expect(find.text('0 条播放记录'), findsOneWidget);
    expect(find.text('还没有播放记录'), findsOneWidget);
    final OutlinedButton clearButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '清空历史'),
    );
    expect(clearButton.onPressed, isNull);
  });

  testWidgets('历史按最近播放排序展示', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.recordPlay('/music/夜航.mp3');
        await repo.recordPlay('/music/潮汐.mp3');
      },
    );
    await openHistory(tester);

    expect(find.text('2 条播放记录'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);

    final double recentY = tester.getTopLeft(find.text('潮汐')).dy;
    final double olderY = tester.getTopLeft(find.text('夜航')).dy;
    expect(recentY, lessThan(olderY), reason: '最近播放的应排在前面');
  });

  testWidgets('清空历史需确认，确认后回到空态', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.recordPlay('/music/夜航.mp3');
      },
    );
    await openHistory(tester);

    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();
    expect(find.text('清空播放历史？'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('0 条播放记录'), findsOneWidget);
    expect(find.text('还没有播放记录'), findsOneWidget);
  });

  testWidgets('设置分区展示真实曲库统计与引擎状态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    expect(find.text('曲目数量'), findsOneWidget);
    expect(find.text('2 首'), findsOneWidget);
    expect(find.text('不可用（未加载 BASS）'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
  });

  testWidgets('艺术家分区可聚合并进入详情、返回', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[
      ...twoTracks(),
      sampleTrack(title: '灯下', artist: '林间电台', album: '夜之专辑'),
    ];
    await pumpLibrary(tester, tracks: tracks);

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();

    expect(find.text('2 位艺术家'), findsOneWidget);
    expect(find.text('1 张专辑 · 2 首'), findsOneWidget);

    await tester.tap(find.text('林间电台'));
    await tester.pumpAndSettle();

    expect(find.text('1 张专辑 · 2 首音乐'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('2 位艺术家'), findsOneWidget);
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

  testWidgets('设置页列出已添加目录，可重新扫描', (WidgetTester tester) async {
    final FakeMusicFolderStore store = FakeMusicFolderStore(
      folders: <String>[r'D:\Music', r'E:\Songs'],
    );
    final FakeLibraryRepository repo = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      folderStore: store,
    );
    await openSettings(tester);

    expect(find.text(r'D:\Music'), findsOneWidget);
    expect(find.text(r'E:\Songs'), findsOneWidget);

    await tester.tap(find.byTooltip('重新扫描').first);
    await tester.pumpAndSettle();

    expect(repo.scannedFolders, <String>[r'D:\Music']);
  });

  testWidgets('移除目录后从列表消失并写回存储', (WidgetTester tester) async {
    final FakeMusicFolderStore store = FakeMusicFolderStore(
      folders: <String>[r'D:\Music'],
    );
    await pumpLibrary(tester, tracks: twoTracks(), folderStore: store);
    await openSettings(tester);

    await tester.tap(find.byTooltip('从列表移除'));
    await tester.pumpAndSettle();

    expect(find.text(r'D:\Music'), findsNothing);
    expect(store.folders, isEmpty);
    expect(find.text('还没有添加音乐目录，先在上方添加一个'), findsOneWidget);
  });

  testWidgets('添加目录会写回存储并立即扫描', (WidgetTester tester) async {
    final FakeMusicFolderStore store = FakeMusicFolderStore();
    final FakeLibraryRepository repo = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      folderStore: store,
      directoryPicker: () async => r'F:\NewMusic',
    );
    await openSettings(tester);

    await tester.ensureVisible(find.text('添加音乐目录'));
    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(store.folders, <String>[r'F:\NewMusic']);
    expect(repo.scannedFolders, <String>[r'F:\NewMusic']);
    // 目录行与扫描结果摘要各出现一次
    expect(find.text(r'F:\NewMusic'), findsWidgets);
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

  testWidgets('音乐分区右键加入歌单能看到已有歌单', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('晨间');
      },
    );

    // 页面停在「音乐」分区，从未进入歌单页
    await tester.tap(find.text('夜航').first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入歌单…'));
    await tester.pumpAndSettle();

    expect(find.text('晨间'), findsOneWidget, reason: '应能列出已有歌单');
    expect(find.text('还没有歌单，点右下角新建一个。'), findsNothing);

    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();
    expect(find.text('已加入「晨间」'), findsOneWidget);
  });

  testWidgets('启动时恢复上次选择的排序方式', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: 'B 曲', artist: '甲'),
        sampleTrack(title: 'A 曲', artist: '乙'),
      ],
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(sort: LibrarySort.title),
      ),
    );

    expect(find.text('排序：标题'), findsOneWidget);
    final double aY = tester.getTopLeft(find.text('A 曲')).dy;
    final double bY = tester.getTopLeft(find.text('B 曲')).dy;
    expect(aY, lessThan(bY), reason: '应按标题排序，而不是保留默认顺序');
  });

  testWidgets('切换排序方式会写回会话', (WidgetTester tester) async {
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(tester, tracks: twoTracks(), sessionStore: session);

    await tester.tap(find.textContaining('排序：'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题').last);
    await tester.pumpAndSettle();

    expect(find.text('排序：标题'), findsOneWidget);
    expect(session.snapshot.sort, LibrarySort.title);
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

  testWidgets('拖入文件夹会复用扫描流程并显示导入结果', (WidgetTester tester) async {
    final Directory dropped = Directory.systemTemp.createTempSync('lamp_drop_');
    addTearDown(() => dropped.deleteSync(recursive: true));

    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: const <Track>[],
    );

    Future<void> sendDropEvent(String method, Object arguments) async {
      final ByteData data = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop',
        data,
        (ByteData? _) {},
      );
    }

    await sendDropEvent('entered', <double>[100, 100]);
    await tester.pump();
    expect(find.text('松开即可导入音乐'), findsOneWidget);

    await sendDropEvent('performOperation', <String>[dropped.path]);
    await tester.pumpAndSettle();

    expect(find.text('松开即可导入音乐'), findsNothing);
    expect(repository.scannedFolders, <String>[dropped.path]);
    expect(find.textContaining('导入完成'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

Finder get playlistNameField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> openPlaylists(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('歌单')),
  );
  await tester.pumpAndSettle();
}

Future<void> createPlaylistThroughUi(WidgetTester tester, String name) async {
  await tester.tap(find.text('新建歌单').first);
  await tester.pumpAndSettle();
  await tester.enterText(playlistNameField, name);
  await tester.tap(find.text('创建'));
  await tester.pumpAndSettle();
}

Future<void> openFavorites(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('收藏')),
  );
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
  );
  await tester.pumpAndSettle();
}

Future<void> openHistory(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('历史')),
  );
  await tester.pumpAndSettle();
}

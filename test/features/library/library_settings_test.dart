import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app_lifecycle.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/common/widgets/cover_shape.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/features/settings/listening_stats_repository.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/features/settings/listening_stats_view.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
  testWidgets('设置分区展示真实曲库统计', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    expect(find.text('曲目数量'), findsOneWidget);
    expect(find.text('2 首'), findsOneWidget);

    // 新增独占 / 设备 / ReplayGain / 淡变几行后设置页更长，外观分区要滚得更多
    await tester.drag(find.byType(SettingsView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
  });

  testWidgets('听歌统计是设置里的子界面：侧栏与播放岛仍在，可退回列表', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      statsRepository: _FakeStatsRepository(),
    );
    await openSettings(tester);

    await tester.tap(find.text('听歌统计'));
    await tester.pumpAndSettle();

    expect(find.byType(ListeningStatsView), findsOneWidget);
    expect(find.text('累计听歌'), findsOneWidget, reason: '统计内容真的加载了');
    expect(find.byType(LibraryRail), findsOneWidget, reason: '左侧栏还在');
    expect(find.byType(PlayerBar), findsOneWidget, reason: '底部播放岛还在');
    expect(find.text('常听歌曲'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('stats-back')));
    await tester.pumpAndSettle();

    expect(find.byType(ListeningStatsView), findsNothing);
    expect(find.text('曲目数量'), findsOneWidget, reason: '回到设置列表');
    expect(find.byType(LibraryRail), findsOneWidget);
  });

  testWidgets('Esc 从听歌统计退回设置列表', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      statsRepository: _FakeStatsRepository(),
    );
    await openSettings(tester);

    await tester.tap(find.text('听歌统计'));
    await tester.pumpAndSettle();
    expect(find.byType(ListeningStatsView), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ListeningStatsView), findsNothing, reason: 'Esc 退回设置列表');
    expect(find.text('曲目数量'), findsOneWidget);
  });

  testWidgets('打开统计是淡入过渡，不是硬切换', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      statsRepository: _FakeStatsRepository(),
    );
    await openSettings(tester);

    await tester.tap(find.text('听歌统计'));
    await tester.pump();

    // 过渡的第一帧：新旧两份都在（旧的正在淡出）
    expect(find.byType(ListeningStatsView), findsOneWidget);
    expect(find.text('曲目数量'), findsOneWidget, reason: '设置列表正在淡出');

    await tester.pumpAndSettle();

    // 结束后只剩统计，淡出的那份被丢掉
    expect(find.byType(ListeningStatsView), findsOneWidget);
    expect(find.text('曲目数量'), findsNothing);
  });

  testWidgets('离开设置分区后再回来，统计子界面已经收起', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      statsRepository: _FakeStatsRepository(),
    );
    await openSettings(tester);
    await tester.tap(find.text('听歌统计'));
    await tester.pumpAndSettle();
    expect(find.byType(ListeningStatsView), findsOneWidget);

    // 切到音乐分区再切回来：子界面不该还开着（也不该继续占着内存）
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('音乐')),
    );
    await tester.pumpAndSettle();
    await openSettings(tester);
    await tester.pumpAndSettle();

    expect(find.byType(ListeningStatsView), findsNothing);
    expect(find.text('曲目数量'), findsOneWidget);
  });

  testWidgets('统计里点艺术家一步进详情，不先露出艺术家列表', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      statsRepository: _FakeStatsRepository(),
    );
    await openSettings(tester);
    await tester.tap(find.text('听歌统计'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('rank-tab-artists')));
    await tester.pumpAndSettle();

    final Finder row = find.byKey(const ValueKey<String>('rank-artist-林间电台'));
    // 统计页里有不止一个 Scrollable（外面这层 CustomScrollView 之外还有
    // 横向滚动的部件），必须点名用列表这层滚
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(row);
    // 一帧收掉统计、下一帧就是详情：中间不给列表留位置
    await tester.pump();
    await tester.pump();

    expect(find.byType(ListeningStatsView), findsNothing);
    expect(
      find.byKey(const PageStorageKey<String>('grid:artists')),
      findsNothing,
      reason: '艺术家列表不该闪一下再跳走',
    );
    expect(find.text('播放全部'), findsOneWidget, reason: '直接就是艺术家详情');

    await tester.pumpAndSettle();
    expect(find.text('播放全部'), findsOneWidget);
    expect(
      find.byKey(const PageStorageKey<String>('grid:artists')),
      findsNothing,
    );
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

  testWidgets('设置页可开启独占输出并写回会话', (WidgetTester tester) async {
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
      // 新增「清理缺失文件」行后设置页更长，独占开关需要更高的视口
      viewSize: const Size(1280, 1400),
    );
    await openSettings(tester);

    await tester.ensureVisible(find.text('独占输出（WASAPI）'));
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-exclusive-switch')),
    );
    await tester.pumpAndSettle();

    expect(playback.exclusiveCalls, 1);
    expect(playback.exclusive, isTrue);
    expect(store.snapshot.exclusiveOutput, isTrue);
    expect(find.text('正在独占'), findsOneWidget);
  });

  testWidgets('启动时按会话恢复独占输出', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(exclusiveOutput: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(playback.exclusiveCalls, 1, reason: '启动时应把偏好告诉引擎');
    expect(playback.exclusive, isTrue);
  });

  testWidgets('切换独占失败时开关回滚并提示', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..exclusiveError = StateError('设备被其他进程独占');
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      viewSize: const Size(1280, 1400),
    );
    await openSettings(tester);

    await tester.ensureVisible(find.text('独占输出（WASAPI）'));
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-exclusive-switch')),
    );
    await tester.pumpAndSettle();

    expect(playback.exclusive, isFalse);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey<String>('settings-exclusive-switch')),
          )
          .value,
      isFalse,
      reason: '失败后开关应回到关闭',
    );
    expect(find.textContaining('切换输出失败'), findsOneWidget);
  });

  testWidgets('引擎不可用时独占开关禁用', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: false),
    );
    await openSettings(tester);

    await tester.ensureVisible(find.text('独占输出（WASAPI）'));
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey<String>('settings-exclusive-switch')),
          )
          .onChanged,
      isNull,
    );
  });

  testWidgets('设置页切换关闭到托盘会写进 AppLifecycle', (WidgetTester tester) async {
    final AppLifecycle lifecycle = AppLifecycle();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: true),
      lifecycle: lifecycle,
      // 设置页比默认视口高：调高视口，避免最后一行被播放条压住
      // （新增「快捷键」一行后又要再高一点）
      viewSize: const Size(1280, 1240),
    );
    await openSettings(tester);

    await tester.ensureVisible(find.text('关闭窗口时留在托盘'));
    expect(lifecycle.closeToTray, isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('settings-close-to-tray-switch')),
    );
    await tester.pumpAndSettle();

    expect(lifecycle.closeToTray, isFalse);
    // 说明文字常显，不随开关变化
    expect(find.text('点 × 只隐藏窗口'), findsOneWidget);
  });

  testWidgets('开启均衡器会下发给引擎并写回会话', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(isAvailable: true);
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
      viewSize: const Size(1280, 1400),
    );
    await openSettings(tester);

    // 均衡器改到独立页：先点入口，再在页面里打开开关
    await tester.ensureVisible(find.text('均衡器'));
    await tester.tap(find.text('均衡器'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('equalizer-enable')));
    await tester.pumpAndSettle();

    expect(playback.eqCalls, greaterThan(0));
    expect(playback.eqEnabled, isTrue);
    expect(playback.eqGains, hasLength(10));
    expect(session.snapshot.eqEnabled, isTrue);
  });

  testWidgets('音量过渡开关写回会话并下发给引擎', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(isAvailable: true);
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
    );
    await openSettings(tester);

    final Finder toggle = find.byKey(
      const ValueKey<String>('settings-volume-fade-switch'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();

    expect(session.snapshot.volumeFade, isTrue, reason: '默认开启');
    expect(
      playback.volumeFadeCalls.contains(true),
      isTrue,
      reason:
          '启动时要把开关下发给引擎（探测回调与 bootstrap 可能各发一次，'
          '第二次才是会话恢复后的权威值）',
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(session.snapshot.volumeFade, isFalse);
    expect(playback.volumeFadeCalls.last, isFalse, reason: '开关要写回引擎');
  });

  testWidgets('圆形封面开关会写回会话并立刻作用到全局封面', (WidgetTester tester) async {
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      sessionStore: session,
      viewSize: const Size(1280, 1400),
    );
    addTearDown(() => circularCovers.value = false);
    await openSettings(tester);

    final Finder toggle = find.byKey(
      const ValueKey<String>('settings-circular-cover-switch'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(circularCovers.value, isFalse, reason: '默认关闭');
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(circularCovers.value, isTrue);
    expect(session.snapshot.circularCovers, isTrue);
  });

  testWidgets('清理缺失文件只删记录并展示清理条数', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      configure: (FakeLibraryRepository repo) {
        repo.prunedPaths.add('/music/夜航.mp3');
      },
    );
    await openSettings(tester);

    await tester.tap(find.text('清理缺失文件'));
    await tester.pumpAndSettle();

    expect(repository.pruneCalls, 1);
    expect(repository.tracks, hasLength(1));
    expect(find.text('1 首'), findsOneWidget, reason: '曲目数量应跟着刷新');
    expect(find.text('已清理 1 条缺失记录'), findsWidgets);
  });

  testWidgets('清理缺失文件被存储层拒绝时展示错误', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      configure: (FakeLibraryRepository repo) {
        repo.pruneError = StateError('曲库目录似乎不可用，已拒绝清理');
      },
    );
    await openSettings(tester);

    await tester.tap(find.text('清理缺失文件'));
    await tester.pumpAndSettle();

    expect(repository.pruneCalls, 1);
    expect(repository.tracks, hasLength(2), reason: '拒绝清理时不能动列表');
    expect(find.text('清理失败'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('已拒绝清理'),
      ),
      findsOneWidget,
      reason: '拒绝清理的原因要弹出来，不能静默当成 0 条',
    );
  });

  testWidgets('退出前会把播放会话落盘', (WidgetTester tester) async {
    final AppLifecycle lifecycle = AppLifecycle();
    final FakeSessionStore session = FakeSessionStore();
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
      lifecycle: lifecycle,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 模拟「窗口即将关闭」：把会话清空，退出钩子应把最新状态写回去
    session.snapshot = const SessionSnapshot();
    await lifecycle.runBeforeExit();

    expect(session.snapshot.lastTrackPath, '/music/夜航.mp3');
    expect(session.snapshot.section, 'music');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('设置页「快捷键」打开弹窗，列出当前键位', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('快捷键'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('shortcuts-dialog')),
      findsOneWidget,
      reason: '是浮在设置上面的弹窗，不是新页面',
    );
    expect(find.byType(LibraryRail), findsOneWidget, reason: '左侧栏没被顶掉');
    expect(find.text('播放 / 暂停'), findsOneWidget);
    expect(find.text('空格'), findsOneWidget);
    expect(find.text('Ctrl + ←'), findsOneWidget, reason: '上一首');
    expect(find.text('Ctrl + →'), findsOneWidget, reason: '下一首');
    expect(find.text('恢复默认'), findsOneWidget);
    expect(find.textContaining('点击任意一行'), findsOneWidget);
  });

  testWidgets('改键后立即生效并写回会话', (WidgetTester tester) async {
    final FakeSessionStore session = FakeSessionStore();
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: session,
    );
    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(playback.pauseCalls, 0);

    await openSettings(tester);
    await tester.ensureVisible(find.text('快捷键'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();

    // 点「播放 / 暂停」那一行，再按 Ctrl+P
    await tester.tap(find.text('播放 / 暂停'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正在录制'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Ctrl + P'), findsOneWidget, reason: '键帽要跟着更新');
    expect(session.snapshot.shortcutsJson, isNotEmpty, reason: '要写回会话');

    // 关掉弹窗回到曲库页，Ctrl+P 应当能暂停
    await tester.tap(find.byKey(const ValueKey<String>('shortcuts-close')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(playback.pauseCalls, 1, reason: '改过的键位要真的生效');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// 统计子界面的假数据源：只给最小可用的一份，够断言「内容真的渲染了」
class _FakeStatsRepository implements ListeningStatsRepository {
  @override
  Future<PlayStats> playStats() async => const PlayStats(
    totalSeconds: 3600,
    totalPlays: 12,
    trackCount: 3,
    activeDays: 1,
  );

  @override
  Future<List<TrackPlayStat>> topTracks({int limit = 100}) async =>
      <TrackPlayStat>[TrackPlayStat(track: sampleTrack(title: '夜航'), plays: 5)];

  @override
  Future<List<ArtistPlayStat>> topArtists({int limit = 100}) async =>
      <ArtistPlayStat>[ArtistPlayStat(artist: '林间电台', plays: 5, trackCount: 1)];

  @override
  Future<List<DailyPlaytime>> dailyPlaytime(int sinceDay) async =>
      const <DailyPlaytime>[];
}

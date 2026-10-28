import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app_lifecycle.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
  testWidgets('设置分区展示真实曲库统计与引擎状态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    expect(find.text('曲目数量'), findsOneWidget);
    expect(find.text('2 首'), findsOneWidget);
    expect(find.text('不可用（未加载 BASS）'), findsOneWidget);

    // 新增独占 / 设备 / ReplayGain / 淡变几行后设置页更长，外观分区要滚得更多
    await tester.drag(find.byType(SettingsView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
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
    expect(find.text('设备由本应用独占，系统混音器不再参与'), findsOneWidget);
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

  testWidgets('进入设置页会重新读取输出信息', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
    final int before = playback.outputInfoCalls;

    await openSettings(tester);
    await tester.pumpAndSettle();

    expect(
      playback.outputInfoCalls,
      greaterThan(before),
      reason: '空闲释放 / 回落共享都可能改变实际输出，进设置页要重读',
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
    expect(find.text('点 × 直接退出应用'), findsOneWidget);
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

  testWidgets('设置页「快捷键」打开编辑页，列出当前键位', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('快捷键'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();

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

    // 返回曲库页，Ctrl+P 应当能暂停
    await tester.pageBack();
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

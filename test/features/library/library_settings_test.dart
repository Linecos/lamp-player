import 'package:flutter/material.dart';
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

    // 新增独占行后设置页变长，外观分区要滚动才在视口内
    await tester.drag(find.byType(SettingsView), const Offset(0, -400));
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
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
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
      viewSize: const Size(1280, 1100),
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
}

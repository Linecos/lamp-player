import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app_lifecycle.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/app/window_controls.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/features/library/music_tag.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/features/settings/listening_stats_repository.dart';
import 'package:lamp_player/src/features/settings/music_folder_store.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import 'fake_library.dart';

/// 曲库页测试的公共脚手架。
///
/// 各分区测试文件都从这里 `pumpLibrary`，避免每个文件复制一遍注入参数。

Future<FakeLibraryRepository> pumpLibrary(
  WidgetTester tester, {
  List<Track>? tracks,
  FakePlaybackService? playback,
  DirectoryPicker? directoryPicker,
  MusicFolderStore? folderStore,
  SessionStore? sessionStore,
  AppLifecycle? lifecycle,
  WindowControls? windowControls,
  MusicTagLauncher? musicTagLauncher,
  ListeningStatsRepository? statsRepository,
  Size viewSize = const Size(1280, 800),
  bool prefetchReplayGain = true,

  /// 传了就在外面套一层 ThemeScope：只有「跟随封面」等需要读主题状态的用例才用
  ThemeController? themeController,
  void Function(FakeLibraryRepository repo)? configure,
  Future<void> Function(FakeLibraryRepository repo)? seed,
}) async {
  tester.view.physicalSize = viewSize;
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

  final Widget app = MaterialApp(
    theme: AppTheme.light(AppTheme.defaultSeed),
    home: LibraryPage(
      repository: repository,
      playbackService: playback ?? FakePlaybackService(),
      directoryPicker: directoryPicker,
      musicFolderStore: folderStore,
      sessionStore: sessionStore ?? FakeSessionStore(),
      appLifecycle: lifecycle,
      windowControls: windowControls,
      musicTagLauncher: musicTagLauncher,
      statsRepository: statsRepository,
      prefetchReplayGain: prefetchReplayGain,
    ),
  );
  await tester.pumpWidget(
    themeController == null
        ? app
        : ThemeScope(controller: themeController, child: app),
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return repository;
}

List<Track> twoTracks() => <Track>[
  sampleTrack(title: '夜航', artist: '林间电台', album: '夜之专辑'),
  sampleTrack(title: '潮汐', artist: '海岸线', album: '玻璃海', durationSecs: 200),
];

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

/// 直接切到「音乐库」分区（目录、隐藏、清理与听歌统计都在里面）
Future<void> openLibrarySettings(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('音乐库')),
  );
  await tester.pumpAndSettle();
}

Future<void> openHistory(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('历史')),
  );
  await tester.pumpAndSettle();
}

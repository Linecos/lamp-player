import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

Future<FakeLibraryRepository> pumpLibrary(
  WidgetTester tester, {
  List<Track>? tracks,
  FakePlaybackService? playback,
  DirectoryPicker? directoryPicker,
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

  testWidgets('自然播完后按播放会重新开始而不是 resume', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(playback.playedPaths.length, 1);

    // 模拟 BASS 自然播完：状态 stopped、位置停在结尾
    playback
      ..current = rust.PlaybackState.stopped
      ..positionSecs = 180;
    await tester.pump(const Duration(milliseconds: 550));

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.play_arrow));
    await tester.pump();

    expect(playback.playedPaths.length, 2, reason: '应重新 play 而不是 resume');
    expect(playback.resumeCalls, 0);
    expect(find.byIcon(Icons.pause), findsOneWidget);

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

    expect(playback.volumeCalls, isNotEmpty);
    expect(playback.volumeCalls.last, lessThan(1));
    expect(playback.volumeCalls.last, greaterThan(0));

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();

    expect(playback.volumeCalls.last, 0);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await tester.tap(find.byTooltip('取消静音'));
    await tester.pump();

    expect(playback.volumeCalls.last, greaterThan(0));
    expect(find.byIcon(Icons.volume_off), findsNothing);
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

Future<void> openHistory(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('历史')),
  );
  await tester.pumpAndSettle();
}

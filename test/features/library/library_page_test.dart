import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

Future<FakeLibraryRepository> pumpLibrary(
  WidgetTester tester, {
  List<Track>? tracks,
  FakePlaybackService? playback,
  void Function(FakeLibraryRepository repo)? configure,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final FakeLibraryRepository repository = FakeLibraryRepository(
    tracks: tracks,
  );
  configure?.call(repository);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: LibraryPage(
        repository: repository,
        playbackService: playback ?? FakePlaybackService(),
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
    expect(find.textContaining('播放引擎未接入'), findsWidgets);

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('播放引擎尚未接入'), findsOneWidget);
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

  testWidgets('歌单分区明确标注待接入', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('歌单')),
    );
    await tester.pumpAndSettle();

    expect(find.text('歌单还没有接入'), findsOneWidget);
    expect(find.text('待接入'), findsOneWidget);
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
}

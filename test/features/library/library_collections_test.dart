import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lamp_player/src/features/player/player_bar.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
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

  testWidgets('正在播放页点歌手，退出播放页并进艺术家详情', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
    await _playAndOpenNowPlaying(tester);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-artist')));
    await tester.pumpAndSettle();

    // 播放页退掉，落在「艺术家」分区的详情里
    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsNothing,
    );
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.text('林间电台'), findsWidgets);
    // 同一页里的另一位歌手不该出现在详情里
    expect(find.text('海岸线'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('正在播放页点专辑，退出播放页并进专辑详情', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
    await _playAndOpenNowPlaying(tester);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-album')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsNothing,
    );
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.text('夜之专辑'), findsWidgets);
    expect(find.text('玻璃海'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// 播一首并打开正在播放页：后面的跳转测试都从这一步开始
Future<void> _playAndOpenNowPlaying(WidgetTester tester) async {
  await tester.tap(find.text('夜航'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  // 点播放条上的曲名（左段中央是播放键，别点正中）
  await tester.tap(
    find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('now-playing-header')),
    findsOneWidget,
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

Finder get _selectionToggle =>
    find.byKey(const ValueKey<String>('library-selection-toggle'));

Future<void> _enterSelection(WidgetTester tester) async {
  await tester.tap(_selectionToggle);
  await tester.pumpAndSettle();
}

Future<void> _selectAll(WidgetTester tester) async {
  await tester.tap(find.text('全选'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点「多选」进入多选，点击行只选择不播放', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    expect(find.byType(Checkbox), findsNothing, reason: '普通模式不显示复选框');

    await _enterSelection(tester);
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('已选 0 首'), findsOneWidget);

    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsOneWidget);
    expect(playback.playedPaths, isEmpty, reason: '多选模式下点击不播放');

    await tester.tap(find.text('潮汐'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 首'), findsOneWidget);

    // 再点一次同一行取消选择
    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsOneWidget);

    await tester.tap(_selectionToggle);
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('已选'), findsNothing);
  });

  testWidgets('Ctrl 点击直接进入多选，Shift 点击选中范围', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
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

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('夜航'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.text('已选 1 首'), findsOneWidget);
    expect(playback.playedPaths, isEmpty, reason: 'Ctrl 点击不应触发播放');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('灯下'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('已选 3 首'), findsOneWidget, reason: 'Shift 应从锚点选中整段范围');
  });

  testWidgets('全选 / 取消全选作用于当前列表', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _enterSelection(tester);

    await _selectAll(tester);
    expect(find.text('已选 2 首'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 首'), findsOneWidget);
  });

  testWidgets('批量收藏与取消收藏', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    await _enterSelection(tester);
    await _selectAll(tester);

    await tester.tap(find.byTooltip('收藏所选'));
    await tester.pumpAndSettle();

    expect(await repository.loadFavoritePaths(), <String>{
      '/music/夜航.mp3',
      '/music/潮汐.mp3',
    });
    expect(find.text('已收藏 2 首'), findsOneWidget);
    expect(find.byTooltip('取消收藏所选'), findsOneWidget);

    await tester.tap(find.byTooltip('取消收藏所选'));
    await tester.pumpAndSettle();

    expect(await repository.loadFavoritePaths(), isEmpty);
    expect(find.text('已取消收藏 2 首'), findsOneWidget);
  });

  testWidgets('批量加入歌单', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('晨间');
      },
    );
    await _enterSelection(tester);
    await _selectAll(tester);

    await tester.tap(find.byTooltip('加入歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    final List<Playlist> playlists = await repository.loadPlaylists();
    expect(playlists.single.trackCount, 2);
    expect(find.text('已加入 2 首到「晨间」'), findsOneWidget);
  });

  testWidgets('从曲库移除所选只删记录并退出多选', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    await _enterSelection(tester);
    await _selectAll(tester);

    await tester.tap(find.byTooltip('从曲库移除'));
    await tester.pumpAndSettle();

    expect(find.text('从曲库移除 2 首？'), findsOneWidget);
    expect(find.textContaining('不会删除磁盘上的音频文件'), findsOneWidget);

    await tester.tap(find.text('从曲库移除').last);
    await tester.pumpAndSettle();

    expect(repository.removeTracksCalls, 1);
    expect(repository.lastRemovedPaths, hasLength(2));
    expect(repository.tracks, isEmpty);
    expect(find.text('已从曲库移除 2 首'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing, reason: '删除后应退出多选');
    expect(find.text('曲库还是空的'), findsOneWidget);
  });

  testWidgets('歌单详情的批量移除只移出歌单，不动曲库', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/夜航.mp3');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/潮汐.mp3');
      },
    );
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    await _enterSelection(tester);
    await _selectAll(tester);

    await tester.tap(find.byTooltip('从歌单移除'));
    await tester.pumpAndSettle();
    expect(find.text('从歌单移除 2 首？'), findsOneWidget);

    await tester.tap(find.text('移除').last);
    await tester.pumpAndSettle();

    expect(repository.tracks, hasLength(2), reason: '曲库记录不能动');
    expect((await repository.loadPlaylists()).single.trackCount, 0);
    expect(find.text('已从歌单移除 2 首'), findsOneWidget);
  });

  testWidgets('多选条嵌在标题行，不把列表向下挤', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    final double listHeaderTop = tester.getTopLeft(find.text('标题')).dy;

    await _enterSelection(tester);

    final Rect bar = tester.getRect(find.text('已选 0 首'));
    final Rect playAll = tester.getRect(find.text('播放全部'));
    expect(bar.center.dy, closeTo(playAll.center.dy, 18), reason: '应与标题按钮同一行');
    expect(bar.right, lessThan(playAll.left), reason: '不能盖住右侧按钮');
    expect(
      tester.getTopLeft(find.text('标题')).dy,
      closeTo(listHeaderTop, 0.5),
      reason: '列表不应因多选条下移',
    );
  });

  testWidgets('切换分区会退出多选', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _enterSelection(tester);
    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsOneWidget);

    await openFavorites(tester);

    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('已选'), findsNothing);
  });
}

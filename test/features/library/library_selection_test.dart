import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/track_list_view.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

Finder get _selectionToggle =>
    find.byKey(const ValueKey<String>('library-selection-toggle'));

Finder get _selectAllBox =>
    find.byKey(const ValueKey<String>('track-select-all'));

Finder _rowBox(String path) =>
    find.byKey(ValueKey<String>('track-select-$path'));

Future<void> _enterSelection(WidgetTester tester) async {
  await tester.tap(_selectionToggle);
  await tester.pumpAndSettle();
}

/// 表头复选框：一键全选 / 取消全选（工具条撤掉后它成了唯一入口）
Future<void> _selectAll(WidgetTester tester) async {
  await tester.tap(_selectAllBox);
  await tester.pumpAndSettle();
}

/// 在某一行上点右键，等菜单弹出
Future<void> _rightClickRow(WidgetTester tester, String title) async {
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.down(tester.getCenter(find.text(title)));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点「多选」进入多选，点击行只选择不播放', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);

    expect(_rowBox('/music/夜航.mp3'), findsNothing, reason: '普通模式不显示复选框');

    await _enterSelection(tester);
    expect(_rowBox('/music/夜航.mp3'), findsOneWidget);
    expect(_selectAllBox, findsOneWidget, reason: '表头给一键全选');
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
    expect(_rowBox('/music/夜航.mp3'), findsNothing);
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

    // 拼音序：潮汐 → 灯下 → 夜航；锚点选第一首、Shift 落到最后一首才跨满三行
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('潮汐'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(_rowBox('/music/潮汐.mp3'), findsOneWidget);
    expect(find.text('已选 1 首'), findsOneWidget);
    expect(playback.playedPaths, isEmpty, reason: 'Ctrl 点击不应触发播放');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('夜航'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.text('已选 3 首'), findsOneWidget, reason: 'Shift 应从锚点选中整段范围');
  });

  testWidgets('表头复选框全选 / 取消全选作用于当前列表', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _enterSelection(tester);

    await _selectAll(tester);
    expect(find.text('已选 2 首'), findsOneWidget);

    await _selectAll(tester);
    expect(find.text('已选 0 首'), findsOneWidget);
  });

  testWidgets('多选时 Ctrl+A 也能全选 / 取消全选', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _enterSelection(tester);

    Future<void> ctrlA() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await ctrlA();
    expect(find.text('已选 2 首'), findsOneWidget, reason: 'Ctrl+A 与表头复选框等价');

    await ctrlA();
    expect(find.text('已选 0 首'), findsOneWidget, reason: '再按一次取消全选');
  });

  testWidgets('批量收藏与取消收藏走右键菜单', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    await _enterSelection(tester);
    await _selectAll(tester);

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('收藏所选 2 首'));
    await tester.pumpAndSettle();

    expect(await repository.loadFavoritePaths(), <String>{
      '/music/夜航.mp3',
      '/music/潮汐.mp3',
    });
    expect(find.text('已收藏 2 首'), findsOneWidget);

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('取消收藏所选 2 首'));
    await tester.pumpAndSettle();

    expect(await repository.loadFavoritePaths(), isEmpty);
    expect(find.text('已取消收藏 2 首'), findsOneWidget);
  });

  testWidgets('批量加入歌单走右键菜单', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('晨间');
      },
    );
    await _enterSelection(tester);
    await _selectAll(tester);

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('加入歌单（2 首）…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    final List<Playlist> playlists = await repository.loadPlaylists();
    expect(playlists.single.trackCount, 2);
    expect(find.text('已加入 2 首到「晨间」'), findsOneWidget);
  });

  testWidgets('右键隐藏对整批生效，只删记录并退出多选', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    await _enterSelection(tester);
    await _selectAll(tester);

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('隐藏所选 2 首'));
    await tester.pumpAndSettle();

    expect(find.text('隐藏 2 首？'), findsOneWidget);
    expect(find.textContaining('不删除磁盘上的音频文件'), findsOneWidget);

    await tester.tap(find.text('隐藏').last);
    await tester.pumpAndSettle();

    expect(repository.hideTracksCalls, 1);
    expect(repository.lastHiddenPaths, hasLength(2));
    expect(repository.tracks, isEmpty);
    expect(find.text('已隐藏 2 首'), findsOneWidget);
    expect(_rowBox('/music/夜航.mp3'), findsNothing, reason: '删除后应退出多选');
    expect(find.text('曲库还是空的'), findsOneWidget);
  });

  testWidgets('歌单详情右键批量移除只移出歌单，不动曲库', (WidgetTester tester) async {
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

    await _rightClickRow(tester, '夜航');
    await tester.tap(find.text('从歌单移除 2 首'));
    await tester.pumpAndSettle();
    expect(find.text('从歌单移除 2 首？'), findsOneWidget);

    await tester.tap(find.text('移除').last);
    await tester.pumpAndSettle();

    expect(repository.tracks, hasLength(2), reason: '曲库记录不能动');
    expect((await repository.loadPlaylists()).single.trackCount, 0);
    expect(find.text('已从歌单移除 2 首'), findsOneWidget);
  });

  testWidgets('未勾选的行右键仍只作用单曲', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    await _enterSelection(tester);
    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsOneWidget);

    await _rightClickRow(tester, '潮汐');
    expect(find.text('隐藏歌曲'), findsOneWidget, reason: '单首菜单用单数措辞');
    expect(find.textContaining('所选'), findsNothing, reason: '没勾选的行走单曲语义');

    await tester.tap(find.text('隐藏歌曲'));
    await tester.pumpAndSettle();
    expect(repository.lastHiddenPaths, <String>['/music/潮汐.mp3']);
  });

  testWidgets('已选计数留在标题行，不再有工具条按钮', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    // 排序按钮上也写着「标题」，这里只量表头那一处
    final Finder headerTitle = find.descendant(
      of: find.byType(TrackListView),
      matching: find.text('标题'),
    );
    final double listHeaderTop = tester.getTopLeft(headerTitle).dy;

    await _enterSelection(tester);

    final Rect bar = tester.getRect(find.text('已选 0 首'));
    final Rect playAll = tester.getRect(find.text('播放全部'));
    expect(bar.center.dy, closeTo(playAll.center.dy, 18), reason: '应与标题按钮同一行');
    expect(bar.right, lessThan(playAll.left), reason: '不能盖住右侧按钮');
    expect(
      tester.getTopLeft(headerTitle).dy,
      closeTo(listHeaderTop, 0.5),
      reason: '列表不应因计数下移',
    );
    expect(find.byTooltip('播放所选'), findsNothing, reason: '工具条已撤掉');
    expect(find.byTooltip('收藏所选'), findsNothing);
  });

  testWidgets('切换分区会退出多选', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _enterSelection(tester);
    await tester.tap(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsOneWidget);

    await openFavorites(tester);

    expect(_rowBox('/music/夜航.mp3'), findsNothing);
    expect(find.textContaining('已选'), findsNothing);
  });
}

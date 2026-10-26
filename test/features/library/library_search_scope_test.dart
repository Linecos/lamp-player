// 常驻搜索框的分区作用域：在哪个界面就只过滤哪个界面的内容。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

Future<void> openSection(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

Future<void> search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('专辑分区只过滤专辑，且不发起数据库搜索', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: <Track>[
        ...twoTracks(),
        sampleTrack(title: '灯下', artist: '林间电台', album: '清晨的光'),
      ],
    );
    await openSection(tester, '专辑');
    expect(find.text('3 张专辑'), findsOneWidget);

    await search(tester, '夜之');

    expect(find.text('找到 1 张专辑'), findsOneWidget);
    expect(find.text('清晨的光'), findsNothing);
    expect(repository.searchCalls, 0, reason: '内存过滤不该再查数据库');
  });

  testWidgets('艺术家分区按姓名过滤', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openSection(tester, '艺术家');
    expect(find.text('2 位艺术家'), findsOneWidget);

    await search(tester, '海岸');

    expect(find.text('找到 1 位艺术家'), findsOneWidget);
    expect(find.text('林间电台'), findsNothing);
  });

  testWidgets('收藏分区按曲目过滤，拼音首字母同样命中', (WidgetTester tester) async {
    final Track night = twoTracks().first;
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.setFavorite(night.path, true);
      },
    );
    await openFavorites(tester);
    expect(find.text('1 首收藏'), findsOneWidget);

    // 假仓库不认拼音：能命中说明走的是本地拼音兜底
    await search(tester, 'yh');

    expect(find.text('找到 1 首收藏'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget);

    await search(tester, '潮汐');
    expect(find.text('没有找到匹配的收藏'), findsOneWidget);
  });

  testWidgets('历史分区按曲目过滤', (WidgetTester tester) async {
    final List<Track> tracks = twoTracks();
    await pumpLibrary(
      tester,
      tracks: tracks,
      seed: (FakeLibraryRepository repo) async {
        await repo.recordPlay(tracks[0].path);
        await repo.recordPlay(tracks[1].path);
      },
    );
    await openHistory(tester);
    expect(find.text('2 条播放记录'), findsOneWidget);

    await search(tester, '潮汐');

    expect(find.text('找到 1 条播放记录'), findsOneWidget);
    expect(find.text('夜航'), findsNothing);
  });

  testWidgets('歌单分区按歌单名过滤', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('深夜');
        await repo.createPlaylist('清晨');
      },
    );
    await openPlaylists(tester);
    expect(find.text('2 个歌单'), findsOneWidget);

    await search(tester, '深夜');

    expect(find.text('找到 1 个歌单'), findsOneWidget);
    expect(find.text('清晨'), findsNothing);
    expect(find.text('没有找到匹配的歌单'), findsNothing);
  });

  testWidgets('切换分区会清空搜索词，不会把过滤带到另一个界面', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await search(tester, '夜');
    expect(find.text('找到 1 首'), findsOneWidget);

    await openSection(tester, '收藏');
    await openSection(tester, '音乐');

    expect(find.text('2 首音乐'), findsOneWidget, reason: '切回来应看到完整列表');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
  });

  testWidgets('搜索框提示语跟随分区，设置页禁用', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    expect(find.text('搜索音乐'), findsOneWidget);

    await openSection(tester, '专辑');
    expect(find.text('搜索专辑'), findsOneWidget);

    await openSettings(tester);
    expect(find.text('设置页无需搜索'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });
}

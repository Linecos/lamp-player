@Tags(<String>['golden'])
library;

// 曲库页的整体布局锁：播放岛收窄居中，列表铺到窗口底、行从岛下面穿过。
//
// 之前岛是全宽的，而且列表底部被整体抬高了岛的高度——行被岛的直边整条
// 横切，看起来像被一块板子压住。现在列表一直铺到窗口底，窄岛只在中间
// 挡住一段，同一行在左右两侧仍然看得见，读起来才是「悬浮」。
// 滚到底时最后一行停在岛上方，靠列表自己的底部留白（见 `TrackListView`）。
//
// 只在本地跑（CI 用 `flutter test --exclude-tags golden`）。改了播放岛宽度、
// 列表底部留白或列宽后：
//     flutter test --update-goldens test/golden

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/features/library/widgets/track_list_view.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../support/fake_library.dart';
import '../support/page_harness.dart';

List<Track> _tracks() => <Track>[
  for (int i = 1; i <= 30; i += 1)
    sampleTrack(
      title: 'Track $i',
      artist: 'Artist $i',
      album: 'Album $i',
      path: '/music/$i.mp3',
    ),
];

ScrollPosition _listPosition(WidgetTester tester) {
  return tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(TrackListView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;
}

void main() {
  testWidgets('播放岛收窄居中，列表从岛下穿过', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: _tracks(),
      viewSize: const Size(1470, 1000),
    );
    _listPosition(tester).jumpTo(300);
    await tester.pumpAndSettle();

    // 岛自身宽度封顶，且落在内容区中轴上（不是贴着侧栏）
    final Rect island = tester.getRect(find.byType(PlayerBar));
    final Rect content = tester.getRect(find.byType(TrackListView));
    expect(island.width, lessThanOrEqualTo(900));
    expect(island.center.dx, closeTo(content.center.dx, 1));

    // 列表铺到窗口底：岛后面还有内容，行才可能在两侧露出来
    expect(content.bottom, closeTo(tester.view.physicalSize.height, 1));

    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/library_page_1470x1000.png'),
    );
  });

  testWidgets('滚到底最后一行停在岛上方', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: _tracks(),
      viewSize: const Size(1470, 1000),
    );
    final ScrollPosition position = _listPosition(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    final Rect island = tester.getRect(find.byType(PlayerBar));
    // 最后一行：取列表里最后一个封面（它落在最后一行里）
    final Rect last = tester.getRect(
      find
          .descendant(
            of: find.byType(TrackListView),
            matching: find.byType(AlbumCover),
          )
          .last,
    );
    expect(last.bottom, lessThanOrEqualTo(island.top));

    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/library_page_1470x1000_bottom.png'),
    );
  });
}

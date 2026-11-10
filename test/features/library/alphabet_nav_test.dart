import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/collection_grids.dart';
import 'package:lamp_player/src/features/library/widgets/cover_flight.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

ArtistGroup _artist(String name) => ArtistGroup(
  name: name,
  tracks: <Track>[sampleTrack(title: '曲目', artist: name)],
);

AlbumGroup _album(String title, String artist) {
  final AlbumGroup group = AlbumGroup(
    key: '$artist/$title',
    title: title,
    artist: artist,
  );
  group.tracks.add(
    sampleTrack(title: '$title - 1', artist: artist, album: title),
  );
  return group;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(body: SizedBox(height: 600, child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  final List<ArtistGroup> manyArtists = <ArtistGroup>[
    for (final String letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
      for (int i = 0; i < 3; i += 1) _artist('$letter Artist $i'),
  ];

  testWidgets('艺术家按首字母分段，点字母跳到该段', (WidgetTester tester) async {
    await _pump(
      tester,
      ArtistGridView(artists: manyArtists, onSelect: (_, _) {}),
    );

    // 初始只能看到 A 段标题，后面的还没滚到
    expect(
      find.byKey(const ValueKey<String>('alphabet-header-A')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('alphabet-header-M')),
      findsNothing,
    );

    final double top = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    await tester.tap(find.byKey(const ValueKey<String>('alphabet-rail-M')));
    await tester.pumpAndSettle();

    final Finder header = find.byKey(
      const ValueKey<String>('alphabet-header-M'),
    );
    expect(header, findsOneWidget);
    // 跳转落点：该段标题正好贴着视口顶部
    expect(tester.getTopLeft(header).dy - top, lessThan(2));
  });

  testWidgets('字母导航贴最右侧但与滚动条保持距离', (WidgetTester tester) async {
    await _pump(
      tester,
      ArtistGridView(artists: manyArtists, onSelect: (_, _) {}),
    );

    final Rect rail = tester.getRect(
      find.byKey(const ValueKey<String>('alphabet-rail-A')),
    );
    final Rect viewport = tester.getRect(find.byType(CustomScrollView));

    // 导航条右缘离视口右缘还有一段距离（滚动条就贴在视口边上）
    expect(viewport.right - rail.right, greaterThanOrEqualTo(16));
    // 而且不能跑到视口外面
    expect(rail.right, lessThanOrEqualTo(viewport.right));
  });

  testWidgets('专辑按专辑名首字母分段', (WidgetTester tester) async {
    await _pump(
      tester,
      AlbumGridView(
        albums: <AlbumGroup>[
          _album('夜航', '林间电台'),
          _album('Adele 21', 'Adele'),
          _album('3 Doors', 'Various'),
        ],
        onSelect: (_, _) {},
      ),
    );

    for (final String letter in <String>['A', 'Y', '#']) {
      expect(
        find.byKey(ValueKey<String>('alphabet-header-$letter')),
        findsOneWidget,
        reason: '缺少 $letter 段',
      );
    }
  });

  testWidgets('侧栏动画途中列数不变，封面不会先变大再变小', (WidgetTester tester) async {
    // 侧栏收起时内容区从 900 连续变到 1000：按当前宽度算列数会在 944 附近
    // 多出一列（卡片先被撑大再被挤回去）。给了最终宽度后，整段过渡都是 5 列。
    final List<AlbumGroup> albums = <AlbumGroup>[
      for (int i = 0; i < 12; i += 1) _album('专辑 $i', '林间电台'),
    ];

    /// 返回「第一行有几张卡」
    Future<int> cardsInFirstRowWith(double width, double? widthHint) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.defaultSeed),
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: 600,
              child: AlbumGridView(
                albums: albums,
                onSelect: (_, _) {},
                columnWidthHint: widthHint,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder covers = find.byType(CoverFlightTarget);
      final List<Rect> rects = <Rect>[
        for (int i = 0; i < covers.evaluate().length; i += 1)
          tester.getRect(covers.at(i)),
      ];
      final double top = rects.first.top;
      return rects.where((Rect r) => (r.top - top).abs() < 1).length;
    }

    Future<int> cardsInFirstRow(double width) =>
        cardsInFirstRowWith(width, 1000);

    final List<int> counts = <int>[];
    for (final double width in <double>[868, 900, 940, 968]) {
      counts.add(await cardsInFirstRow(width));
    }

    expect(counts.toSet(), <int>{5}, reason: '动画途中列数不能跳，否则卡片会被撑大再挤回去');
  });

  testWidgets('开关侧栏时封面只单调缩放，不会先变大再变小', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[
      for (int i = 0; i < 8; i += 1)
        for (int j = 0; j < 3; j += 1)
          sampleTrack(
            title: '$i-$j',
            artist: '艺人$i',
            album: '专辑$i',
            trackNum: j + 1,
            path: '/music/$i-$j.mp3',
          ),
    ];
    // 1440 宽：展开 / 收起两种布局恰好会差一列，最容易复现那个抖动
    await pumpLibrary(tester, tracks: tracks, viewSize: const Size(1440, 900));
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('专辑')),
    );
    await tester.pumpAndSettle();

    double coverWidth() {
      final Finder cover = find.descendant(
        of: find.byType(AlbumGridView),
        matching: find.byType(CoverFlightTarget),
      );
      return tester.getSize(cover.first).width;
    }

    /// 点一下按钮，逐帧记录封面宽度
    Future<List<double>> trace(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      final List<double> widths = <double>[];
      for (int i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        widths.add(coverWidth());
      }
      await tester.pumpAndSettle();
      widths.add(coverWidth());
      return widths;
    }

    final List<double> closing = await trace('收起导航栏');
    for (int i = 1; i < closing.length; i += 1) {
      expect(
        closing[i],
        greaterThanOrEqualTo(closing[i - 1] - 0.1),
        reason: '收起侧栏时封面只能一路变大，不能回缩：${closing.join(" -> ")}',
      );
    }

    final List<double> opening = await trace('展开导航栏');
    for (int i = 1; i < opening.length; i += 1) {
      expect(
        opening[i],
        lessThanOrEqualTo(opening[i - 1] + 0.1),
        reason: '展开侧栏时封面只能一路变小，不能回弹：${opening.join(" -> ")}',
      );
    }
  });
}

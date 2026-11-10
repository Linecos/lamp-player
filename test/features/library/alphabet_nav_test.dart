import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/collection_grids.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

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
}

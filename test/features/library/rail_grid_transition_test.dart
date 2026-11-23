import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/collection_grids.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

List<Track> _albums() => <Track>[
  for (int i = 0; i < 12; i += 1)
    sampleTrack(title: '曲$i', album: '专辑$i', artist: '艺人$i'),
];

Future<void> _openAlbums(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text('专辑')),
  );
  await tester.pumpAndSettle();
}

/// 网格里第一张封面的宽度（卡片跟着列宽走，封面再扣掉卡片内边距）
double _coverWidth(WidgetTester tester) {
  return tester
      .getRect(
        find
            .descendant(
              of: find.byType(AlbumGridView),
              matching: find.byType(AlbumCover),
            )
            .first,
      )
      .width;
}

void main() {
  testWidgets('列数不变的窗口，收起侧栏时卡片跟着连续变宽', (WidgetTester tester) async {
    // 1600 宽：展开 / 收起都是 7 列，只有列宽在变。以前这里会在点下去那一帧
    // 直接换成终态几何（144.6 → 165.7），看着就是「封面先原地放大，再等侧栏走完」。
    await pumpLibrary(
      tester,
      tracks: _albums(),
      viewSize: const Size(1600, 900),
    );
    await _openAlbums(tester);

    final double before = _coverWidth(tester);
    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pump();
    expect(_coverWidth(tester), closeTo(before, 0.5), reason: '第一帧不该先把卡片放大到终态');

    final List<double> widths = <double>[];
    for (int i = 0; i < 14; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_coverWidth(tester));
    }
    await tester.pumpAndSettle();
    final double end = _coverWidth(tester);

    expect(end, greaterThan(before + 10), reason: '收起后内容区变宽，卡片该跟着变大');
    expect(widths.first, greaterThan(before), reason: '动画刚开始就该长一点');
    expect(widths.first, lessThan(end), reason: '第一帧不该已经到终值');

    // 每一帧都只走一小步：整段变化不能挤在两三帧里
    double previous = before;
    for (final double width in widths) {
      expect(
        (width - previous).abs(),
        lessThan((end - before) * 0.5),
        reason: '单帧变化过大，说明还是跳变而不是连续伸缩',
      );
      previous = width;
    }
  });

  testWidgets('列数会变的窗口，卡片在第一帧就换成终态几何', (WidgetTester tester) async {
    // 1280 宽：展开 5 列、收起 6 列。换列只能发生一次——放在动画中途会把卡片
    // 一次性缩掉二十多像素（实测 170.8 → 140.9），所以这里选择在起始那一帧换掉，
    // 之后整段动画只做「把地方让出来」，卡片不再动。
    await pumpLibrary(
      tester,
      tracks: _albums(),
      viewSize: const Size(1280, 800),
    );
    await _openAlbums(tester);

    final double before = _coverWidth(tester);
    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pump();
    final double first = _coverWidth(tester);
    expect(first, lessThan(before - 4), reason: '列数变了，第一帧就该是终态列宽');

    await tester.pumpAndSettle();
    expect(
      _coverWidth(tester),
      closeTo(first, 0.5),
      reason: '换成终态之后，动画期间不该再来回变',
    );
  });
}

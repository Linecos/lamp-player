import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/alphabet_index.dart';
import 'package:lamp_player/src/features/library/widgets/alphabet_grid.dart';

/// 卡片宽度固定，内容区一变宽就只是多一列、零头进留白；列数一变行高跟着变，
/// 而滚动偏移是像素，同一个像素在新布局里指向另一条 —— 所以要把「视口顶上
/// 是谁」换算过去。
AlphabetGridMetrics metrics({required double viewportWidth}) {
  return AlphabetGridMetrics(
    viewportWidth: viewportWidth,
    tileWidth: 220,
    tileHeight: 246,
    crossAxisSpacing: 16,
    mainAxisSpacing: 16,
    headerExtent: alphabetHeaderExtent,
    topPadding: 8,
  );
}

const List<int> counts = <int>[5, 20, 3];

void main() {
  // 开关侧栏：内容区从 680 变到 900（正好差一列）
  final AlphabetGridMetrics expanded = metrics(viewportWidth: 680);
  final AlphabetGridMetrics collapsed = metrics(viewportWidth: 900);
  final List<double> expandedOffsets = expanded.sectionOffsets(counts);

  // 窗口变窄：可用宽度只够两列
  final AlphabetGridMetrics narrow = metrics(viewportWidth: 420);
  final List<double> narrowOffsets = narrow.sectionOffsets(counts);

  test('收缩侧栏多一列，卡片尺寸基本不动', () {
    expect(collapsed.crossAxisCount, expanded.crossAxisCount + 1);
    expect(
      collapsed.childMainAxisExtent,
      expanded.childMainAxisExtent,
      reason: '行高是固定值，不该跟着内容区宽度变',
    );
    expect(
      (collapsed.childCrossAxisExtent - expanded.childCrossAxisExtent).abs(),
      lessThan(8),
      reason: '多出来的宽度用来多排一列，不该把卡片撑胖',
    );
  });

  test('锚点换算回去能得到原来的偏移', () {
    // 都在内容范围内（三段加起来约 2700）
    for (final double pixels in <double>[0, 200, 1200, 2100]) {
      final AlphabetScrollAnchor? anchor = alphabetAnchorAt(
        expanded,
        expandedOffsets,
        counts,
        pixels,
      );
      expect(anchor, isNotNull);
      final double back = alphabetOffsetOf(expanded, expandedOffsets, anchor!);
      expect(back, closeTo(pixels, 0.001));
    }
  });

  test('列数变化后，视口顶上还是同一条', () {
    expect(narrow.crossAxisCount, lessThan(expanded.crossAxisCount));
    // 深入第二段第五行：3 列时是 4 × 3，换成 2 列后仍是行首
    final double rowExtent =
        expanded.childMainAxisExtent + expanded.mainAxisSpacing;
    final double pixels =
        expandedOffsets[1] + expanded.headerExtent + rowExtent * 4 + 40;
    final AlphabetScrollAnchor before = alphabetAnchorAt(
      expanded,
      expandedOffsets,
      counts,
      pixels,
    )!;
    expect(before.section, 1);
    expect(before.item, 12, reason: '第 5 行的第一条 = 4 × 3 列');

    // 窄到 2 列后，12 号仍然是行首（12 ~/ 2 = 6）
    final double after = alphabetOffsetOf(narrow, narrowOffsets, before);
    final AlphabetScrollAnchor restored = alphabetAnchorAt(
      narrow,
      narrowOffsets,
      counts,
      after,
    )!;
    expect(restored.section, before.section);
    expect(restored.item, before.item);
  });

  test('停在段标题上方时锚点落在该段第一条，且偏移能原样换回来', () {
    final double pixels = expandedOffsets[1] + 2;
    final AlphabetScrollAnchor anchor = alphabetAnchorAt(
      expanded,
      expandedOffsets,
      counts,
      pixels,
    )!;
    expect(anchor.section, 1);
    expect(anchor.item, 0);
    // 负的行内偏移表示「还没滚到网格」，换成 0 会把顶部几十像素吃掉
    expect(anchor.fraction, lessThan(0));
    expect(
      alphabetOffsetOf(expanded, expandedOffsets, anchor),
      closeTo(pixels, 0.001),
    );
  });
}

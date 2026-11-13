import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/alphabet_index.dart';
import 'package:lamp_player/src/features/library/widgets/alphabet_grid.dart';

/// 开关侧栏时列数不变、但卡片会变宽，行高跟着变。滚动偏移是像素，同一个像素
/// 在新布局里指向另一条 —— 所以要能把「视口顶上是谁」换算过去。
AlphabetGridMetrics metrics({
  required double viewportWidth,
  required double columnWidth,
}) {
  return AlphabetGridMetrics(
    viewportWidth: viewportWidth,
    maxCrossAxisExtent: 220,
    crossAxisSpacing: 16,
    mainAxisSpacing: 16,
    aspectRatio: 0.76,
    headerExtent: alphabetHeaderExtent,
    topPadding: 8,
    columnWidth: columnWidth,
  );
}

const List<int> counts = <int>[5, 20, 3];

void main() {
  final AlphabetGridMetrics expanded = metrics(
    viewportWidth: 1000,
    columnWidth: 800,
  );
  final AlphabetGridMetrics collapsed = metrics(
    viewportWidth: 1200,
    columnWidth: 800,
  );
  final List<double> expandedOffsets = expanded.sectionOffsets(counts);
  final List<double> collapsedOffsets = collapsed.sectionOffsets(counts);

  test('收缩侧栏只改行高，不改列数', () {
    expect(collapsed.crossAxisCount, expanded.crossAxisCount);
    expect(
      collapsed.childMainAxisExtent,
      greaterThan(expanded.childMainAxisExtent),
      reason: '内容区变宽，卡片应该变高',
    );
  });

  test('锚点换算回去能得到原来的偏移', () {
    // 都在内容范围内（三段加起来约 2700）
    for (final double pixels in <double>[0, 200, 1200, 2600]) {
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

  test('行高变化后，视口顶上还是同一条', () {
    // 深入第二段（20 条，4 列即 5 行）的第三行
    final double rowExtent =
        expanded.childMainAxisExtent + expanded.mainAxisSpacing;
    final double pixels =
        expandedOffsets[1] + expanded.headerExtent + rowExtent * 3 + 40;
    final AlphabetScrollAnchor before = alphabetAnchorAt(
      expanded,
      expandedOffsets,
      counts,
      pixels,
    )!;
    expect(before.section, 1);
    expect(before.item, 12, reason: '第 3 行的第一条 = 3 × 4 列');

    final double after = alphabetOffsetOf(collapsed, collapsedOffsets, before);
    final AlphabetScrollAnchor restored = alphabetAnchorAt(
      collapsed,
      collapsedOffsets,
      counts,
      after,
    )!;
    expect(restored.section, before.section);
    expect(restored.item, before.item);
  });

  test('窗口变窄导致列数变化时，仍保住同一条', () {
    final AlphabetGridMetrics narrow = metrics(
      viewportWidth: 760,
      columnWidth: 560,
    );
    expect(narrow.crossAxisCount, lessThan(expanded.crossAxisCount));
    final List<double> narrowOffsets = narrow.sectionOffsets(counts);

    final double rowExtent =
        expanded.childMainAxisExtent + expanded.mainAxisSpacing;
    final double pixels =
        expandedOffsets[1] + expanded.headerExtent + rowExtent * 3 + 40;
    final AlphabetScrollAnchor before = alphabetAnchorAt(
      expanded,
      expandedOffsets,
      counts,
      pixels,
    )!;

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

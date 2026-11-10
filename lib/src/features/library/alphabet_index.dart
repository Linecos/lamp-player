import 'dart:math' as math;

import '../../common/text/pinyin_key.dart';

/// 「分不出首字母」的桶：数字、符号、日文假名、空名都归到这里。
const String alphabetOtherBucket = '#';

/// 名称落在哪个字母桶。
///
/// - 拉丁字母开头取首字母大写（`maroon` → `M`）；
/// - 汉字取**拼音**首字母（`周杰伦` → `zhou` → `Z`，`林俊杰` → `L`）；
/// - 数字 / 符号 / 假名等分不出首字母的进 [alphabetOtherBucket]。
///
/// 只转第一个字，不整串转拼音：这里一个字母就决定分组，多转的部分纯浪费。
String alphabetBucketOf(String name) {
  final String text = name.trim();
  if (text.isEmpty) {
    return alphabetOtherBucket;
  }
  final int rune = text.runes.first;
  if (_isLatinLetter(rune)) {
    return String.fromCharCode(rune).toUpperCase();
  }
  if (_isCjk(rune)) {
    final String key = buildPinyinKey(String.fromCharCode(rune));
    final String full = key.split('|').first;
    if (full.isNotEmpty && _isLatinLetter(full.runes.first)) {
      return String.fromCharCode(full.runes.first).toUpperCase();
    }
  }
  return alphabetOtherBucket;
}

/// 一个字母桶（`A`…`Z` / `#`）
class AlphabetBucket<T> {
  AlphabetBucket(this.letter);

  final String letter;
  final List<T> items = <T>[];

  int get length => items.length;
}

/// 按首字母分组，组内按拼音 / 字母序排好，返回顺序是 `A`…`Z` 再接 `#`。
///
/// 组内排序用拼音全拼，所以同一桶里的中文是按读音排的（张 zhang 在周 zhou
/// 之前），而不是按码位——码位序在汉字上完全是乱的。
///
/// 名称只取一次、排序键只算一次，排序本身不再做任何字符串转换。
List<AlphabetBucket<T>> groupByAlphabet<T>(
  Iterable<T> items,
  String Function(T item) labelOf,
) {
  final List<_AlphabetEntry<T>> entries = <_AlphabetEntry<T>>[];
  int index = 0;
  for (final T item in items) {
    final String label = labelOf(item);
    entries.add(
      _AlphabetEntry<T>(
        item: item,
        letter: alphabetBucketOf(label),
        sortKey: _sortKeyOf(label),
        index: index,
      ),
    );
    index += 1;
  }
  entries.sort((_AlphabetEntry<T> a, _AlphabetEntry<T> b) {
    final int byBucket = a.rank.compareTo(b.rank);
    if (byBucket != 0) {
      return byBucket;
    }
    final int byKey = a.sortKey.compareTo(b.sortKey);
    if (byKey != 0) {
      return byKey;
    }
    // 同键时保留入参顺序，避免同一批数据两次分组排出不同结果
    return a.index.compareTo(b.index);
  });

  final List<AlphabetBucket<T>> buckets = <AlphabetBucket<T>>[];
  for (final _AlphabetEntry<T> entry in entries) {
    if (buckets.isEmpty || buckets.last.letter != entry.letter) {
      buckets.add(AlphabetBucket<T>(entry.letter));
    }
    buckets.last.items.add(entry.item);
  }
  return buckets;
}

class _AlphabetEntry<T> {
  _AlphabetEntry({
    required this.item,
    required this.letter,
    required this.sortKey,
    required this.index,
  });

  final T item;
  final String letter;
  final String sortKey;
  final int index;

  int get rank => _bucketRank(letter);
}

int _bucketRank(String letter) {
  if (letter.length == 1) {
    final int code = letter.codeUnitAt(0);
    if (code >= 0x41 && code <= 0x5A) {
      return code - 0x41;
    }
  }
  return 26;
}

String _sortKeyOf(String label) =>
    '${buildPinyinKey(label).split('|').first}\u0000${label.toLowerCase()}';

bool _isLatinLetter(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

bool _isCjk(int rune) => rune >= 0x4E00 && rune <= 0x9FFF;

/// 字母分段的网格几何：算每段从哪开始，供字母导航跳转用。
///
/// 这里复刻的是 [SliverGridDelegateWithMaxCrossAxisExtent] 的取值规则
/// （列数 `ceil(宽 / (上限 + 间距))`、列宽按剩余空间均分、行高 = 列宽 / 宽高比）。
/// 跳转要落得准，就不能靠「估」，只能和 delegate 用同一套算式；两侧任何一边改了
/// 布局参数，都要把这里一起改——测试里有「点了字母，该段标题就在顶上」的断言兜底。
class AlphabetGridMetrics {
  const AlphabetGridMetrics({
    required this.viewportWidth,
    required this.maxCrossAxisExtent,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
    required this.aspectRatio,
    required this.headerExtent,
    required this.topPadding,
    this.columnWidth,
  });

  /// 网格可用的横向宽度（已扣掉字母导航预留的那一条）
  final double viewportWidth;
  final double maxCrossAxisExtent;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double aspectRatio;

  /// 每段标题占的高度（含标题上下的空隙）
  final double headerExtent;

  /// 第一段标题之前的内边距
  final double topPadding;

  /// 算**列数**时用的宽度；为空时就用 [viewportWidth]。
  ///
  /// 侧边栏展开 / 收起是个 220ms 的宽度动画，内容区每一帧都在变宽。如果按
  /// 当前宽度算列数，动画走到一半就会多出一列——同一排卡片先被撑大、再被
  /// 挤回去，看着就是「封面先变大再变小」。传入动画结束后的宽度，列数在整段
  /// 过渡里保持不变，卡片宽度只是单调变化，落点正好等于最终布局。
  ///
  /// 只影响列数：列宽 / 行高仍然按真实的 [viewportWidth] 算，否则过渡期间
  /// 卡片会超出可用宽度。
  final double? columnWidth;

  int get crossAxisCount => math.max(
    1,
    ((columnWidth ?? viewportWidth) / (maxCrossAxisExtent + crossAxisSpacing))
        .ceil(),
  );

  double get childCrossAxisExtent =>
      (viewportWidth - crossAxisSpacing * (crossAxisCount - 1)) /
      crossAxisCount;

  double get childMainAxisExtent => childCrossAxisExtent / aspectRatio;

  /// 一段网格自身的高度（行数按列数折算，行间距只算在行与行之间）
  double gridExtent(int count) {
    if (count <= 0) {
      return 0;
    }
    final int rows = (count / crossAxisCount).ceil();
    return rows * childMainAxisExtent + (rows - 1) * mainAxisSpacing;
  }

  /// 第 [index] 段标题的滚动偏移
  double offsetOfSection(int index, List<int> counts) {
    double offset = topPadding;
    for (int i = 0; i < index && i < counts.length; i += 1) {
      offset += headerExtent + gridExtent(counts[i]);
    }
    return offset;
  }
}

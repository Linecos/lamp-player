import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/alphabet_index.dart';

void main() {
  group('首字母归档', () {
    test('英文取首字母大写', () {
      expect(alphabetBucketOf('Maroon 5'), 'M');
      expect(alphabetBucketOf('maroon'), 'M');
      expect(alphabetBucketOf('  Adele'), 'A');
    });

    test('汉字按拼音首字母', () {
      // 周 zhou → Z；林 lin → L；海 hai → H
      expect(alphabetBucketOf('周杰伦'), 'Z');
      expect(alphabetBucketOf('林俊杰'), 'L');
      expect(alphabetBucketOf('海阔天空'), 'H');
    });

    test('扩展 A / 兼容区 / 扩展 B 的汉字也按拼音归档', () {
      // 㐀 qiu、豈 qi、𠀀 he —— 只按基本区判断会全掉进 #
      expect(alphabetBucketOf('㐀'), 'Q');
      expect(alphabetBucketOf('豈'), 'Q');
      expect(alphabetBucketOf('\u{20000}'), 'H');
    });

    test('数字、符号、假名与空名都归到 #', () {
      expect(alphabetBucketOf('3 Doors Down'), alphabetOtherBucket);
      expect(alphabetBucketOf('!!!'), alphabetOtherBucket);
      expect(alphabetBucketOf('さくら'), alphabetOtherBucket);
      expect(alphabetBucketOf('   '), alphabetOtherBucket);
    });
  });

  group('按首字母分组', () {
    test('顺序是 A…Z，最后才是 #', () {
      final List<String> names = <String>['3 Doors', '周杰伦', 'Adele', '张杰'];
      final List<AlphabetBucket<String>> buckets = groupByAlphabet<String>(
        names,
        (String name) => name,
      );

      expect(
        buckets.map((AlphabetBucket<String> bucket) => bucket.letter),
        <String>['A', 'Z', '#'],
      );
      // 张 zhang 排在周 zhou 之前
      expect(buckets[1].items, <String>['张杰', '周杰伦']);
    });

    test('空列表得到空分组', () {
      expect(groupByAlphabet<String>(<String>[], (String n) => n), isEmpty);
    });

    test('同一个桶里英文与中文混排时按拼音键比较', () {
      final List<AlphabetBucket<String>> buckets = groupByAlphabet<String>(
        <String>['Zoe', '张杰', 'Zed'],
        (String name) => name,
      );

      expect(buckets.single.letter, 'Z');
      // 张杰 zhangjie 排在 Zoe(zo) 之前——比的是拼音，不是码位
      expect(buckets.single.items, <String>['Zed', '张杰', 'Zoe']);
    });
  });

  group('字母网格几何', () {
    const AlphabetGridMetrics metrics = AlphabetGridMetrics(
      viewportWidth: 1000,
      tileWidth: 220,
      tileHeight: 260,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      headerExtent: 34,
      topPadding: 8,
    );

    test('列数向上取整，列宽均分，行高是固定值', () {
      // ceil(1000 / (220 + 16)) = 5
      expect(metrics.crossAxisCount, 5);
      expect(metrics.childCrossAxisExtent, closeTo((1000 - 64) / 5, 0.001));
      expect(metrics.childMainAxisExtent, 260);
    });

    test('内容区变宽只加列数，卡片高度不变', () {
      const AlphabetGridMetrics wide = AlphabetGridMetrics(
        viewportWidth: 1300,
        tileWidth: 220,
        tileHeight: 260,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        headerExtent: 34,
        topPadding: 8,
      );
      expect(wide.crossAxisCount, 6);
      expect(
        wide.childMainAxisExtent,
        metrics.childMainAxisExtent,
        reason: '窗口化 / 全屏来回切，卡片高度必须一样',
      );
      // 宽度只在列数变化带来的均分误差里浮动：186.7 ~ 203.3
      expect(
        (wide.childCrossAxisExtent - metrics.childCrossAxisExtent).abs(),
        lessThan(220 * 0.1),
      );
    });

    test('窄到一列都放不下时按可用宽度缩', () {
      const AlphabetGridMetrics tiny = AlphabetGridMetrics(
        viewportWidth: 180,
        tileWidth: 220,
        tileHeight: 260,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        headerExtent: 34,
        topPadding: 8,
      );
      expect(tiny.crossAxisCount, 1);
      expect(tiny.childCrossAxisExtent, 180);
    });

    test('一段的高度按行数折算，行间距只算在行与行之间', () {
      final double rowHeight = metrics.childMainAxisExtent;
      expect(metrics.gridExtent(0), 0);
      // 5 列：5 条正好一行，第 6 条起新开一行
      expect(metrics.gridExtent(5), closeTo(rowHeight, 0.001));
      expect(metrics.gridExtent(6), closeTo(rowHeight * 2 + 16, 0.001));
      expect(metrics.gridExtent(11), closeTo(rowHeight * 3 + 16 * 2, 0.001));
    });

    test('每段偏移 = 顶部留白 + 之前所有段的高度', () {
      final List<int> counts = <int>[5, 10, 2];
      final List<double> offsets = metrics.sectionOffsets(counts);
      expect(offsets, hasLength(3));
      expect(offsets[0], 8);
      expect(offsets[1], closeTo(8 + 34 + metrics.gridExtent(5), 0.001));
      expect(
        offsets[2],
        closeTo(
          8 + 34 * 2 + metrics.gridExtent(5) + metrics.gridExtent(10),
          0.001,
        ),
      );
    });
  });
}

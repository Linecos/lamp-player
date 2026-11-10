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
      maxCrossAxisExtent: 220,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      aspectRatio: 0.72,
      headerExtent: 34,
      topPadding: 8,
    );

    test('列数与 delegate 的算法一致', () {
      // ceil(1000 / (220 + 16)) = 5
      expect(metrics.crossAxisCount, 5);
      expect(metrics.childCrossAxisExtent, closeTo((1000 - 16 * 4) / 5, 0.001));
      expect(
        metrics.childMainAxisExtent,
        closeTo(metrics.childCrossAxisExtent / 0.72, 0.001),
      );
    });

    test('一段的高度按行数折算，行间距只算在行与行之间', () {
      final double rowHeight = metrics.childMainAxisExtent;
      expect(metrics.gridExtent(0), 0);
      expect(metrics.gridExtent(5), closeTo(rowHeight, 0.001));
      expect(metrics.gridExtent(6), closeTo(rowHeight * 2 + 16, 0.001));
    });

    test('每段偏移 = 顶部留白 + 之前所有段的高度', () {
      final List<int> counts = <int>[5, 10, 2];
      expect(metrics.offsetOfSection(0, counts), 8);
      expect(
        metrics.offsetOfSection(1, counts),
        closeTo(8 + 34 + metrics.gridExtent(5), 0.001),
      );
      expect(
        metrics.offsetOfSection(2, counts),
        closeTo(
          8 + 34 * 2 + metrics.gridExtent(5) + metrics.gridExtent(10),
          0.001,
        ),
      );
    });
  });
}

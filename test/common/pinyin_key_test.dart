import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/pinyin_key.dart';

void main() {
  test('hasCjk 只对汉字返回 true', () {
    expect(hasCjk('夜航'), isTrue);
    expect(hasCjk('yehang'), isFalse);
    expect(hasCjk('夜航 yh'), isTrue);
    expect(hasCjk(''), isFalse);
  });

  test('拼音键同时包含全拼与首字母', () {
    final String key = buildPinyinKey('夜航');
    expect(key, contains('yehang'));
    expect(key.split('|').last, 'yh');
  });

  test('英文与数字原样保留并转小写', () {
    final String key = buildPinyinKey('Daft Punk 2001');
    expect(key, startsWith('daft punk 2001|daft punk 2001'));
  });

  test('中英混排按片段转换', () {
    final String key = buildPinyinKey('夜航 Live');
    expect(key, contains('yehang'));
    expect(key, contains('live'));
  });

  test('normalizePinyinQuery 去空白并转小写', () {
    expect(normalizePinyinQuery('  Y H '), 'yh');
  });

  group('pinyinSortKey', () {
    test('汉字转全拼、不带分隔与声调', () {
      expect(pinyinSortKey('夜航'), 'yehang');
      expect(pinyinSortKey('玻璃海'), 'bolihai');
    });

    test('英文转小写，中英混排落在同一把尺子上', () {
      expect(pinyinSortKey('Blue Archive'), 'blue archive');
      expect(pinyinSortKey('夜航 Live'), 'yehang live');
    });

    test('同形不同音的排序结果是稳定的（同一输入两次调用一致）', () {
      expect(pinyinSortKey('长夜'), pinyinSortKey('长夜'));
    });

    test('转换不出来的字符原样保留，不抛异常', () {
      expect(pinyinSortKey('夜航🙂'), contains('yehang'));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/pinyin_key.dart';

void main() {
  test('hasCjk 只对汉字返回 true', () {
    expect(hasCjk('夜航'), isTrue);
    expect(hasCjk('yehang'), isFalse);
    expect(hasCjk('夜航 yh'), isTrue);
    expect(hasCjk(''), isFalse);
  });

  group('汉字码位范围', () {
    test('基本区、扩展 A、兼容区与扩展 B 都算汉字', () {
      expect(isCjkRune(0x4E00), isTrue, reason: '基本区首字「一」');
      expect(isCjkRune(0x3400), isTrue, reason: '扩展 A 首字「㐀」');
      expect(isCjkRune(0xF900), isTrue, reason: '兼容区首字「豈」');
      expect(isCjkRune(0x20000), isTrue, reason: '扩展 B 首字「𠀀」');
    });

    test('紧贴范围外的码位不算汉字', () {
      expect(isCjkRune(0x33FF), isFalse, reason: '扩展 A 之前是 CJK 符号');
      expect(isCjkRune(0x4DC0), isFalse, reason: '扩展 A 之后是易经卦象');
      expect(isCjkRune(0xA000), isFalse, reason: '基本区之后是彝文');
      expect(isCjkRune(0xFB00), isFalse, reason: '兼容区之后是拉丁连字');
    });

    test('只看基本区会漏掉的字，现在能被认出来', () {
      expect(hasCjk('㐀'), isTrue);
      expect(hasCjk('豈'), isTrue);
      expect(hasCjk('\u{20000}'), isTrue);
      // 不误伤：CJK 符号、彝文、假名都不算汉字
      expect(hasCjk('、。'), isFalse);
      expect(hasCjk('ꀀ'), isFalse);
      expect(hasCjk('さくら'), isFalse);
    });

    test('扩展区汉字也进拼音键，且能拼出声母', () {
      // 㐀 qiū / 豈 qǐ / 𠀀 hé —— 只认基本区时这些都会退化成原字
      expect(buildPinyinKey('㐀'), startsWith('qiu|'));
      expect(buildPinyinKey('豈'), startsWith('qi|'));
      expect(pinyinSortKey('\u{20000}'), 'he');
      expect(pinyinSortKey('㐀'), 'qiu');
    });
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

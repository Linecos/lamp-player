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
}

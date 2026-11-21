import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/bundled_fonts.dart';
import 'package:lamp_player/src/common/text/lyric_font.dart';

void main() {
  tearDown(registeredBundledFamilies.clear);

  test('MiSans 的每个字重各占一个候选，按注册结果过滤', () {
    registeredBundledFamilies.clear();
    final int without = lyricFontChoices().length;
    expect(
      lyricFontChoices().map(((String, String) item) => item.$1),
      isNot(contains('MiSans Light')),
      reason: '没跑过 setup-misans.ps1 的机器上不该出现选不了的项',
    );

    registeredBundledFamilies.addAll(
      kMiSansFaces.map((BundledFontFace face) => face.family),
    );
    final List<(String, String)> all = lyricFontChoices();
    expect(all.length, without + kMiSansFaces.length);
    // 紧跟「跟随界面字体」，在系统字体之前
    expect(all[1].$1, 'MiSans Light');
    expect(all[1].$2, 'MiSans 细体');
    expect(
      all.map(((String, String) item) => item.$1).toSet().length,
      all.length,
      reason: '别名不能重复，否则同一款字体会出现两次',
    );
  });

  test('只注册了部分字重时，只列这几款', () {
    registeredBundledFamilies
      ..clear()
      ..add('MiSans Regular');
    final List<String> values = lyricFontChoices()
        .map(((String, String) item) => item.$1)
        .toList();
    expect(values, contains('MiSans Regular'));
    expect(values, isNot(contains('MiSans Light')));
    expect(values, isNot(contains('MiSans Bold')));
  });

  test('默认是跟随界面字体，空串不当成字体名', () {
    expect(kLyricFontChoices.first.$1, isEmpty);
    expect(lyricFontFamilyOrNull(''), isNull);
    expect(lyricFontFamilyOrNull('   '), isNull);
    expect(lyricFontFamilyOrNull(' MiSans Light '), 'MiSans Light');
  });

  test('中文名与字体族名一一对应', () {
    expect(lyricFontLabel('SimSun'), '宋体');
    expect(lyricFontLabel(''), '跟随界面字体');
    // 随包字重即使还没注册，标签也能翻译（存档里是英文别名）
    expect(lyricFontLabel('MiSans Bold'), 'MiSans 粗体');
    // 表里没有的原样返回，别把用户配过的字体显示成空白
    expect(lyricFontLabel('Some Unknown Font'), 'Some Unknown Font');
  });

  test('MiSans 别名判定覆盖各字重', () {
    expect(isBundledMiSansFamily('MiSans'), isTrue);
    expect(isBundledMiSansFamily('MiSans Light'), isTrue);
    expect(isBundledMiSansFamily(' misans bold '), isTrue);
    expect(isBundledMiSansFamily('SimSun'), isFalse);
    expect(isBundledMiSansFamily('MiSansx'), isFalse);
  });
}

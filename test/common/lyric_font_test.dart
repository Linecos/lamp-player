import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/bundled_fonts.dart';
import 'package:lamp_player/src/common/text/lyric_font.dart';

void main() {
  tearDown(() => misansAvailable = false);

  test('MiSans 只在字体包加载成功后出现在候选里', () {
    misansAvailable = false;
    final int withoutMiSans = lyricFontChoices().length;
    expect(
      lyricFontChoices().map(((String, String) item) => item.$1),
      isNot(contains(miSansFamily)),
      reason: '没跑过 setup-misans.ps1 的机器上不该出现选不了的项',
    );

    misansAvailable = true;
    expect(
      lyricFontChoices().map(((String, String) item) => item.$1),
      contains(miSansFamily),
    );
    // 其余候选与过滤无关，数量只是多了 MiSans 这一项
    expect(lyricFontChoices().length, withoutMiSans + 1);
  });

  test('默认是跟随界面字体，空串不当成字体名', () {
    expect(kLyricFontChoices.first.$1, isEmpty);
    expect(lyricFontFamilyOrNull(''), isNull);
    expect(lyricFontFamilyOrNull('   '), isNull);
    expect(lyricFontFamilyOrNull(' MiSans '), miSansFamily);
  });

  test('中文名与字体族名一一对应', () {
    expect(lyricFontLabel('SimSun'), '宋体');
    expect(lyricFontLabel(''), '跟随界面字体');
    // 表里没有的原样返回，别把用户配过的字体显示成空白
    expect(lyricFontLabel('Some Unknown Font'), 'Some Unknown Font');
  });
}

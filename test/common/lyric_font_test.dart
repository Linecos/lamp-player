import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/bundled_fonts.dart';
import 'package:lamp_player/src/common/text/lyric_font.dart';

void main() {
  tearDown(registeredBundledFamilies.clear);

  test('内置中文字体表只做别名：不重复、MiSans 不混进来', () {
    registeredBundledFamilies.clear();
    expect(
      kLyricFontChoices.map(((String, String) item) => item.$1),
      isNot(contains('MiSans')),
      reason: '随包字体只在注册成功时才出现在弹窗里，别写进别名表',
    );
    expect(
      kLyricFontChoices.map(((String, String) item) => item.$1).toSet().length,
      kLyricFontChoices.length,
      reason: '别名不能重复，否则同一款字体会出现两次',
    );
  });

  test('旧字重别名归一成当前那一款', () {
    registeredBundledFamilies.clear();
    // 字体没下载：原样留着，交给下拉按「未知值」处理
    expect(normalizeLyricFontFamily('MiSans Bold'), 'MiSans Bold');

    registeredBundledFamilies.add('MiSans');
    for (final String old in <String>[
      'MiSans Light',
      'MiSans Regular',
      'MiSans Medium',
      'MiSans Bold',
      ' misans ',
    ]) {
      expect(normalizeLyricFontFamily(old), 'MiSans', reason: old);
    }
    expect(normalizeLyricFontFamily('SimSun'), 'SimSun');
    expect(normalizeLyricFontFamily(''), '');
    expect(lyricFontFamilyOrNull('MiSans Bold'), 'MiSans');
  });

  test('默认是跟随界面字体，空串不当成字体名', () {
    expect(kLyricFontChoices.first.$1, isEmpty);
    expect(lyricFontFamilyOrNull(''), isNull);
    expect(lyricFontFamilyOrNull('   '), isNull);
    expect(lyricFontFamilyOrNull(' SimSun '), 'SimSun');
  });

  test('中文名与字体族名一一对应', () {
    expect(lyricFontLabel('SimSun'), '宋体');
    expect(lyricFontLabel(''), '跟随界面字体');
    // 已下线的字重别名按同一款显示，界面上不冒出英文家族名
    expect(lyricFontLabel('MiSans Bold'), 'MiSans');
    // 表里没有的原样返回，别把用户配过的字体显示成空白
    expect(lyricFontLabel('Some Unknown Font'), 'Some Unknown Font');
  });

  test('MiSans 别名判定覆盖旧字重名', () {
    expect(isBundledMiSansFamily('MiSans'), isTrue);
    expect(isBundledMiSansFamily('MiSans Light'), isTrue);
    expect(isBundledMiSansFamily(' misans bold '), isTrue);
    expect(isBundledMiSansFamily('SimSun'), isFalse);
    expect(isBundledMiSansFamily('MiSansx'), isFalse);
  });
}

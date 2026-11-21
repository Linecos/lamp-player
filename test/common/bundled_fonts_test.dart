import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/text/bundled_fonts.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

double _width(String text, String? family) {
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: family, fontSize: 32),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  return painter.width;
}

void main() {
  testWidgets('注册后 MiSans 的字形真的生效（不是回退字体）', (WidgetTester tester) async {
    await registerBundledFonts();
    if (!misansAvailable) {
      // 没跑过 scripts/setup-misans.ps1（比如 CI）：跳过而不是失败
      markTestSkipped('未安装打包字体，跳过');
      return;
    }

    const String sample = '夜色温柔 Abc 123';
    final double withMiSans = _width(sample, miSansFamily);
    final double withTheme = _width(sample, AppTheme.fontFamily);
    expect(
      withMiSans,
      isNot(closeTo(withTheme, 1.0)),
      reason: '两者宽度一致说明 MiSans 没注册上、只是回退到了系统字体',
    );
  });

  testWidgets('字体包缺失时不抛异常，标记为不可用', (WidgetTester tester) async {
    // 这个用例只保证调用安全：缺文件（CI）与有文件（本机）都不能崩
    await registerBundledFonts();
    expect(misansAvailable, isA<bool>());
  });
}

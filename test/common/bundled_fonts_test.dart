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
  tearDown(registeredBundledFamilies.clear);

  testWidgets('注册后 MiSans 真正生效（不是回退到系统字体）', (WidgetTester tester) async {
    await registerBundledFonts();
    if (!misansAvailable) {
      // 没跑过 scripts/setup-misans.ps1（比如 CI）：跳过而不是失败
      markTestSkipped('未安装打包字体，跳过');
      return;
    }

    const String sample = '夜色温柔 Abc 123';
    final String family = kMiSansFaces.first.family;

    expect(registeredBundledFamilies.length, kMiSansFaces.length);
    expect(
      _width(sample, family),
      isNot(closeTo(_width(sample, AppTheme.fontFamily), 1.0)),
      reason: '宽度与主题字体一致说明没注册上、只是回退',
    );
    // 有实际字宽（不是空家族导致 0 宽）
    for (final BundledFontFace face in kMiSansFaces) {
      expect(_width(sample, face.family), greaterThan(0));
    }
  });

  testWidgets('字体包缺失时不抛异常，标记为不可用', (WidgetTester tester) async {
    // 这个用例只保证调用安全：缺文件（CI）与有文件（本机）都不能崩
    await registerBundledFonts();
    expect(misansAvailable, isA<bool>());
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

void main() {
  test('深浅色主题默认雅黑 Light，并带中文字体回退', () {
    for (final ThemeData theme in <ThemeData>[AppTheme.light, AppTheme.dark]) {
      final TextStyle? body = theme.textTheme.bodyMedium;
      expect(body?.fontFamily, 'Microsoft YaHei Light');
      expect(
        body?.fontFamilyFallback,
        contains('Microsoft YaHei UI'),
        reason: '汉字必须有确定的中文字面，避免系统回退到宋体',
      );
      // 标题类同样要带上，否则大字号仍会落到系统回退字体
      expect(
        theme.textTheme.headlineMedium?.fontFamilyFallback,
        contains('Microsoft YaHei UI'),
      );
    }
  });
}

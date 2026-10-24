import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

void main() {
  test('深浅色主题默认雅黑 Light，并带中文字体回退', () {
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(AppTheme.defaultSeed),
      AppTheme.dark(AppTheme.defaultSeed),
    ]) {
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

  test('调色板风格清单完整且互不重复', () {
    expect(
      AppTheme.variantOptions,
      hasLength(DynamicSchemeVariant.values.length),
    );
    final Set<DynamicSchemeVariant> seen = <DynamicSchemeVariant>{};
    for (final (DynamicSchemeVariant variant, String label)
        in AppTheme.variantOptions) {
      expect(seen.add(variant), isTrue, reason: '$variant 重复出现');
      expect(label, isNotEmpty);
    }
  });

  test('Monochrome 风格生成无色度配色', () {
    final ColorScheme scheme = AppTheme.schemeOf(
      const Color(0xFF2196F3),
      Brightness.light,
      DynamicSchemeVariant.monochrome,
    );

    final int argb = scheme.primary.toARGB32();
    final int r = (argb >> 16) & 0xFF;
    final int g = (argb >> 8) & 0xFF;
    final int b = argb & 0xFF;
    expect(r, g, reason: '单色风格下 R=G');
    expect(g, b, reason: '单色风格下 G=B');
  });

  test('高对比档位改变生成的配色', () {
    final ColorScheme normal = AppTheme.schemeOf(
      AppTheme.defaultSeed,
      Brightness.light,
      AppTheme.defaultVariant,
    );
    final ColorScheme high = AppTheme.schemeOf(
      AppTheme.defaultSeed,
      Brightness.light,
      AppTheme.defaultVariant,
      contrastLevel: 1.0,
    );

    expect(normal.primary, isNot(high.primary));
  });
}

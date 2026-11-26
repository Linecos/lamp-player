import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/theme/app_theme.dart';
import 'package:lamp_player/src/theme/tokens.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

Hct _hct(Color color) => Hct.fromInt(color.toARGB32());

/// 色相差（0~180），跨 0 / 360 绕回来
double _hueDistance(double a, double b) {
  final double raw = (a - b).abs() % 360;
  return raw > 180 ? 360 - raw : raw;
}

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

  test('传入界面字体时整棵主题换族，回退链不变', () {
    final ThemeData custom = AppTheme.light(
      AppTheme.defaultSeed,
      fontFamily: 'SimSun',
    );
    expect(custom.textTheme.bodyMedium?.fontFamily, 'SimSun');
    expect(custom.textTheme.titleLarge?.fontFamily, 'SimSun');
    expect(
      custom.textTheme.bodyMedium?.fontFamilyFallback,
      contains('Microsoft YaHei UI'),
      reason: '换族只换首选，中文回退链还得在',
    );

    // 空串 = 用默认，别把 fontFamily 设成空家族导致整界面掉到系统默认
    final ThemeData fallback = AppTheme.light(
      AppTheme.defaultSeed,
      fontFamily: '',
    );
    expect(fallback.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei Light');
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

  test('浅色底跟着 seed 上色，不再是纯白', () {
    final ColorScheme scheme = AppTheme.schemeOf(
      AppTheme.defaultSeed,
      Brightness.light,
      AppTheme.defaultVariant,
    );
    final List<Color> layers = <Color>[
      scheme.surfaceContainerLowest,
      scheme.surfaceContainerLow,
      scheme.surfaceContainer,
      scheme.surfaceContainerHigh,
      scheme.surfaceContainerHighest,
    ];

    expect(
      scheme.surfaceContainerLowest.toARGB32(),
      isNot(0xFFFFFFFF),
      reason: '岛式布局的底色就是 lowest，纯白等于回到「白纸」',
    );
    expect(
      _hct(layers.first).chroma,
      greaterThan(3),
      reason: '底色要留得住 seed 的色调',
    );
    for (int i = 1; i < layers.length; i++) {
      expect(
        _hct(layers[i]).tone,
        lessThan(_hct(layers[i - 1]).tone),
        reason: '卡片层级要一层比一层深，否则卡片与缝分不开',
      );
    }
  });

  test('弹层收进主题：菜单小圆角 + 高一级的底', () {
    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(AppTheme.defaultSeed),
      AppTheme.dark(AppTheme.defaultSeed),
    ]) {
      final ShapeBorder? shape = theme.popupMenuTheme.shape;
      expect(shape, isA<RoundedRectangleBorder>(), reason: '别再用默认的 4px 方角');
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(Radii.sm),
      );
      expect(
        theme.popupMenuTheme.color,
        theme.colorScheme.surfaceContainerHigh,
      );
    }
  });

  test('浅色派生的深色主题只换亮度，不转色相', () {
    // 播放详情页在浅色模式下套深色前景，走 darkOf。以前是 dark(primary)：
    // 主色被当 seed 又算一遍，Expressive 的主色相是 seed + 240°，绿封面
    // 就会变成粉色按钮配绿色背景。
    for (final (Color seed, DynamicSchemeVariant variant)
        in <(Color, DynamicSchemeVariant)>[
          (const Color(0xFF4CAF50), DynamicSchemeVariant.fidelity),
          (AppTheme.defaultSeed, AppTheme.defaultVariant),
        ]) {
      final ThemeData light = AppTheme.light(seed, variant: variant);
      final ColorScheme dark = AppTheme.darkOf(light.colorScheme).colorScheme;
      final double delta = _hueDistance(
        _hct(light.colorScheme.primary).hue,
        _hct(dark.primary).hue,
      );
      expect(delta, lessThan(12), reason: '派生深色不能把主色相转走');
      expect(dark.brightness, Brightness.dark);
      expect(_hct(dark.primary).tone, greaterThan(70), reason: '深色主色要亮');
    }
  });

  test('中性 seed 的浅色底保持中性，不凭空染色', () {
    final ColorScheme scheme = AppTheme.schemeOf(
      const Color(0xFF808080),
      Brightness.light,
      AppTheme.defaultVariant,
    );
    expect(_hct(scheme.surfaceContainerLow).chroma, lessThan(2));
  });

  test('高对比档位不覆盖浅色底', () {
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

    expect(
      _hct(high.surfaceContainerLow).tone,
      greaterThan(_hct(normal.surfaceContainerLow).tone),
      reason: '高对比要让底更亮、前景更黑，不能被着色压暗',
    );
  });
}

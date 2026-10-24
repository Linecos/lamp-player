import 'package:flutter/material.dart';

/// 全局主题：Material 3 + 可配置 seed 色与调色板风格，深浅色模式跟随系统。
///
/// seed 与调色板风格来自「外观 → 配色」：预设色板或系统强调色（动态取色）。
/// 不要在页面里写死颜色，一律用 `Theme.of(context).colorScheme.*`。
abstract final class AppTheme {
  /// 默认主色种子：台灯灯光的暖黄；也是「未选自定义色且读不到
  /// 系统强调色」时的兜底。
  static const Color defaultSeed = Color(0xFFFFB300);

  /// 默认调色板风格：Material 3 的 Tonal spot（与历史版本行为一致）。
  static const DynamicSchemeVariant defaultVariant =
      DynamicSchemeVariant.tonalSpot;

  /// 预设强调色板：设置页可一键选用，都是 MD3 seed 友好的饱和色。
  static const List<Color> presetSeeds = <Color>[
    Color(0xFFFFB300), // 台灯暖黄（默认）
    Color(0xFFE91E63), // 玫红
    Color(0xFFF44336), // 朱红
    Color(0xFFFF9800), // 橙
    Color(0xFF4CAF50), // 绿
    Color(0xFF009688), // 青绿
    Color(0xFF00BCD4), // 青
    Color(0xFF2196F3), // 蓝
    Color(0xFF3F51B5), // 靛蓝
    Color(0xFF9C27B0), // 紫
  ];

  /// 调色板风格中文名，顺序与 [DynamicSchemeVariant.values] 对应之外单独列出，
  /// 便于设置页展示与测试断言。
  static const List<(DynamicSchemeVariant, String)> variantOptions =
      <(DynamicSchemeVariant, String)>[
        (DynamicSchemeVariant.tonalSpot, 'Tonal spot'),
        (DynamicSchemeVariant.fidelity, 'Fidelity'),
        (DynamicSchemeVariant.content, 'Content'),
        (DynamicSchemeVariant.vibrant, 'Vibrant'),
        (DynamicSchemeVariant.expressive, 'Expressive'),
        (DynamicSchemeVariant.rainbow, 'Rainbow'),
        (DynamicSchemeVariant.fruitSalad, 'Fruit salad'),
        (DynamicSchemeVariant.neutral, 'Neutral'),
        (DynamicSchemeVariant.monochrome, 'Monochrome'),
      ];

  /// 由 seed + 风格 + 对比度生成 ColorScheme；色卡预览与主题共用这一个入口，
  /// 保证「所见即所得」。
  static ColorScheme schemeOf(
    Color seed,
    Brightness brightness,
    DynamicSchemeVariant variant, {
    double contrastLevel = 0,
  }) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: variant,
      contrastLevel: contrastLevel,
    );
  }

  /// 默认字体：微软雅黑 Light。
  ///
  /// 比系统默认的 Segoe UI 更适合中文界面：汉字不再走随机回退（宋体/等线），
  /// 笔画也更轻、正文密度更均匀。拉丁字母同样由它自带的字形渲染。
  static const String fontFamily = 'Microsoft YaHei Light';

  /// 回退链：某些机器没装 Light 字型，或用到了它没有的符号时兜底。
  static const List<String> fontFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'PingFang SC',
    'sans-serif',
  ];

  static ThemeData light(
    Color seed, {
    DynamicSchemeVariant variant = defaultVariant,
    double contrastLevel = 0,
  }) => _build(Brightness.light, seed, variant, contrastLevel);

  static ThemeData dark(
    Color seed, {
    DynamicSchemeVariant variant = defaultVariant,
    double contrastLevel = 0,
  }) => _build(Brightness.dark, seed, variant, contrastLevel);

  static ThemeData _build(
    Brightness brightness,
    Color seed,
    DynamicSchemeVariant variant,
    double contrastLevel,
  ) {
    final ColorScheme scheme = schemeOf(
      seed,
      brightness,
      variant,
      contrastLevel: contrastLevel,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      appBarTheme: const AppBarTheme(centerTitle: false),
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}

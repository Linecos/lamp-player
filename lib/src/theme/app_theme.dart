import 'package:flutter/material.dart';

/// 全局主题：Material 3 + 单一 seed 色，深浅色模式跟随系统。
///
/// 只改 [seed] 就能整体换色；不要在页面里写死颜色，一律用
/// `Theme.of(context).colorScheme.*`。
abstract final class AppTheme {
  /// 主色种子：台灯灯光的暖黄
  static const Color seed = Color(0xFFFFB300);

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

  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
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

import 'package:flutter/material.dart';

/// 全局主题：Material 3 + 单一 seed 色，深浅色模式跟随系统。
///
/// 只改 [seed] 就能整体换色；不要在页面里写死颜色，一律用
/// `Theme.of(context).colorScheme.*`。
abstract final class AppTheme {
  /// 主色种子：台灯灯光的暖黄
  static const Color seed = Color(0xFFFFB300);

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
      appBarTheme: const AppBarTheme(centerTitle: false),
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}

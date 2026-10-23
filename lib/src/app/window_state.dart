import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

/// 窗口几何：只记“普通状态”的尺寸，最大化时不要把整屏尺寸写回去。
class WindowSnapshot {
  const WindowSnapshot({
    this.size = const Size(1180, 760),
    this.maximized = false,
  });

  final Size size;
  final bool maximized;
}

abstract interface class WindowStateStore {
  Future<WindowSnapshot> load();

  Future<void> save(WindowSnapshot snapshot);
}

/// 基于 `shared_preferences` 的实现。
///
/// 尺寸做下限保护：显示器变小或存了异常值时，至少还能看到完整标题栏。
class PrefsWindowStateStore implements WindowStateStore {
  const PrefsWindowStateStore();

  static const String widthKey = 'window_width';
  static const String heightKey = 'window_height';
  static const String maximizedKey = 'window_maximized';

  static const double minWidth = 900;
  static const double minHeight = 560;

  @override
  Future<WindowSnapshot> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final double width = (prefs.getDouble(widthKey) ?? 1180).clamp(
        minWidth,
        10000,
      );
      final double height = (prefs.getDouble(heightKey) ?? 760).clamp(
        minHeight,
        10000,
      );
      return WindowSnapshot(
        size: Size(width, height),
        maximized: prefs.getBool(maximizedKey) ?? false,
      );
    } catch (_) {
      return const WindowSnapshot();
    }
  }

  @override
  Future<void> save(WindowSnapshot snapshot) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(widthKey, snapshot.size.width);
      await prefs.setDouble(heightKey, snapshot.size.height);
      await prefs.setBool(maximizedKey, snapshot.maximized);
    } catch (_) {
      // 保存失败只影响下次启动的窗口大小
    }
  }
}

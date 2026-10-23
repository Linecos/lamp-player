import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

/// 窗口几何：只记“普通状态”的尺寸与位置，最大化时不要把整屏几何写回去。
class WindowSnapshot {
  const WindowSnapshot({
    this.size = const Size(1180, 760),
    this.position,
    this.maximized = false,
  });

  final Size size;

  /// 上次普通状态下的窗口左上角；`null` 表示没有记录（启动时居中）。
  final Offset? position;

  final bool maximized;
}

/// 保存的位置是否还能在任意显示器上看到。
///
/// 显示器拔掉 / 分辨率变化后，旧坐标可能完全落在屏幕外；此时应放弃记忆、
/// 回退居中。只要求标题栏附近有一小块可见，用户就能把窗口拖回来。
bool isWindowVisibleOn({
  required Offset position,
  required Size size,
  required Iterable<Rect> displays,
}) {
  const double minVisibleWidth = 160;
  const double minVisibleHeight = 80;
  final Rect window = position & size;
  for (final Rect display in displays) {
    final Rect overlap = window.intersect(display);
    if (overlap.width >= minVisibleWidth &&
        overlap.height >= minVisibleHeight) {
      return true;
    }
  }
  return false;
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
  static const String xKey = 'window_x';
  static const String yKey = 'window_y';
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
      final double? x = prefs.getDouble(xKey);
      final double? y = prefs.getDouble(yKey);
      return WindowSnapshot(
        size: Size(width, height),
        position: x == null || y == null ? null : Offset(x, y),
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
      final Offset? position = snapshot.position;
      if (position == null) {
        await prefs.remove(xKey);
        await prefs.remove(yKey);
      } else {
        await prefs.setDouble(xKey, position.dx);
        await prefs.setDouble(yKey, position.dy);
      }
      await prefs.setBool(maximizedKey, snapshot.maximized);
    } catch (_) {
      // 保存失败只影响下次启动的窗口大小
    }
  }
}

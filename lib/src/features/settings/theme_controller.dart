import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式状态：改动立即生效，并异步写入本地存储。
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initialMode = ThemeMode.system})
    : _mode = initialMode;

  /// 存储键；单独暴露便于测试直接断言写入内容。
  static const String prefsKey = 'theme_mode';

  ThemeMode _mode;

  ThemeMode get mode => _mode;

  /// 从本地存储恢复；读取失败（插件不可用、值非法）时保持当前值。
  Future<void> restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ThemeMode? saved = _decode(prefs.getString(prefsKey));
      if (saved != null && saved != _mode) {
        _mode = saved;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('读取主题设置失败：$error');
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, mode.name);
    } catch (error) {
      debugPrint('保存主题设置失败：$error');
    }
  }

  static ThemeMode? _decode(String? raw) {
    for (final ThemeMode mode in ThemeMode.values) {
      if (mode.name == raw) {
        return mode;
      }
    }
    return null;
  }
}

/// 向下提供 [ThemeController]。
///
/// 用 `maybeOf` 的地方是为了兼容尚未包裹 scope 的调用方（如既有测试），
/// 拿不到时降级为只读展示。
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final ThemeController? controller = maybeOf(context);
    assert(controller != null, '上层缺少 ThemeScope');
    return controller!;
  }

  static ThemeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()?.notifier;
}

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/app_theme.dart';

/// 主题状态：深浅模式 + 强调色种子。改动立即生效，并异步写入本地存储。
///
/// 强调色支持两种来源：
/// - 预设色板：固定颜色，存 0xAARRGGBB；
/// - 跟随系统（动态取色）：`seedColor` 为 `null`，实际颜色取
///   [updateSystemAccent] 注入的系统强调色，读不到再回落 [AppTheme.defaultSeed]。
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initialMode = ThemeMode.system})
    : _mode = initialMode;

  /// 存储键；单独暴露便于测试直接断言写入内容。
  static const String prefsKey = 'theme_mode';

  /// 强调色存储键：`system` 表示跟随系统，其余为 0xAARRGGBB 的十进制字符串。
  static const String seedPrefsKey = 'theme_seed';

  /// 调色板风格存储键：存 `DynamicSchemeVariant.name`。
  static const String variantPrefsKey = 'theme_variant';

  /// 高对比存储键：'1' / '0'。
  static const String contrastPrefsKey = 'theme_contrast';

  static const String _systemSeedValue = 'system';

  ThemeMode _mode;
  Color? _seedColor;
  DynamicSchemeVariant _variant = AppTheme.defaultVariant;
  bool _highContrast = false;

  /// 系统强调色缓存；由外部（启动时 / 切到跟随系统时）注入
  Color? _systemAccent;

  /// 防止异步恢复晚于用户操作或销毁：恢复不再覆盖新选择，也不在销毁后通知。
  bool _disposed = false;
  bool _userChanged = false;

  ThemeMode get mode => _mode;

  /// 用户选定的强调色；`null` 表示跟随系统。
  Color? get seedColor => _seedColor;

  /// 调色板风格（Tonal spot / Vibrant / Monochrome…）。
  DynamicSchemeVariant get schemeVariant => _variant;

  /// 是否用高对比色阶（contrastLevel = 1.0）。
  bool get highContrast => _highContrast;

  /// 最近一次读到的系统强调色；`null` 表示未知（非 Windows / 读取失败）。
  Color? get systemAccent => _systemAccent;

  /// 实际生效的种子色：用户选择 > 系统强调色 > 默认暖黄。
  Color get effectiveSeed =>
      _seedColor ?? _systemAccent ?? AppTheme.defaultSeed;

  /// 从本地存储恢复；读取失败（插件不可用、值非法）时保持当前值。
  Future<void> restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_disposed || _userChanged) {
        return;
      }
      bool changed = false;
      final ThemeMode? savedMode = _decodeMode(prefs.getString(prefsKey));
      if (savedMode != null && savedMode != _mode) {
        _mode = savedMode;
        changed = true;
      }
      final Color? savedSeed = _decodeSeed(prefs.getString(seedPrefsKey));
      if (savedSeed != _seedColor) {
        _seedColor = savedSeed;
        changed = true;
      }
      final DynamicSchemeVariant? savedVariant = _decodeVariant(
        prefs.getString(variantPrefsKey),
      );
      if (savedVariant != null && savedVariant != _variant) {
        _variant = savedVariant;
        changed = true;
      }
      final bool? savedContrast = _decodeContrast(
        prefs.getString(contrastPrefsKey),
      );
      if (savedContrast != null && savedContrast != _highContrast) {
        _highContrast = savedContrast;
        changed = true;
      }
      if (changed) {
        notifyListeners();
      }
    } catch (error) {
      debugPrint('读取主题设置失败：$error');
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_disposed || mode == _mode) {
      return;
    }
    _userChanged = true;
    _mode = mode;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, mode.name);
    } catch (error) {
      debugPrint('保存主题设置失败：$error');
    }
  }

  /// 设置强调色；传 `null` 表示跟随系统（动态取色）。
  Future<void> setSeedColor(Color? color) async {
    if (_disposed || color == _seedColor) {
      return;
    }
    _userChanged = true;
    _seedColor = color;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        seedPrefsKey,
        color == null ? _systemSeedValue : color.toARGB32().toString(),
      );
    } catch (error) {
      debugPrint('保存强调色设置失败：$error');
    }
  }

  /// 注入系统强调色（动态取色的数据源）；值变化时通知界面刷新。
  ///
  /// 调用时机：启动恢复设置后，以及从「其他地方」切回跟随系统时。
  void updateSystemAccent(Color? color) {
    if (_disposed || color == _systemAccent) {
      return;
    }
    _systemAccent = color;
    // 只在「跟随系统」生效时界面才会变，但通知总是无害且让依赖方拿到最新值
    notifyListeners();
  }

  /// 设置调色板风格。
  Future<void> setSchemeVariant(DynamicSchemeVariant variant) async {
    if (_disposed || variant == _variant) {
      return;
    }
    _userChanged = true;
    _variant = variant;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(variantPrefsKey, variant.name);
    } catch (error) {
      debugPrint('保存调色板风格失败：$error');
    }
  }

  /// 切换高对比色阶。
  Future<void> setHighContrast(bool value) async {
    if (_disposed || value == _highContrast) {
      return;
    }
    _userChanged = true;
    _highContrast = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(contrastPrefsKey, value ? '1' : '0');
    } catch (error) {
      debugPrint('保存高对比设置失败：$error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static ThemeMode? _decodeMode(String? raw) {
    for (final ThemeMode mode in ThemeMode.values) {
      if (mode.name == raw) {
        return mode;
      }
    }
    return null;
  }

  /// 非法风格名返回 `null`（保持当前值）
  static DynamicSchemeVariant? _decodeVariant(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final DynamicSchemeVariant variant in DynamicSchemeVariant.values) {
      if (variant.name == raw) {
        return variant;
      }
    }
    return null;
  }

  static bool? _decodeContrast(String? raw) {
    if (raw == '1') {
      return true;
    }
    if (raw == '0') {
      return false;
    }
    return null;
  }

  /// `system` → null（跟随系统）；十进制 ARGB → Color；其余非法值 → null
  static Color? _decodeSeed(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    if (raw == _systemSeedValue) {
      return null;
    }
    final int? value = int.tryParse(raw);
    if (value == null) {
      return null;
    }
    return Color(value);
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

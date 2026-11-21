import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/text/lyric_font.dart';
import '../../theme/app_theme.dart';

/// 主题状态：深浅模式 + 强调色种子。改动立即生效，并异步写入本地存储。
///
/// 强调色有三级来源，优先级从高到低：
/// - **动态主题色**（`followsCover`）：取 [updateCoverSeed] 注入的封面色，
///   开着时压过下面两级；
/// - 手动强调色：`seedColor` 非 `null` 时的存档；
/// - 跟随系统：`seedColor` 为 `null`，取 [updateSystemAccent] 注入的系统强调色；
///   都没有再回落 [AppTheme.defaultSeed]。
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initialMode = ThemeMode.system})
    : _mode = initialMode;

  /// 存储键；单独暴露便于测试直接断言写入内容。
  static const String prefsKey = 'theme_mode';

  /// 强调色存储键：`system` 跟随系统、`cover` 跟随封面，其余为 0xAARRGGBB 的十进制字符串。
  static const String seedPrefsKey = 'theme_seed';

  /// 调色板风格存储键：存 `DynamicSchemeVariant.name`。
  static const String variantPrefsKey = 'theme_variant';

  /// 高对比存储键：'1' / '0'。
  static const String contrastPrefsKey = 'theme_contrast';

  /// 界面字体存储键：字体族名，空串 = 默认（微软雅黑 Light）。
  static const String fontPrefsKey = 'theme_font';

  /// 上次封面色存储键：0xAARRGGBB 的十进制字符串。
  ///
  /// 与 [seedPrefsKey] 分开：那个记的是「模式」（跟随封面只写一个哨兵值），
  /// 这里存**具体颜色**。开机第一帧就按它上色，等这次的取色回来再校正，
  /// 免得先闪一下手选色 / 系统色 —— 封面色解码要 40ms 上下，肉眼看得见。
  static const String coverSeedPrefsKey = 'theme_cover_seed';

  /// 手选色存储键：0xAARRGGBB 的十进制字符串。
  ///
  /// 与 [seedPrefsKey] 分开：跟随封面时那个键写的是哨兵值 `cover`，手选色会被
  /// 覆盖掉，重启后再关掉跟随就回不到原来的颜色了。
  static const String handSeedPrefsKey = 'theme_hand_seed';

  static const String _systemSeedValue = 'system';

  /// 跟随封面的存储值
  static const String _coverSeedValue = 'cover';

  /// 跟随封面时强制使用的调色板风格（定义在 [AppTheme]，取色一侧也要用同一个）。
  static const DynamicSchemeVariant coverVariant = AppTheme.coverVariant;

  ThemeMode _mode;
  Color? _seedColor;
  DynamicSchemeVariant _variant = AppTheme.defaultVariant;
  bool _highContrast = false;
  String _fontFamily = '';

  /// 系统强调色缓存；由外部（启动时 / 切到跟随系统时）注入
  Color? _systemAccent;

  /// 最近一次从封面取到的、可用的种子色。
  ///
  /// **只在取到合格颜色时更新**：灰封面 / 纯黑白封面不算数，保持上一个颜色，
  /// 否则每遇到一张黑白封面界面就跳回默认色。
  Color? _coverSeed;

  /// 强调色是否跟随封面
  bool _followCover = false;

  /// 防止异步恢复晚于用户操作或销毁：恢复不再覆盖新选择，也不在销毁后通知。
  bool _disposed = false;
  bool _userChanged = false;

  ThemeMode get mode => _mode;

  /// 用户选定的强调色；`null` 表示没有手选（跟随系统或跟随封面）。
  Color? get seedColor => _seedColor;

  /// 调色板风格（Tonal spot / Vibrant / Monochrome…）。
  DynamicSchemeVariant get schemeVariant => _variant;

  /// 实际生效的调色板风格：跟随封面时固定 [coverVariant]。
  DynamicSchemeVariant get effectiveVariant =>
      _followCover ? coverVariant : _variant;

  /// 是否用高对比色阶（contrastLevel = 1.0）。
  bool get highContrast => _highContrast;

  /// 界面字体族名；空串 = 默认字体（[AppTheme.fontFamily]）。
  String get fontFamily => _fontFamily;

  /// 是否跟随封面取色。
  ///
  /// 播放侧据此决定要不要为取色去解码封面——关掉时一帧都不多花。
  bool get followsCover => _followCover;

  /// 最近一次读到的系统强调色；`null` 表示未知（非 Windows / 读取失败）。
  Color? get systemAccent => _systemAccent;

  /// 最近一次从封面取到的种子色（尚未取到过时为 `null`）。
  Color? get coverSeed => _coverSeed;

  /// 最近一次封面色落盘的 Future；仅供测试等待写入完成。
  @visibleForTesting
  Future<void>? get coverSeedWrite => _coverSeedWrite;

  /// 封面色写入的中介（`updateCoverSeed` 是同步接口，写盘在后面跑）。
  Future<void>? _coverSeedWrite;

  /// 等待落盘的最新封面色；写盘在飞时只更新它，不并发发第二次。
  String? _pendingCoverSeedRaw;

  /// 实际生效的种子色：跟随封面 > 用户选择 > 系统强调色 > 默认暖黄。
  Color get effectiveSeed => _followCover
      ? (_coverSeed ?? _seedColor ?? _systemAccent ?? AppTheme.defaultSeed)
      : (_seedColor ?? _systemAccent ?? AppTheme.defaultSeed);

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
      final String? savedSeedRaw = prefs.getString(seedPrefsKey);
      if (savedSeedRaw == _coverSeedValue) {
        if (!_followCover) {
          _followCover = true;
          changed = true;
        }
        // 手选色单独存着：跟随封面时它不生效，但关掉开关要能回去
        _seedColor = _decodeSeed(prefs.getString(handSeedPrefsKey));
      } else {
        final Color? savedSeed = _decodeSeed(savedSeedRaw);
        if (_followCover) {
          _followCover = false;
          changed = true;
        }
        if (savedSeed != _seedColor) {
          _seedColor = savedSeed;
          changed = true;
        }
      }
      // 上次的封面色：开机第一帧就用它，等这次的取色回来再校正（免得闪一下）
      final Color? savedCoverSeed = _decodeSeed(
        prefs.getString(coverSeedPrefsKey),
      );
      if (savedCoverSeed != null && savedCoverSeed != _coverSeed) {
        _coverSeed = savedCoverSeed;
        // 不跟随时界面不变，不必通知；跟着时这就是首帧的颜色
        if (_followCover) {
          changed = true;
        }
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
      // 早先随包发过 MiSans 的四个字重，存档里可能是旧别名：过一遍归一
      final String savedFont = normalizeLyricFontFamily(
        prefs.getString(fontPrefsKey) ?? '',
      );
      if (savedFont != _fontFamily) {
        _fontFamily = savedFont;
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

  /// 设置手动强调色；传 `null` 表示跟随系统。
  ///
  /// 只是改「手动档」的存档：**「动态主题色」开关开着时它不生效**（封面色优先），
  /// 关掉开关后立刻回到这里存的值。所以这个方法不动开关状态。
  Future<void> setSeedColor(Color? color) async {
    if (_disposed || color == _seedColor) {
      return;
    }
    _userChanged = true;
    _seedColor = color;
    notifyListeners();
    await _persistSeed();
  }

  /// 切换「强调色跟随封面」。
  ///
  /// 关闭时回到手选色（没选过就回跟随系统），不会把当前封面色固定下来——
  /// 那样下次打开就又锁死在一个颜色上了。
  Future<void> setFollowCover(bool value) async {
    if (_disposed || value == _followCover) {
      return;
    }
    _userChanged = true;
    _followCover = value;
    notifyListeners();
    await _persistSeed();
  }

  /// 注入从封面取到的种子色。传 `null` 表示这张封面没有合格的候选（太灰）。
  ///
  /// `null` 只被当作「这次不算」，不会清掉上一个色：否则每遇到一张黑白封面，
  /// 界面就跳回默认色，下一首又跳回去，比不跟随还乱。
  void updateCoverSeed(Color? color) {
    if (_disposed || color == null || color == _coverSeed) {
      return;
    }
    _coverSeed = color;
    // 没在跟随时界面不变，不必通知（取色本身还是会缓存下来，切过去立刻就位）
    if (_followCover) {
      notifyListeners();
    }
    _pendingCoverSeedRaw = color.toARGB32().toString();
    // 单飞 + 最新值优先：连点下一首时几次写入排队会乱序落盘，只剩最后那次才算数
    _coverSeedWrite ??= _drainCoverSeed();
  }

  Future<void> _drainCoverSeed() async {
    try {
      while (_pendingCoverSeedRaw != null) {
        final String raw = _pendingCoverSeedRaw!;
        _pendingCoverSeedRaw = null;
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString(coverSeedPrefsKey, raw);
      }
    } catch (error) {
      debugPrint('保存封面色失败：$error');
    } finally {
      _coverSeedWrite = null;
    }
  }

  Future<void> _persistSeed() async {
    final String raw = _followCover
        ? _coverSeedValue
        : (_seedColor?.toARGB32().toString() ?? _systemSeedValue);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(seedPrefsKey, raw);
      // 手选色另存一份：上面那个键在跟随时写的是哨兵值，不存这份就丢了
      final String? hand = _seedColor?.toARGB32().toString();
      if (hand == null) {
        await prefs.remove(handSeedPrefsKey);
      } else {
        await prefs.setString(handSeedPrefsKey, hand);
      }
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

  /// 切换界面字体；空串 = 回到默认（微软雅黑 Light）。
  Future<void> setFontFamily(String family) async {
    final String name = family.trim();
    if (_disposed || name == _fontFamily) {
      return;
    }
    _userChanged = true;
    _fontFamily = name;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (name.isEmpty) {
        await prefs.remove(fontPrefsKey);
      } else {
        await prefs.setString(fontPrefsKey, name);
      }
    } catch (error) {
      debugPrint('保存界面字体失败：$error');
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

  /// 取到控制器但**不登记依赖**。
  ///
  /// 给「只在事件里读一下、不需要跟着重建」的调用方用（比如播放侧判断要不要
  /// 为动态主题去取色）。用 [maybeOf] 会让那个 widget 在每次换主题时重建一次。
  static ThemeController? readOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ThemeScope>()?.notifier;
}

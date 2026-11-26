import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('默认跟随系统', () {
    expect(ThemeController().mode, ThemeMode.system);
  });

  test('restore 读取已保存的模式', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.prefsKey: 'dark',
    });

    final ThemeController controller = ThemeController();
    await controller.restore();

    expect(controller.mode, ThemeMode.dark);
  });

  test('存储值非法时保持默认', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.prefsKey: 'purple',
    });

    final ThemeController controller = ThemeController();
    await controller.restore();

    expect(controller.mode, ThemeMode.system);
  });

  test('setMode 通知监听者并写入存储', () async {
    final ThemeController controller = ThemeController();
    int notified = 0;
    controller.addListener(() => notified += 1);

    await controller.setMode(ThemeMode.light);

    expect(controller.mode, ThemeMode.light);
    expect(notified, 1);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.prefsKey), 'light');
  });

  test('设为相同值不触发通知', () async {
    final ThemeController controller = ThemeController();
    int notified = 0;
    controller.addListener(() => notified += 1);

    await controller.setMode(ThemeMode.system);

    expect(notified, 0);
  });

  test('写入后可被新实例恢复', () async {
    await ThemeController().setMode(ThemeMode.dark);

    final ThemeController restored = ThemeController();
    await restored.restore();

    expect(restored.mode, ThemeMode.dark);
  });

  test('restore 不覆盖用户已做的选择', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.prefsKey: 'dark',
    });

    final ThemeController controller = ThemeController();
    final Future<void> restoring = controller.restore();
    await controller.setMode(ThemeMode.light);
    await restoring;

    expect(controller.mode, ThemeMode.light);
  });

  test('dispose 后完成的 restore 不再改状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.prefsKey: 'dark',
    });

    final ThemeController controller = ThemeController();
    final Future<void> restoring = controller.restore();
    controller.dispose();
    await restoring;

    expect(controller.mode, ThemeMode.system);
  });

  test('封面色会落盘，新实例恢复后首帧就用它', () async {
    const Color seed = Color(0xFF7B1FA2);
    final ThemeController controller = ThemeController();
    await controller.setFollowCover(true);
    controller.updateCoverSeed(seed);
    await controller.coverSeedWrite;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.coverSeedPrefsKey), isNotNull);

    final ThemeController restored = ThemeController();
    await restored.restore();

    expect(restored.followsCover, isTrue);
    expect(restored.coverSeed, seed);
    expect(restored.effectiveSeed, seed, reason: '开机首帧就该是上次的封面色，不能先闪一下手选色');
  });

  test('跟随封面不会把手选色弄丢', () async {
    final ThemeController controller = ThemeController();
    await controller.setSeedColor(const Color(0xFF00897B));
    await controller.setFollowCover(true);
    controller.updateCoverSeed(const Color(0xFF7B1FA2));
    await controller.coverSeedWrite;

    // 重启：跟随时 seedPrefsKey 里是哨兵值，手选色得靠另一个键活下来
    final ThemeController restored = ThemeController();
    await restored.restore();

    expect(restored.followsCover, isTrue);
    expect(restored.effectiveSeed, const Color(0xFF7B1FA2));
    expect(restored.seedColor, const Color(0xFF00897B));

    await restored.setFollowCover(false);
    expect(
      restored.effectiveSeed,
      const Color(0xFF00897B),
      reason: '关掉跟随后回到手选色',
    );
  });

  test('默认强调色跟随系统，生效色回落默认种子', () {
    final ThemeController controller = ThemeController();

    expect(controller.seedColor, isNull);
    expect(controller.effectiveSeed, AppTheme.defaultSeed);
  });

  test('updateSystemAccent 生效于 effectiveSeed', () {
    final ThemeController controller = ThemeController();
    const Color accent = Color(0xFF2196F3);

    controller.updateSystemAccent(accent);

    expect(controller.systemAccent, accent);
    expect(controller.effectiveSeed, accent);
  });

  test('自定义强调色优先于系统强调色', () async {
    final ThemeController controller = ThemeController();
    const Color accent = Color(0xFF2196F3);
    const Color custom = Color(0xFFF44336);

    controller.updateSystemAccent(accent);
    expect(controller.effectiveSeed, accent);

    await controller.setSeedColor(custom);
    expect(controller.effectiveSeed, custom);

    // 切回跟随系统后重新由系统强调色生效
    await controller.setSeedColor(null);
    expect(controller.effectiveSeed, accent);
  });

  test('setSeedColor 写入存储并可恢复；null 表示跟随系统', () async {
    const Color custom = Color(0xFF4CAF50);
    final ThemeController controller = ThemeController();
    await controller.setSeedColor(custom);

    expect(controller.seedColor, custom);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(ThemeController.seedPrefsKey),
      custom.toARGB32().toString(),
    );

    final ThemeController restored = ThemeController();
    await restored.restore();
    expect(restored.seedColor, custom);

    await restored.setSeedColor(null);
    final SharedPreferences prefs2 = await SharedPreferences.getInstance();
    expect(prefs2.getString(ThemeController.seedPrefsKey), 'system');
    expect(restored.seedColor, isNull);
  });

  test('restore 支持跟随系统标记', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.seedPrefsKey: 'system',
    });

    final ThemeController controller = ThemeController();
    await controller.restore();

    expect(controller.seedColor, isNull);
  });

  test('restore 非法强调色值时保持默认', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.seedPrefsKey: 'purple',
    });

    final ThemeController controller = ThemeController();
    await controller.restore();

    expect(controller.seedColor, isNull);
  });

  test('切到自定义色后生效色不再跟随系统', () {
    final ThemeController controller = ThemeController();
    const Color accent = Color(0xFF2196F3);
    controller.updateSystemAccent(accent);

    const Color custom = Color(0xFF9C27B0);
    // setSeedColor 的存储写入是异步的，但内存状态同步生效
    unawaited(controller.setSeedColor(custom));

    expect(controller.seedColor, custom);
    expect(controller.effectiveSeed, custom);
  });

  test('默认 Expressive 且非高对比', () {
    final ThemeController controller = ThemeController();

    expect(controller.schemeVariant, AppTheme.defaultVariant);
    expect(controller.highContrast, isFalse);
  });

  test('setSchemeVariant 写入存储并可恢复', () async {
    final ThemeController controller = ThemeController();
    await controller.setSchemeVariant(DynamicSchemeVariant.vibrant);

    expect(controller.schemeVariant, DynamicSchemeVariant.vibrant);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.variantPrefsKey), 'vibrant');

    final ThemeController restored = ThemeController();
    await restored.restore();
    expect(restored.schemeVariant, DynamicSchemeVariant.vibrant);
  });

  test('restore 非法风格名保持默认', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.variantPrefsKey: 'jolly',
    });

    final ThemeController controller = ThemeController();
    await controller.restore();

    expect(controller.schemeVariant, AppTheme.defaultVariant);
  });

  test('setHighContrast 持久化并可恢复', () async {
    final ThemeController controller = ThemeController();
    await controller.setHighContrast(true);

    expect(controller.highContrast, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.contrastPrefsKey), '1');

    final ThemeController restored = ThemeController();
    await restored.restore();
    expect(restored.highContrast, isTrue);
  });

  test('默认不跟随封面', () {
    final ThemeController controller = ThemeController();
    expect(controller.followsCover, isFalse);
    expect(controller.coverSeed, isNull);
  });

  test('开启跟随后生效色取封面种子色，并持久化为 cover', () async {
    final ThemeController controller = ThemeController();
    controller.updateSystemAccent(const Color(0xFF2196F3));
    await controller.setFollowCover(true);
    controller.updateCoverSeed(const Color(0xFFE91E63));

    expect(controller.effectiveSeed, const Color(0xFFE91E63));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.seedPrefsKey), 'cover');

    final ThemeController restored = ThemeController();
    await restored.restore();
    expect(restored.followsCover, isTrue);
    expect(restored.seedColor, isNull);
  });

  test('封面太灰（null）时保持上一个颜色，不回落', () async {
    final ThemeController controller = ThemeController();
    await controller.setFollowCover(true);
    controller.updateCoverSeed(const Color(0xFF4CAF50));

    controller.updateCoverSeed(null);

    expect(controller.coverSeed, const Color(0xFF4CAF50));
    expect(controller.effectiveSeed, const Color(0xFF4CAF50));
  });

  test('还没取到封面色时按手选色 / 系统色回落', () async {
    final ThemeController controller = ThemeController();
    const Color custom = Color(0xFF9C27B0);
    await controller.setSeedColor(custom);
    await controller.setFollowCover(true);

    expect(controller.effectiveSeed, custom, reason: '封面还没取到，先用之前的颜色');

    controller.updateCoverSeed(const Color(0xFFFF9800));
    expect(controller.effectiveSeed, const Color(0xFFFF9800));
  });

  test('开关开着时手动选色只改存档，不生效也不退出', () async {
    final ThemeController controller = ThemeController();
    await controller.setFollowCover(true);
    controller.updateCoverSeed(const Color(0xFFE91E63));

    await controller.setSeedColor(const Color(0xFF009688));

    expect(controller.followsCover, isTrue, reason: '开关是总闸，选色不动它');
    expect(controller.effectiveSeed, const Color(0xFFE91E63), reason: '封面色优先');
    expect(
      controller.seedColor,
      const Color(0xFF009688),
      reason: '但存档要更新，关掉开关就能用',
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.seedPrefsKey), 'cover');
  });

  test('开关开着时切跟随系统同样只改存档', () async {
    final ThemeController controller = ThemeController();
    await controller.setFollowCover(true);

    await controller.setSeedColor(null);

    expect(controller.followsCover, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.seedPrefsKey), 'cover');
  });

  test('关闭跟随后恢复之前的持久化状态', () async {
    const Color custom = Color(0xFF3F51B5);
    final ThemeController controller = ThemeController();
    await controller.setSeedColor(custom);
    await controller.setFollowCover(true);
    await controller.setFollowCover(false);

    expect(controller.followsCover, isFalse);
    expect(controller.effectiveSeed, custom);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(ThemeController.seedPrefsKey),
      custom.toARGB32().toString(),
    );
  });

  test('没在跟随时注入了封面色也不通知界面', () async {
    final ThemeController controller = ThemeController();
    int notified = 0;
    controller.addListener(() => notified += 1);

    controller.updateCoverSeed(const Color(0xFFE91E63));

    expect(notified, 0, reason: '颜色不生效就没必要重建');
    expect(
      controller.coverSeed,
      const Color(0xFFE91E63),
      reason: '但要存下来，切过去立刻可用',
    );
  });

  test('跟随封面时调色板风格固定为 Fidelity', () async {
    final ThemeController controller = ThemeController();
    expect(controller.effectiveVariant, AppTheme.defaultVariant);

    await controller.setFollowCover(true);
    expect(controller.effectiveVariant, ThemeController.coverVariant);
    expect(
      controller.schemeVariant,
      AppTheme.defaultVariant,
      reason: '用户的选择不丢',
    );

    await controller.setFollowCover(false);
    expect(controller.effectiveVariant, AppTheme.defaultVariant);
  });

  test('界面字体默认是空串，切换后落盘并通知界面', () async {
    final ThemeController controller = ThemeController();
    expect(controller.fontFamily, isEmpty);

    int notified = 0;
    controller.addListener(() => notified += 1);
    await controller.setFontFamily('SimSun');

    expect(controller.fontFamily, 'SimSun');
    expect(notified, 1);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.fontPrefsKey), 'SimSun');

    // 同值再设一次不重复通知、不重复写盘
    await controller.setFontFamily('SimSun');
    expect(notified, 1);

    // 回到默认 = 删键
    await controller.setFontFamily('');
    expect(controller.fontFamily, isEmpty);
    expect(prefs.getString(ThemeController.fontPrefsKey), isNull);
  });

  test('restore 读取已保存的界面字体，并把旧字重别名归一', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.fontPrefsKey: 'SimSun',
    });
    final ThemeController controller = ThemeController();
    await controller.restore();
    expect(controller.fontFamily, 'SimSun');

    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.fontPrefsKey: 'MiSans Bold',
    });
    final ThemeController legacy = ThemeController();
    await legacy.restore();
    expect(
      legacy.fontFamily,
      'MiSans Bold',
      reason: '字体没注册时原样保留，注册后由下拉归一到 MiSans',
    );
  });
}

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

  test('默认 Tonal spot 且非高对比', () {
    final ThemeController controller = ThemeController();

    expect(controller.schemeVariant, DynamicSchemeVariant.tonalSpot);
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

    expect(controller.schemeVariant, DynamicSchemeVariant.tonalSpot);
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
}

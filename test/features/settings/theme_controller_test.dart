import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
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
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decideCloseAction', () {
    test('默认把关闭变成「隐藏到托盘」', () {
      expect(
        decideCloseAction(
          closeToTray: true,
          quitRequested: false,
          trayAvailable: true,
        ),
        CloseAction.hideToTray,
      );
    });

    test('托盘菜单「退出」优先于偏好', () {
      expect(
        decideCloseAction(
          closeToTray: true,
          quitRequested: true,
          trayAvailable: true,
        ),
        CloseAction.quit,
      );
    });

    test('托盘不可用时直接退出：藏起窗口而没有托盘就再也打不开', () {
      expect(
        decideCloseAction(
          closeToTray: true,
          quitRequested: false,
          trayAvailable: false,
        ),
        CloseAction.quit,
      );
    });

    test('用户关掉偏好时直接退出', () {
      expect(
        decideCloseAction(
          closeToTray: false,
          quitRequested: false,
          trayAvailable: true,
        ),
        CloseAction.quit,
      );
    });
  });

  test('关闭到托盘偏好会持久化并在启动时恢复', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppLifecycle lifecycle = AppLifecycle();
    expect(lifecycle.closeToTray, isTrue, reason: '默认开启');

    int notifications = 0;
    lifecycle.addListener(() => notifications += 1);
    lifecycle.closeToTray = false;
    expect(notifications, 1, reason: '设置页要跟着刷新');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final AppLifecycle restored = AppLifecycle();
    await restored.restore();
    expect(restored.closeToTray, isFalse);
  });

  test('重复设置同一个值不会触发通知', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppLifecycle lifecycle = AppLifecycle();
    int notifications = 0;
    lifecycle.addListener(() => notifications += 1);

    lifecycle.closeToTray = true;
    expect(notifications, 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('退出请求一旦设置就保持', () {
    final AppLifecycle lifecycle = AppLifecycle();
    expect(lifecycle.quitRequested, isFalse);
    lifecycle.requestQuit();
    expect(lifecycle.quitRequested, isTrue);
  });
}

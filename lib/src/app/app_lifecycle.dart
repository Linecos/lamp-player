import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 关闭窗口时该做什么。
enum CloseAction {
  /// 隐藏窗口、留在托盘，音乐继续播放
  hideToTray,

  /// 真正退出应用
  quit,
}

/// 决定关闭行为。
///
/// 三条例外优先于「关到托盘」偏好：
/// 1. 用户从托盘菜单点了「退出」（`quitRequested`）；
/// 2. 托盘不可用——把窗口藏起来而托盘没起来，用户既看不到界面也没法再打开，
///    只剩任务管理器一条路；
/// 3. 用户关掉了这个偏好。
CloseAction decideCloseAction({
  required bool closeToTray,
  required bool quitRequested,
  required bool trayAvailable,
}) {
  if (quitRequested || !trayAvailable || !closeToTray) {
    return CloseAction.quit;
  }
  return CloseAction.hideToTray;
}

/// 应用级行为状态：关闭到托盘、退出请求。
///
/// 全应用共享一个实例：窗口关闭逻辑在 `main.dart`，开关在设置页，两边都要读
/// 同一个值。与 `SessionSnapshot` 分开存（`ui_close_to_tray`），避免和播放会话
/// 的高频保存互相覆盖。
class AppLifecycle extends ChangeNotifier {
  /// [closeToTray] 默认开启：音乐播放器关窗不该停音乐。
  /// 用具名参数会把私有字段名暴露成参数名（Dart 不允许），所以用位置参数。
  AppLifecycle([this._closeToTray = true]);

  static const String prefsKey = 'ui_close_to_tray';

  bool _closeToTray;
  bool _quitRequested = false;

  /// 关闭窗口时是否隐藏到托盘（默认开启：音乐播放器关窗不该停音乐）
  bool get closeToTray => _closeToTray;

  set closeToTray(bool value) {
    if (_closeToTray == value) {
      return;
    }
    _closeToTray = value;
    notifyListeners();
    unawaited(_save(value));
  }

  /// 已请求退出（托盘菜单「退出」）：关闭流程不再隐藏窗口
  bool get quitRequested => _quitRequested;

  void requestQuit() {
    _quitRequested = true;
  }

  /// 读取已保存的偏好；失败时保持默认值
  Future<void> restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool? saved = prefs.getBool(prefsKey);
      if (saved != null && saved != _closeToTray) {
        _closeToTray = saved;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('读取关闭到托盘偏好失败：$error');
    }
  }

  Future<void> _save(bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (error) {
      // 只影响下次启动的默认行为
      debugPrint('保存关闭到托盘偏好失败：$error');
    }
  }
}

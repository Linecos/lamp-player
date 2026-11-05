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

  /// 退出前要完成的事（例如把播放会话落盘）
  Future<void> Function()? _beforeExit;

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

  /// 注册「真正退出前」的钩子；页面销毁时用 [clearBeforeExit] 注销。
  ///
  /// 关闭到托盘时不会调用：音乐还在播，会话照常按 10 秒周期落盘。
  void setBeforeExit(Future<void> Function() hook) {
    _beforeExit = hook;
  }

  void clearBeforeExit(Future<void> Function() hook) {
    if (identical(_beforeExit, hook)) {
      _beforeExit = null;
    }
  }

  /// 执行退出前钩子；失败或超时都不阻断退出流程。
  Future<void> runBeforeExit() async {
    final Future<void> Function()? hook = _beforeExit;
    if (hook == null) {
      return;
    }
    try {
      await hook().timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('退出前保存失败：$error');
    }
  }

  /// 退出清理是否已经跑过。
  ///
  /// 托盘菜单「退出」是「先清理、再关窗」，而关窗又会触发
  /// `_handleClose` 的退出分支 —— 不加这个标志，会话落盘与关库会跑两遍，
  /// 第二遍时引擎已经关掉，写回去的是空状态。
  bool _shutdownStarted = false;

  bool get shutdownStarted => _shutdownStarted;

  /// 真正退出前的清理：**只跑第一次**。
  ///
  /// [release] 是释放引擎 / 系统媒体 / 曲库的那一步（`_shutdownResources`）。
  Future<void> runShutdownOnce(Future<void> Function() release) async {
    if (_shutdownStarted) {
      return;
    }
    _shutdownStarted = true;
    await runBeforeExit();
    try {
      await release();
    } catch (error) {
      debugPrint('释放资源失败：$error');
    }
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

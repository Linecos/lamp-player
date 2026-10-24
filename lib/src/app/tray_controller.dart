import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

/// 托盘图标与菜单。
///
/// 菜单只留「显示主窗口 / 退出」两项：播放控制交给 SMTC（媒体键、任务栏缩略图）
/// 和主界面，托盘菜单越长越难用。
///
/// 初始化失败（图标缺失、系统限制）不影响主功能，只是关窗会退化成直接退出
/// （见 `decideCloseAction`）。
class TrayController with TrayListener {
  TrayController({required this.onShow, required this.onQuit});

  final Future<void> Function() onShow;
  final Future<void> Function() onQuit;

  bool _ready = false;

  /// 托盘是否可用；关窗逻辑据此决定是隐藏还是退出
  bool get available => _ready;

  Future<void> init() async {
    if (_ready) {
      return;
    }
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Lamp Player');
      await trayManager.setContextMenu(
        Menu(
          items: <MenuItem>[
            MenuItem(key: 'show', label: '显示主窗口'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: '退出'),
          ],
        ),
      );
      trayManager.addListener(this);
      _ready = true;
    } catch (error) {
      debugPrint('托盘初始化失败：$error');
    }
  }

  /// 托盘提示跟随当前曲目，鼠标悬停就能看到在放什么
  Future<void> updateNowPlaying(String? title, String? artist) async {
    if (!_ready) {
      return;
    }
    final String tip;
    if (title == null || title.isEmpty) {
      tip = 'Lamp Player';
    } else if (artist == null || artist.isEmpty) {
      tip = 'Lamp Player · $title';
    } else {
      tip = 'Lamp Player · $artist - $title';
    }
    try {
      await trayManager.setToolTip(tip);
    } catch (error) {
      debugPrint('更新托盘提示失败：$error');
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(onShow());
  }

  /// Windows 上右键菜单由插件弹出；双击也当「显示」
  @override
  void onTrayIconMouseUp() {}

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(onShow());
      case 'quit':
        unawaited(onQuit());
    }
  }

  Future<void> dispose() async {
    if (!_ready) {
      return;
    }
    _ready = false;
    try {
      trayManager.removeListener(this);
      await trayManager.destroy();
    } catch (error) {
      debugPrint('销毁托盘失败：$error');
    }
  }
}

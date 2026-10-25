import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

/// 托盘菜单项（纯函数，便于单测断言文案与可用状态）。
///
/// 顺序有意如此：播放控制在最上面（关窗后最常用的操作），
/// 「显示主窗口 / 退出」放最下面，避免误点退出。
List<MenuItem> trayMenuItems({required bool hasTrack, required bool playing}) {
  final bool enabled = hasTrack;
  return <MenuItem>[
    MenuItem(
      key: 'play_pause',
      label: playing ? '暂停' : '播放',
      disabled: !enabled,
    ),
    MenuItem(key: 'previous', label: '上一首', disabled: !enabled),
    MenuItem(key: 'next', label: '下一首', disabled: !enabled),
    MenuItem.separator(),
    MenuItem(key: 'show', label: '显示主窗口'),
    MenuItem.separator(),
    MenuItem(key: 'quit', label: '退出'),
  ];
}

/// 托盘图标与菜单。
///
/// 左键单击唤起窗口，右键弹出菜单（Windows 下插件不会自动弹，必须自己调
/// [TrayManager.popUpContextMenu]）。菜单提供播放控制快捷操作，
/// 状态由曲库页通过 [updatePlayback] 同步；未绑定播放回调时这些项禁用。
///
/// 初始化失败（图标缺失、系统限制）不影响主功能，只是关窗会退化成直接退出
/// （见 `decideCloseAction`）。
class TrayController with TrayListener {
  TrayController({required this.onShow, required this.onQuit});

  final Future<void> Function() onShow;
  final Future<void> Function() onQuit;

  bool _ready = false;

  /// 上一次下发到菜单的状态，避免同一状态反复重建菜单
  bool? _hasTrack;
  bool? _playing;

  VoidCallback? _onTogglePlay;
  VoidCallback? _onNext;
  VoidCallback? _onPrevious;

  /// 托盘是否可用；关窗逻辑据此决定是隐藏还是退出
  bool get available => _ready;

  Future<void> init() async {
    if (_ready) {
      return;
    }
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Lamp Player');
      await _applyMenu(hasTrack: false, playing: false);
      trayManager.addListener(this);
      _ready = true;
    } catch (error) {
      debugPrint('托盘初始化失败：$error');
    }
  }

  /// 绑定播放控制；曲库页创建时调用，销毁时 [unbindPlayback]。
  void bindPlayback({
    required VoidCallback onTogglePlay,
    required VoidCallback onNext,
    required VoidCallback onPrevious,
  }) {
    _onTogglePlay = onTogglePlay;
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  void unbindPlayback() {
    _onTogglePlay = null;
    _onNext = null;
    _onPrevious = null;
  }

  /// 同步播放状态到菜单（播放/暂停文案、无曲目时禁用）。
  ///
  /// 只在状态真的变化时重建菜单，避免 500ms 轮询反复调 setContextMenu。
  Future<void> updatePlayback({
    required bool hasTrack,
    required bool playing,
  }) async {
    if (!_ready || (_hasTrack == hasTrack && _playing == playing)) {
      return;
    }
    await _applyMenu(hasTrack: hasTrack, playing: playing);
  }

  Future<void> _applyMenu({
    required bool hasTrack,
    required bool playing,
  }) async {
    _hasTrack = hasTrack;
    _playing = playing;
    try {
      await trayManager.setContextMenu(
        Menu(
          items: trayMenuItems(hasTrack: hasTrack, playing: playing),
        ),
      );
    } catch (error) {
      debugPrint('更新托盘菜单失败：$error');
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

  /// 左键单击 / 双击：把窗口唤到前台
  @override
  void onTrayIconMouseDown() {
    unawaited(onShow());
  }

  /// Windows 上右键菜单不会自动弹出，必须在这里显式请求。
  ///
  /// 插件把 `WM_RBUTTONUP` 映射成 `onTrayIconRightMouseDown`，所以在这个
  /// 回调里弹出正好是「右键抬起」的时机。
  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'play_pause':
        _onTogglePlay?.call();
      case 'previous':
        _onPrevious?.call();
      case 'next':
        _onNext?.call();
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

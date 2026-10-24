import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/app/app_lifecycle.dart';
import 'package:lamp_player/src/app/tray_controller.dart';
import 'package:lamp_player/src/app/window_state.dart';
import 'package:lamp_player/src/features/library/library_db.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/rust/api/media.dart' as media;
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/rust/frb_generated.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// 应用入口。
///
/// 启动顺序有讲究：
/// 1. 建窗（先注册「就绪后再显示」，避免闪一下系统标题栏）；
/// 2. Rust 桥接；
/// 3. **单实例检查**——第二个进程在这里就退出，`runApp` 还没执行，窗口不会闪；
/// 4. 曲库、主题、托盘、窗口监听；
/// 5. `runApp`。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尺寸先读出来再建窗，避免先按默认大小闪一下；存储异常时 1 秒后按默认尺寸继续
  const WindowStateStore windowStore = PrefsWindowStateStore();
  final WindowSnapshot windowState = await windowStore.load().timeout(
    const Duration(seconds: 1),
    onTimeout: () => const WindowSnapshot(),
  );
  await _setupWindow(windowState);

  try {
    await RustLib.init();
  } catch (error) {
    // DLL 缺失、架构不匹配等会走到这里：给一个能看懂的界面，而不是白屏
    debugPrint('Rust 桥接初始化失败：$error');
    await _runStartupError(message: '$error');
    return;
  }

  // 已有实例在运行：把它的窗口提到前台，本进程直接退出。
  // 两个实例同时跑会让第二个抢不到 WASAPI 独占设备，静默回落共享输出。
  if (!await _becomeSingleInstance()) {
    exit(0);
  }

  try {
    await initLibrary();
  } catch (error) {
    // 支持目录不可写、数据库损坏等
    debugPrint('曲库初始化失败：$error');
    await _runStartupError(title: '启动失败：曲库未能打开', message: '$error');
    return;
  }

  // 先恢复主题与「关闭到托盘」再挂载，避免深色用户启动时先闪一下浅色
  final ThemeController theme = ThemeController();
  await theme.restore();
  final AppLifecycle lifecycle = AppLifecycle();
  await lifecycle.restore();

  final TrayController tray = TrayController(
    onShow: _showWindow,
    onQuit: () => _quitFromTray(lifecycle),
  );
  await tray.init();

  _AppWindowListener(windowStore, lifecycle, tray).attach();
  _watchActivationRequests();

  runApp(LampApp(themeController: theme, lifecycle: lifecycle));
}

/// 申请成为唯一实例；`false` 表示已有实例（已通知它把窗口亮出来）
Future<bool> _becomeSingleInstance() async {
  try {
    final bool first = await media.singleInstanceAcquire();
    if (!first) {
      await media.singleInstanceSignalExisting();
    }
    return first;
  } catch (error) {
    // 单实例只是体验优化：检查失败时宁可多开一个窗口，也不要打不开应用
    debugPrint('单实例检查失败（继续启动）：$error');
    return true;
  }
}

/// 每 500ms 看一眼有没有另一个进程请求唤起窗口。
///
/// 用轮询而不是让第二个进程跨进程 `ShowWindow`：那时它自己也有一个同名窗口，
/// `FindWindow` 会命中自己；由本实例调 `windowManager.show()` 才可靠。
void _watchActivationRequests() {
  Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (media.singleInstanceTakeActivation()) {
      unawaited(_showWindow());
    }
  });
}

/// 展示启动失败兜底页。
///
/// 这里必须先把 `preventClose` 放开：它在建窗时就打开了，而负责在关闭时解除
/// 拦截的 `_AppWindowListener` 要到初始化全部成功后才挂上。失败路径直接
/// `runApp` 的话，兜底页的 × 与 Alt+F4 都会被吞掉，只能任务管理器杀进程。
Future<void> _runStartupError({String? title, required String message}) async {
  try {
    await windowManager.setPreventClose(false);
  } catch (error) {
    debugPrint('解除关闭拦截失败：$error');
  }
  runApp(
    title == null
        ? LampStartupErrorApp(message: message)
        : LampStartupErrorApp(title: title, message: message),
  );
}

/// 从托盘恢复窗口
Future<void> _showWindow() async {
  try {
    await windowManager.show();
    await windowManager.focus();
  } catch (error) {
    debugPrint('显示窗口失败：$error');
  }
}

/// 托盘菜单「退出」：真正结束进程（关窗默认只是隐藏）
Future<void> _quitFromTray(AppLifecycle lifecycle) async {
  lifecycle.requestQuit();
  await _shutdownAudio();
  try {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  } catch (error) {
    debugPrint('退出失败：$error');
  }
}

/// 释放音频设备与系统媒体信息；任一步失败都继续往下
Future<void> _shutdownAudio() async {
  try {
    // 独占模式下设备只由本进程持有：显式释放，别等系统回收
    await rust.playerShutdown().timeout(const Duration(seconds: 2));
  } catch (error) {
    debugPrint('关闭播放引擎失败：$error');
  }
  try {
    await media.mediaClear().timeout(const Duration(seconds: 1));
  } catch (error) {
    debugPrint('清理系统媒体信息失败：$error');
  }
}

/// 关掉系统标题栏，改用应用内自绘的（见 `lib/src/app/title_bar.dart`）。
///
/// `TitleBarStyle.hidden` 只去掉标题栏，窗口边框、缩放、贴边/分屏手势仍由系统提供。
/// 失败时保持原生标题栏，界面里会同时出现两个标题栏，但至少能正常操作。
Future<void> _setupWindow(WindowSnapshot state) async {
  final Offset? position = await _restorePosition(state);
  try {
    await windowManager.ensureInitialized();
    // 关闭前要留出释放设备的时间（独占模式下设备由本进程持有）
    await windowManager.setPreventClose(true);
    final WindowOptions options = WindowOptions(
      title: 'Lamp Player',
      size: state.size,
      minimumSize: const Size(900, 560),
      // 没有可用的历史位置时才居中，避免每次启动都把窗口挪回主屏
      center: position == null,
      titleBarStyle: TitleBarStyle.hidden,
    );
    // 等首帧就绪后再 show，避免先闪一下系统标题栏
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        if (position != null) {
          await windowManager.setPosition(position);
        }
        if (state.maximized) {
          await windowManager.maximize();
        }
        await windowManager.show();
        await windowManager.focus();
      }),
    );
  } catch (error) {
    debugPrint('窗口初始化失败（保留系统标题栏）：$error');
  }
}

/// 校验记忆的窗口位置：显示器拔掉或分辨率变化后，旧坐标可能完全在屏幕外。
///
/// 读取显示器失败时保留记忆位置（总比强制居中更贴近用户预期）；
/// 有信息但位置不可见时返回 `null`，让窗口回到主屏中间。
Future<Offset?> _restorePosition(WindowSnapshot state) async {
  final Offset? saved = state.position;
  if (saved == null) {
    return null;
  }
  try {
    final List<Display> displays = await screenRetriever.getAllDisplays();
    final List<Rect> areas = displays.map((Display display) {
      final Offset origin = display.visiblePosition ?? Offset.zero;
      final Size size = display.visibleSize ?? display.size;
      return origin & size;
    }).toList();
    if (areas.isEmpty) {
      return saved;
    }
    return isWindowVisibleOn(position: saved, size: state.size, displays: areas)
        ? saved
        : null;
  } catch (error) {
    debugPrint('读取显示器信息失败：$error');
    return saved;
  }
}

/// 窗口生命周期：尺寸防抖落盘 + 关闭行为（隐藏到托盘 / 退出）。
///
/// 尺寸变化后防抖落盘；最大化时只记住「最大化」标记，尺寸沿用上一次普通状态。
class _AppWindowListener with WindowListener {
  _AppWindowListener(this._store, this._lifecycle, this._tray);

  final WindowStateStore _store;
  final AppLifecycle _lifecycle;
  final TrayController _tray;
  Timer? _timer;
  bool _closing = false;

  void attach() {
    windowManager.addListener(this);
  }

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowRestore() => _scheduleSave();

  @override
  void onWindowClose() {
    unawaited(_handleClose());
  }

  /// 关闭流程：按偏好隐藏到托盘，或落盘 → 关引擎 → 真正关窗。
  ///
  /// 任一步失败都要继续往下走，否则窗口会关不掉。
  Future<void> _handleClose() async {
    if (_closing) {
      return;
    }
    final CloseAction action = decideCloseAction(
      closeToTray: _lifecycle.closeToTray,
      quitRequested: _lifecycle.quitRequested,
      trayAvailable: _tray.available,
    );
    if (action == CloseAction.hideToTray) {
      _timer?.cancel();
      await _save();
      try {
        await windowManager.hide();
      } catch (error) {
        // 隐藏失败时不能把窗口留在「拦截关闭」状态，改为直接退出
        debugPrint('隐藏窗口失败，改为退出：$error');
        _lifecycle.requestQuit();
        await _handleClose();
      }
      return;
    }

    _closing = true;
    _timer?.cancel();
    try {
      await _save().timeout(const Duration(milliseconds: 800));
    } catch (error) {
      debugPrint('关闭前保存窗口状态失败：$error');
    }
    await _shutdownAudio();
    try {
      await windowManager.setPreventClose(false);
      // 用 close() 而不是 destroy()：后者只投一条 WM_QUIT，窗口不销毁，
      // 平台线程在收尾时会让进程卡成一个「未响应」的壳。
      await windowManager.close();
    } catch (error) {
      debugPrint('关闭窗口失败：$error');
    }
  }

  void _scheduleSave() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      // 隐藏到托盘时窗口不可见，isMinimized 仍为 false，尺寸照常可读
      if (await windowManager.isMinimized()) {
        return;
      }
      if (await windowManager.isFullScreen()) {
        return;
      }
      final bool maximized = await windowManager.isMaximized();
      final WindowSnapshot previous = await _store.load();
      final Size size = maximized
          ? previous.size
          : await windowManager.getSize();
      // 最大化时记录的是整屏几何，位置沿用上一次普通状态
      final Offset? position = maximized
          ? previous.position
          : await windowManager.getPosition();
      await _store.save(
        WindowSnapshot(size: size, position: position, maximized: maximized),
      );
    } catch (error) {
      // 只影响下次启动的窗口大小
      debugPrint('保存窗口状态失败：$error');
    }
  }
}

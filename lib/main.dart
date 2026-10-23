import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/app/window_state.dart';
import 'package:lamp_player/src/features/library/library_db.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// 应用入口。
///
/// 依次初始化窗口、Rust 桥接与曲库连接，任一步失败都展示能看懂的界面而不是白屏。
/// 业务逻辑与页面请放到 `lib/src/` 对应目录（见 docs/ARCHITECTURE.md）。
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
    runApp(LampStartupErrorApp(message: '$error'));
    return;
  }

  try {
    await initLibrary();
  } catch (error) {
    // 支持目录不可写、数据库损坏等
    debugPrint('曲库初始化失败：$error');
    runApp(LampStartupErrorApp(title: '启动失败：曲库未能打开', message: '$error'));
    return;
  }

  // 先恢复主题再挂载，避免深色用户启动时先闪一下浅色；
  // 恢复失败由 controller 内部兜底为「跟随系统」。
  final ThemeController theme = ThemeController();
  await theme.restore();

  _WindowGeometrySaver(windowStore).attach();

  runApp(LampApp(themeController: theme));
}

/// 关掉系统标题栏，改用应用内自绘的（见 `lib/src/app/title_bar.dart`）。
///
/// `TitleBarStyle.hidden` 只去掉标题栏，窗口边框、缩放、贴边/分屏手势仍由系统提供。
/// 失败时保持原生标题栏，界面里会同时出现两个标题栏，但至少能正常操作。
Future<void> _setupWindow(WindowSnapshot state) async {
  final Offset? position = await _restorePosition(state);
  try {
    await windowManager.ensureInitialized();
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

/// 尺寸变化后防抖落盘；最大化时只记住「最大化」标记，尺寸沿用上一次普通状态。
class _WindowGeometrySaver with WindowListener {
  _WindowGeometrySaver(this._store);

  final WindowStateStore _store;
  Timer? _timer;

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

  void _scheduleSave() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
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

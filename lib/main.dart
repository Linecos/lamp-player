import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/features/library/library_db.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';
import 'package:window_manager/window_manager.dart';

/// 应用入口。
///
/// 依次初始化窗口、Rust 桥接与曲库连接，任一步失败都展示能看懂的界面而不是白屏。
/// 业务逻辑与页面请放到 `lib/src/` 对应目录（见 docs/ARCHITECTURE.md）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _setupWindow();

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

  runApp(LampApp(themeController: theme));
}

/// 关掉系统标题栏，改用应用内自绘的（见 `lib/src/app/title_bar.dart`）。
///
/// `TitleBarStyle.hidden` 只去掉标题栏，窗口边框、缩放、贴边/分屏手势仍由系统提供。
/// 失败时保持原生标题栏，界面里会同时出现两个标题栏，但至少能正常操作。
Future<void> _setupWindow() async {
  try {
    await windowManager.ensureInitialized();
    const WindowOptions options = WindowOptions(
      title: 'Lamp Player',
      size: Size(1180, 760),
      minimumSize: Size(900, 560),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
    );
    // 等首帧就绪后再 show，避免先闪一下系统标题栏
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
      }),
    );
  } catch (error) {
    debugPrint('窗口初始化失败（保留系统标题栏）：$error');
  }
}

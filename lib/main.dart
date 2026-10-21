import 'package:flutter/material.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/features/library/library_db.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';

/// 应用入口。
///
/// 依次初始化 Rust 桥接与曲库连接，任一步失败都展示能看懂的界面而不是白屏。
/// 业务逻辑与页面请放到 `lib/src/` 对应目录（见 docs/ARCHITECTURE.md）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  runApp(const LampApp());
}

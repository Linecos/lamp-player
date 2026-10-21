import 'package:flutter/material.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';

/// 应用入口。
///
/// 只做两件事：初始化 Rust 桥接、挂载应用外壳。
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

  runApp(const LampApp());
}

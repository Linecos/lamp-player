import 'package:flutter/material.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';

/// 应用入口。
///
/// 只做两件事：初始化 Rust 桥接、挂载应用外壳。
/// 业务逻辑与页面请放到 `lib/src/` 对应目录（见 docs/ARCHITECTURE.md）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const LampApp());
}

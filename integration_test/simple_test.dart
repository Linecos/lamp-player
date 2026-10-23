// 桌面端集成测试：会加载真实原生库，验证 Flutter ↔ Rust 桥接可用。
// 跑法：flutter test integration_test -d windows

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/features/library/library_db.dart';
import 'package:lamp_player/src/rust/api/db.dart' as db;
import 'package:lamp_player/src/rust/api/simple.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory libraryDir;

  setUpAll(() async {
    await RustLib.init();
    // 用临时目录建库：测试绝不能打开用户 %APPDATA% 里的真实曲库
    libraryDir = await Directory.systemTemp.createTemp('lamp_it_');
    await initLibrary(supportDirectory: libraryDir);
  });

  tearDownAll(() async {
    try {
      await db.closeDb();
    } catch (_) {
      // 已关闭或从未打开，忽略
    }
    try {
      libraryDir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上文件句柄没释放干净时会失败，不影响测试结论
    }
  });

  testWidgets('Rust 桥接自检：greet 调用正常', (WidgetTester tester) async {
    expect(greet(name: 'Tom'), 'Hello, Tom!');
  });

  testWidgets('应用外壳可以挂载真实原生库', (WidgetTester tester) async {
    await tester.pumpWidget(const LampApp());
    await tester.pumpAndSettle();

    expect(find.text('Lamp Player'), findsOneWidget);
    expect(find.text('音乐'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
  });
}

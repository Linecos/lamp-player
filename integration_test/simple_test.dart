// 桌面端集成测试：会加载真实原生库，验证 Flutter ↔ Rust 桥接可用。
// 跑法：flutter test integration_test -d windows

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/features/library/library_db.dart';
import 'package:lamp_player/src/rust/api/simple.dart';
import 'package:lamp_player/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // 和真实启动路径一致：先打开曲库，再挂载界面
    await initLibrary();
  });

  testWidgets('Rust 桥接自检：greet 调用正常', (WidgetTester tester) async {
    expect(greet(name: 'Tom'), 'Hello, Tom!');
  });

  testWidgets('应用外壳可以挂载真实原生库', (WidgetTester tester) async {
    await tester.pumpWidget(const LampApp());
    await tester.pumpAndSettle();

    expect(find.text('Lamp'), findsOneWidget);
    expect(find.text('音乐'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
  });
}

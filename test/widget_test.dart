// 纯 Dart 环境的冒烟测试：不初始化 Rust 也能跑，CI 的 `flutter test` 用它。
//
// 约定：页面只要依赖 Rust 接口（真正的曲库/播放逻辑），一律放到
// `integration_test/`，用真实原生库跑；`test/` 下只放不依赖 FFI 的逻辑与
// widget 测试，保证贡献者在没有 Rust 工具链的机器上也能验证改动。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app.dart';

void main() {
  testWidgets('应用外壳可渲染：主题、首页占位都在', (WidgetTester tester) async {
    await tester.pumpWidget(const LampApp());

    // 标题栏
    expect(find.text('Lamp Player'), findsOneWidget);
    // 首页占位内容
    expect(find.text('曲库尚未接入'), findsOneWidget);
    expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
  });
}

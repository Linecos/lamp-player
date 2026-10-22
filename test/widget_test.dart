// 纯 Dart 环境的冒烟测试：不初始化 Rust 也能跑，CI 的 `flutter test` 用它。
//
// 约定：页面只要依赖 Rust 接口（真正的曲库/播放逻辑），一律放到
// `integration_test/`，用真实原生库跑；`test/` 下只放不依赖 FFI 的逻辑与
// widget 测试，保证贡献者在没有 Rust 工具链的机器上也能验证改动。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import 'support/fake_library.dart';

void main() {
  testWidgets('应用外壳可渲染：导航、搜索、播放条都在', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      LampApp(
        libraryRepository: FakeLibraryRepository(
          tracks: <Track>[sampleTrack(title: '夜航', album: '夜之专辑')],
        ),
        playbackService: FakePlaybackService(),
      ),
    );
    await tester.pumpAndSettle();

    // 标题栏与搜索
    expect(find.text('Lamp'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    // 侧边导航与曲库页标题
    expect(find.text('音乐'), findsWidgets);
    expect(find.text('夜航'), findsOneWidget);
    // 播放条占位
    expect(find.text('尚未播放'), findsOneWidget);
  });
}

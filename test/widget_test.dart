// TODO(M1): 曲库 UI 落地后替换为真实测试（页面渲染、搜索交互等）。
//
// 现状说明：当前 main.dart 是 flutter_rust_bridge 快速开始示例，
// 其入口需要先初始化 Rust 库（RustLib.init），纯 Dart 单测环境无法
// 加载原生库，因此暂不对其做 widget 测试；真实场景由
// integration_test/simple_test.dart 在设备/桌面端覆盖。

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('占位冒烟测试：本地 flutter test 环境可用', () {
    expect(true, isTrue);
  });
}

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/window_occlusion.dart';

void main() {
  const Rect window = Rect.fromLTWH(0, 0, 1600, 1000);

  test('上面前压一个小窗口不算被盖住——全屏当背景就是这么用的', () {
    const Rect small = Rect.fromLTWH(100, 100, 400, 300);
    expect(isRectCovered(window, <Rect>[small]), isFalse);
  });

  test('一块同尺寸的矩形盖死', () {
    const Rect full = Rect.fromLTWH(-8, -8, 1616, 1016);
    expect(isRectCovered(window, <Rect>[full]), isTrue);
  });

  test('两块拼起来也能盖死（左右各一半）', () {
    const Rect left = Rect.fromLTWH(0, 0, 800, 1000);
    const Rect right = Rect.fromLTWH(800, 0, 800, 1000);
    expect(isRectCovered(window, <Rect>[left, right]), isTrue);
  });

  test('留一条缝就不算盖住（网格采样：窄于 1/5 宽度的缝会漏，够用就行）', () {
    // 右边只盖到 1300，剩下 300px 露着
    const Rect left = Rect.fromLTWH(0, 0, 800, 1000);
    const Rect right = Rect.fromLTWH(800, 0, 500, 1000);
    expect(isRectCovered(window, <Rect>[left, right]), isFalse);
  });

  test('没有任何遮挡物：false', () {
    expect(isRectCovered(window, const <Rect>[]), isFalse);
  });

  test('空窗口不当成盖住（避免 0 尺寸时除零 / 误判）', () {
    expect(
      isRectCovered(Rect.zero, const <Rect>[Rect.fromLTWH(0, 0, 1, 1)]),
      isFalse,
    );
  });
}

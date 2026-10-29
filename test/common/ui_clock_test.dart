import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/ui_clock.dart';

/// UiClock 的节拍约定：三档共用一个定时器，周期按「有没有 60fps 监听」切换。
///
/// 这几条断言锁的是性能回归的两个关键点：
/// 1. 没人监听时定时器必须停（否则空转，等于又回到「按刷新率空出帧」的老问题）；
/// 2. 三档在同一拍里通知完，不许各自起一个 `Timer.periodic`（相位错开会
///    实际要出 2~3 倍于 30fps 的帧）。
void main() {
  test('30/15 共用 33ms 定时器，加 60fps 档后压到 16ms，摘完即停', () {
    fakeAsync((FakeAsync async) {
      int normal = 0;
      int slow = 0;
      int fast = 0;
      void onNormal() => normal += 1;
      void onSlow() => slow += 1;
      void onFast() => fast += 1;

      UiClock.instance.addListener(onNormal);
      UiClock.slow.addListener(onSlow);

      // 33ms 一拍：99ms = 3 拍 → 30fps 3 次，15fps 每 2 拍一次
      async.elapse(const Duration(milliseconds: 99));
      expect(normal, 3);
      expect(slow, 1);

      // 有 60fps 监听后周期换成 16ms：96ms = 6 拍
      // 60fps 每拍 6 次、30fps 每 2 拍 3 次、15fps 每 4 拍 1 次
      UiClock.fast.addListener(onFast);
      normal = 0;
      slow = 0;
      async.elapse(const Duration(milliseconds: 96));
      expect(fast, 6);
      expect(normal, 3);
      expect(slow, 1);

      // 全部摘掉 → 定时器停，再怎么推进也不该有通知
      UiClock.fast.removeListener(onFast);
      UiClock.instance.removeListener(onNormal);
      UiClock.slow.removeListener(onSlow);
      normal = 0;
      slow = 0;
      fast = 0;
      async.elapse(const Duration(milliseconds: 200));
      expect(normal, 0);
      expect(slow, 0);
      expect(fast, 0);
    });
  });
}

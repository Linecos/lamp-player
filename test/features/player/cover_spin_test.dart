import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/player/cover_spin.dart';

/// 从旋转矩阵还原角度（0~1 圈）
double _turnsOf(Transform transform) {
  final List<double> m = transform.transform.storage;
  return math.atan2(m[1], m[0]) / (2 * math.pi);
}

void main() {
  setUp(CoverSpin.reset);
  tearDown(CoverSpin.reset);

  testWidgets('两个来源都撤掉才停：播放页退出后播放条继续转', (WidgetTester tester) async {
    final Object page = Object();
    final Object bar = Object();
    CoverSpin.sync(page, playing: true, circular: true);
    CoverSpin.sync(bar, playing: true, circular: true);

    await tester.pump(const Duration(seconds: 5));
    final double before = CoverSpin.turns.value;
    expect(before, closeTo(5 / 25, 0.01));

    // 播放页销毁（退出播放页）：不能把它那份"停"强加给还在播的播放条
    CoverSpin.release(page);
    await tester.pump(const Duration(seconds: 5));
    expect(
      CoverSpin.turns.value,
      greaterThan(before),
      reason: '播放页退出时封面应该接着转，而不是回正/停住',
    );

    CoverSpin.release(bar);
    final double stopped = CoverSpin.turns.value;
    await tester.pump(const Duration(seconds: 5));
    expect(CoverSpin.turns.value, stopped, reason: '没有来源要求转就停住');
  });

  testWidgets('暂停停住，再播接着原来的角度转', (WidgetTester tester) async {
    final Object owner = Object();
    CoverSpin.sync(owner, playing: true, circular: true);
    await tester.pump(const Duration(seconds: 4));

    CoverSpin.sync(owner, playing: false, circular: true);
    final double frozen = CoverSpin.turns.value;
    await tester.pump(const Duration(seconds: 3));
    expect(CoverSpin.turns.value, frozen);

    CoverSpin.sync(owner, playing: true, circular: true);
    await tester.pump(const Duration(seconds: 2));
    expect(CoverSpin.turns.value, closeTo(6 / 25, 0.01), reason: '接着冻住的角度往下转');

    // 用例结束前停掉时钟，否则会留下一个 16ms 的周期定时器
    CoverSpin.release(owner);
  });

  testWidgets('飞行 shuttle 跟着相位转，不是回到正面', (WidgetTester tester) async {
    final ValueNotifier<double> turns = ValueNotifier<double>(0.25);
    addTearDown(turns.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: coverFlightShuttle(
              size: 200,
              cover: const SizedBox.square(dimension: 200),
              turns: turns,
            ),
          ),
        ),
      ),
    );

    Transform shuttle() => tester.widget<Transform>(
      find.byKey(const ValueKey<String>('cover-shuttle-spin')),
    );

    expect(_turnsOf(shuttle()), closeTo(0.25, 0.01));

    // 相位继续走，shuttle 跟着转——退场动画里封面才不会"先回正"
    turns.value = 0.4;
    await tester.pump();
    expect(_turnsOf(shuttle()), closeTo(0.4, 0.01));
  });

  testWidgets('方形封面不传相位时，shuttle 里没有旋转层', (WidgetTester tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: coverFlightShuttle(
              size: 120,
              cover: const SizedBox.square(dimension: 120),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('cover-shuttle-spin')),
      findsNothing,
    );
  });
}

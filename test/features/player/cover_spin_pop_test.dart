import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/features/player/cover_spin.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

/// 从旋转矩阵还原角度（0~1 圈）
double _turnsOf(Transform transform) {
  final List<double> m = transform.transform.storage;
  return math.atan2(m[1], m[0]) / (2 * math.pi);
}

void main() {
  testWidgets('退出播放页时封面接着转，不回到正面', (WidgetTester tester) async {
    CoverSpin.reset();
    addTearDown(CoverSpin.reset);

    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(
          coverBackfillAttempted: true,
          circularCovers: true,
        ),
      ),
    );

    // 播一首，再点播放条上的曲名进正在播放页
    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
    );
    await tester.pumpAndSettle();

    // 转 5 秒，记下角度
    await tester.pump(const Duration(seconds: 5));
    final double before = CoverSpin.turns.value;
    expect(before, greaterThan(0.15), reason: '页面上已经转起来了');

    // 退出：飞行中和落地后都必须沿用当前角度
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final Finder shuttle = find.byKey(
      const ValueKey<String>('cover-shuttle-spin'),
    );
    expect(shuttle, findsOneWidget, reason: '圆形封面的飞行 shuttle 要带旋转层');
    expect(
      _turnsOf(tester.widget<Transform>(shuttle)),
      closeTo(CoverSpin.turns.value, 0.02),
      reason: 'shuttle 用的是当前相位；回 0 就是「先回到最开始的样子再退出」',
    );

    await tester.pumpAndSettle();

    final Finder barSpin = find.byKey(const ValueKey<String>('spinning-cover'));
    expect(barSpin, findsOneWidget, reason: '播放条小封面也跟同一相位');
    expect(
      _turnsOf(tester.widget<Transform>(barSpin)),
      closeTo(CoverSpin.turns.value, 0.02),
      reason: '落地时不能突然跳回正面',
    );

    // 拆树让 SpinningCover.dispose 撤掉它那一票，否则会留下 16ms 定时器
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

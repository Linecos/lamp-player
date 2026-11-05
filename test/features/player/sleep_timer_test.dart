import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/sleep_timer.dart';

/// 定时器靠 Flutter 的测试时钟推进，这里只需要一个宿主 widget
Future<void> _host(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
}

void main() {
  testWidgets('到点暂停一次，然后自动复位', (WidgetTester tester) async {
    await _host(tester);
    int pauses = 0;
    final List<String> messages = <String>[];
    final SleepTimer timer = SleepTimer(
      isPlaying: () => true,
      position: () => 10,
      duration: () => 200,
      pause: () async => pauses += 1,
      onFired: messages.add,
    )..extendToTrackEnd = false;
    addTearDown(timer.dispose);

    timer.arm(const Duration(minutes: 1));
    expect(timer.active, isTrue);
    expect(timer.remainingMinutes, 1);

    await tester.pump(const Duration(minutes: 1, seconds: 1));

    expect(pauses, 1);
    expect(timer.active, isFalse);
    expect(timer.remainingMinutes, isNull);
    expect(messages, <String>['睡眠定时已到，已暂停播放']);
  });

  testWidgets('曲目没播完时顺延到播完，且只顺延一次', (WidgetTester tester) async {
    await _host(tester);
    int pauses = 0;
    final SleepTimer timer = SleepTimer(
      isPlaying: () => true,
      position: () => 10,
      duration: () => 200,
      pause: () async => pauses += 1,
    );
    addTearDown(timer.dispose);

    timer.arm(const Duration(minutes: 1));
    // 到点时还剩 190 秒：不掐断当前曲目
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    expect(pauses, 0);
    expect(timer.active, isTrue);
    expect(timer.tooltip, contains('播完当前曲目'));

    // 顺延到曲目结束后真的暂停
    await tester.pump(const Duration(seconds: 191));
    expect(pauses, 1);
    expect(timer.active, isFalse);
  });

  testWidgets('0 分钟等于取消，之前挂的定时不会再来一次', (WidgetTester tester) async {
    await _host(tester);
    int pauses = 0;
    final SleepTimer timer = SleepTimer(
      isPlaying: () => true,
      position: () => 10,
      duration: () => 200,
      pause: () async => pauses += 1,
    )..extendToTrackEnd = false;
    addTearDown(timer.dispose);

    timer.arm(const Duration(minutes: 1));
    timer.arm(Duration.zero);
    expect(timer.active, isFalse);

    await tester.pump(const Duration(minutes: 2));
    expect(pauses, 0, reason: '取消后旧定时器不能残留');
  });

  testWidgets('暂停着的时候到点不调 pause，只清状态', (WidgetTester tester) async {
    await _host(tester);
    int pauses = 0;
    final SleepTimer timer = SleepTimer(
      isPlaying: () => false,
      position: () => 10,
      duration: () => 200,
      pause: () async => pauses += 1,
    )..extendToTrackEnd = false;
    addTearDown(timer.dispose);

    timer.arm(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1, seconds: 1));

    expect(pauses, 0);
    expect(timer.active, isFalse);
  });
}

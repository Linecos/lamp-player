import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/sleep_timer_dialog.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 当前用例的浮窗返回值
SleepTimerResult? _result;

String _value(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey<String>('sleep-dial-value')))
    .data!;

bool _switchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('sleep-extend-switch')),
    )
    .value;

Future<void> _pumpHost(
  WidgetTester tester, {
  int initialMinutes = 30,
  bool hasTimer = false,
  bool extendToTrackEnd = true,
}) async {
  _result = null;
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(AppTheme.defaultSeed),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                _result = await showSleepTimerDialog(
                  context,
                  initialMinutes: initialMinutes,
                  hasTimer: hasTimer,
                  extendToTrackEnd: extendToTrackEnd,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认 30 分钟，顺延开关默认开', (WidgetTester tester) async {
    await _pumpHost(tester);

    expect(_value(tester), '30');
    expect(find.text('分钟'), findsOneWidget);
    expect(_switchValue(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();

    expect(_result?.minutes, 30);
    expect(_result?.extendToTrackEnd, isTrue);
  });

  testWidgets('关掉顺延开关后带回 false', (WidgetTester tester) async {
    await _pumpHost(tester);

    await tester.tap(find.byKey(const ValueKey<String>('sleep-extend-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();

    expect(_result?.minutes, 30);
    expect(_result?.extendToTrackEnd, isFalse);
  });

  testWidgets('传入的开关状态作为初始值', (WidgetTester tester) async {
    await _pumpHost(tester, extendToTrackEnd: false);

    expect(_switchValue(tester), isFalse);
  });

  testWidgets('点快选芯片改读数，确认带回对应分钟数', (WidgetTester tester) async {
    await _pumpHost(tester);

    await tester.tap(find.byKey(const ValueKey<String>('sleep-preset-15')));
    await tester.pumpAndSettle();
    expect(_value(tester), '15');

    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();
    expect(_result?.minutes, 15);
  });

  testWidgets('轮盘：点 3 点方向得到 15 分钟', (WidgetTester tester) async {
    await _pumpHost(tester);

    final Offset center = tester
        .getRect(find.byKey(const ValueKey<String>('sleep-dial')))
        .center;
    await tester.tapAt(center + const Offset(96, 0));
    await tester.pumpAndSettle();

    expect(_value(tester), '15', reason: '3 点方向 = 顺时针 90° = 15 分钟');
  });

  testWidgets('轮盘：点 6 点方向得到 30 分钟', (WidgetTester tester) async {
    await _pumpHost(tester, initialMinutes: 5);

    final Offset center = tester
        .getRect(find.byKey(const ValueKey<String>('sleep-dial')))
        .center;
    await tester.tapAt(center + const Offset(0, 96));
    await tester.pumpAndSettle();

    expect(_value(tester), '30', reason: '6 点方向 = 顺时针 180° = 30 分钟');
  });

  testWidgets('0 分钟时按钮变成关闭定时，带回 0', (WidgetTester tester) async {
    await _pumpHost(tester, initialMinutes: 0);

    expect(_value(tester), '0');
    expect(find.text('不定时'), findsOneWidget);
    expect(find.text('关闭定时'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();
    expect(_result?.minutes, 0);
  });

  testWidgets('取消不改动（返回 null）', (WidgetTester tester) async {
    await _pumpHost(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(_result, isNull);
  });

  testWidgets('已在倒计时时提供「关闭定时」，返回 0', (WidgetTester tester) async {
    await _pumpHost(tester, initialMinutes: 20, hasTimer: true);

    await tester.tap(find.byKey(const ValueKey<String>('sleep-clear')));
    await tester.pumpAndSettle();

    expect(_result?.minutes, 0);
  });

  testWidgets('没有定时时不显示「关闭定时」', (WidgetTester tester) async {
    await _pumpHost(tester);

    expect(find.byKey(const ValueKey<String>('sleep-clear')), findsNothing);
  });

  testWidgets('副标题在已定时时显示剩余分钟', (WidgetTester tester) async {
    await _pumpHost(tester, initialMinutes: 20, hasTimer: true);

    expect(find.textContaining('当前还剩 20 分钟'), findsOneWidget);
  });
}

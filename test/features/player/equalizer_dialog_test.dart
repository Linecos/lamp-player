import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/equalizer_dialog.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 打开弹窗
Future<void> _open(
  WidgetTester tester, {
  bool enabled = true,
  List<double>? gains,
  void Function(bool, List<double>, String?)? onChanged,
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showEqualizerDialog(
                context,
                enabled: enabled,
                gains: gains ?? List<double>.filled(10, 0),
                onChanged: onChanged,
              ),
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
  testWidgets('均衡器从整页改成弹窗，十个推子都在弹窗里', (WidgetTester tester) async {
    await _open(tester);

    expect(
      find.byKey(const ValueKey<String>('equalizer-dialog')),
      findsOneWidget,
    );
    expect(find.text('均衡器'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('eq-band-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('eq-band-9')), findsOneWidget);
    // 弹窗里不该再有整页的 AppBar
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('弹窗里开关仍会回调', (WidgetTester tester) async {
    final List<bool> calls = <bool>[];
    await _open(
      tester,
      enabled: false,
      onChanged: (bool enabled, List<double> _, String? _) =>
          calls.add(enabled),
    );

    await tester.tap(find.byKey(const ValueKey<String>('equalizer-enable')));
    await tester.pumpAndSettle();

    expect(calls, <bool>[true]);
  });

  testWidgets('右上角叉号能关掉弹窗', (WidgetTester tester) async {
    await _open(tester);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('equalizer-dialog')),
      findsNothing,
    );
  });

  testWidgets('窗口只有最小高度时弹窗不溢出', (WidgetTester tester) async {
    await _open(tester, size: const Size(900, 560));

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('equalizer-dialog')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('eq-band-0')), findsOneWidget);
  });
}

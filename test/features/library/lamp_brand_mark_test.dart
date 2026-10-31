import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/lamp_brand_mark.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

void main() {
  testWidgets('浅色模式：透明底矢量灯泡，不再用带深色底的位图', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: const Scaffold(body: Center(child: LampBrandMark(size: 28))),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(LampBrandMark),
        matching: find.byType(Image),
      ),
      findsNothing,
      reason: '浅色下不能再用深色底位图',
    );
    expect(
      find.descendant(
        of: find.byType(LampBrandMark),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
  });

  testWidgets('深色模式：同样是矢量灯泡，底板纯黑', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppTheme.defaultSeed),
        home: const Scaffold(body: Center(child: LampBrandMark(size: 28))),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(LampBrandMark),
        matching: find.byType(Image),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(LampBrandMark),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
  });
}

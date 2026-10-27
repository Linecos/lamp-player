import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/widgets/cover_flow_background.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

void main() {
  testWidgets('有动画时能持续渲染并正常销毁', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: const CoverFlowBackground(
          colors: <Color>[Color(0xFF3355AA), Color(0xFFAA5533)],
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test('黄黑封面优先选黄色，而不是黑色混合出的橄榄绿', () {
    final List<Color> colors = harmonizeCoverColors(<Color>[
      const Color(0xFFFFD400),
      const Color(0xFF141414),
    ]);
    final Iterable<HSLColor> hsls = colors.map(HSLColor.fromColor);
    expect(
      hsls.any((HSLColor color) => color.hue >= 40 && color.hue <= 60),
      isTrue,
      reason: '色板里必须保留黄色主色',
    );
    expect(
      hsls.any((HSLColor color) => color.saturation > 0.6),
      isTrue,
      reason: '主色应保持高饱和',
    );
  });

  test('深色封面会按感知亮度自动提亮', () {
    final List<Color> colors = harmonizeCoverColors(<Color>[
      const Color(0xFF1E3A8A),
      const Color(0xFFFF8A3D),
    ]);

    for (final Color color in colors) {
      expect(
        color.computeLuminance(),
        greaterThanOrEqualTo(0.13),
        reason: '深蓝封面不能生成过暗的背景',
      );
    }
  });

  test('蓝封面 + 暖色会生成左右对比色相，而不是单色一片', () {
    final List<Color> colors = harmonizeCoverColors(<Color>[
      const Color(0xFF1E3A8A),
      const Color(0xFFFF8A3D),
    ]);
    final List<double> hues = colors
        .map((Color color) => HSLColor.fromColor(color).hue)
        .toList();

    bool distinct = false;
    for (int i = 0; i < hues.length; i += 1) {
      for (int j = i + 1; j < hues.length; j += 1) {
        final double diff = (hues[i] - hues[j]).abs();
        if ((diff > 180 ? 360 - diff : diff) > 50) {
          distinct = true;
        }
      }
    }
    expect(distinct, isTrue);
  });

  testWidgets('没有封面色时用主题色兜底', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppTheme.defaultSeed),
        home: const CoverFlowBackground(
          colors: null,
          animate: false,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CoverFlowBackground), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

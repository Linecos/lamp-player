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

  test('面积最大的颜色做主色，同时保留小面积对比色', () {
    final List<Color> colors = harmonizeCoverColors(<Color>[
      const Color(0xFFF2C230), // 大面积黄
      const Color(0xFF3F9B45), // 小面积绿
    ]);
    final List<HSLColor> hsls = colors.map(HSLColor.fromColor).toList();

    expect(hsls.first.hue, inInclusiveRange(40, 60), reason: '黄色应做主色');
    expect(
      hsls.any((HSLColor color) => color.hue >= 90 && color.hue <= 160),
      isTrue,
      reason: '绿色不能被大面积黄色挤掉',
    );
  });

  test('蓝衣、绿草、蓝天封面保留三种色相', () {
    final List<Color> colors = harmonizeCoverColors(<Color>[
      const Color(0xFF3A66C8), // 蓝衣 / 蓝天
      const Color(0xFF4E9B48), // 草地
      const Color(0xFFE8C34A), // 暖色高光
    ]);
    final List<double> hues = colors
        .map((Color color) => HSLColor.fromColor(color).hue)
        .toList();

    expect(hues.any((double h) => h >= 190 && h <= 260), isTrue);
    expect(hues.any((double h) => h >= 80 && h <= 160), isTrue);
    expect(hues.any((double h) => h >= 35 && h <= 70), isTrue);
  });

  testWidgets('动画帧复用预渲染光斑，不会每帧重建位图', (WidgetTester tester) async {
    final int before = coverFlowSpotRenderCount;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppTheme.defaultSeed),
        home: const CoverFlowBackground(
          colors: <Color>[Color(0xFF3355AA), Color(0xFFAA5533)],
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    // 4 个色板色 × 7 档色相
    final int built = coverFlowSpotRenderCount - before;
    expect(built, 28);

    // 跑满一个循环（12 秒）：位图不该被重新渲染
    await tester.pump(const Duration(seconds: 12));
    expect(coverFlowSpotRenderCount - before, built);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换封面配色会重建光斑位图', (WidgetTester tester) async {
    final int before = coverFlowSpotRenderCount;

    Widget host(List<Color> colors) => MaterialApp(
      theme: AppTheme.dark(AppTheme.defaultSeed),
      home: CoverFlowBackground(
        colors: colors,
        animate: false,
        child: const SizedBox.expand(),
      ),
    );

    await tester.pumpWidget(host(const <Color>[Color(0xFF3355AA)]));
    await tester.pumpWidget(host(const <Color>[Color(0xFF33AA55)]));

    expect(coverFlowSpotRenderCount - before, 56);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换色板时旧光斑留到过渡结束，连切也不会误释放', (WidgetTester tester) async {
    Widget host(List<Color> colors) => MaterialApp(
      theme: AppTheme.dark(AppTheme.defaultSeed),
      home: CoverFlowBackground(
        colors: colors,
        animate: false,
        child: const SizedBox.expand(),
      ),
    );

    await tester.pumpWidget(host(const <Color>[Color(0xFF3355AA)]));
    await tester.pump();

    await tester.pumpWidget(host(const <Color>[Color(0xFF33AA55)]));
    await tester.pump(const Duration(milliseconds: 120));

    // 淡出还没走完又换一次：上一组仍在被绘制，不能提前 dispose，
    // 否则下一帧会拿一张已释放的位图去贴（真机上直接崩）
    await tester.pumpWidget(host(const <Color>[Color(0xFFAA3355)]));
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);

    // 过渡收尾：旧组释放、只剩一组
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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

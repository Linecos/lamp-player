import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/theme_reveal.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 搭一个最小外壳：MaterialApp + 圆形揭示，主题由控制器驱动
Future<void> pumpShell(WidgetTester tester, ThemeController controller) async {
  await tester.pumpWidget(
    ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) => MaterialApp(
        theme: AppTheme.light(controller.effectiveSeed),
        darkTheme: AppTheme.dark(controller.effectiveSeed),
        themeMode: controller.mode,
        // 与生产一致：主题一帧切完，扩散交给 ThemeReveal。
        // 开着 MaterialApp 自带的过渡时明暗是半程才翻的，测不到真实时序。
        themeAnimationStyle: AnimationStyle.noAnimation,
        builder: (BuildContext context, Widget? child) =>
            ThemeReveal(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Center(child: Text('内容'))),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ThemeRevealPainter painterOf(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(ThemeReveal.overlayKey)).painter!
        as ThemeRevealPainter;

void main() {
  testWidgets('切深浅色时从圆里露出新主题，铺满后移除', (WidgetTester tester) async {
    final ThemeController controller = ThemeController(
      initialMode: ThemeMode.light,
    );
    addTearDown(controller.dispose);
    await pumpShell(tester, controller);

    expect(
      find.byKey(ThemeReveal.overlayKey),
      findsNothing,
      reason: '首帧没有旧画面可画',
    );

    unawaited(controller.setMode(ThemeMode.dark));
    await tester.pump();

    expect(find.byKey(ThemeReveal.overlayKey), findsOneWidget);
    expect(painterOf(tester).progress.value, 0.0, reason: '从圆心为起点开始铺');
    // 新主题在同一帧就生效了：盖着的只是视觉上的圆，不是延迟切换
    expect(
      Theme.of(tester.element(find.text('内容'))).brightness,
      Brightness.dark,
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(ThemeReveal.overlayKey), findsOneWidget);
    final double mid = painterOf(tester).progress.value;
    expect(mid, greaterThan(0.0));
    expect(mid, lessThan(1.0), reason: '半程应该扩到一半左右');

    await tester.pumpAndSettle();
    expect(find.byKey(ThemeReveal.overlayKey), findsNothing, reason: '铺满后要移除');
  });

  testWidgets('扩散圆心取自最后一次点击的位置', (WidgetTester tester) async {
    final ThemeController controller = ThemeController(
      initialMode: ThemeMode.light,
    );
    addTearDown(controller.dispose);
    await pumpShell(tester, controller);

    await tester.tapAt(const Offset(120, 300));
    await tester.pump();

    unawaited(controller.setMode(ThemeMode.dark));
    await tester.pump();

    expect(painterOf(tester).origin, const Offset(120, 300));
  });

  testWidgets('没点过（例如系统切换）时以窗口中心为圆心', (WidgetTester tester) async {
    final ThemeController controller = ThemeController(
      initialMode: ThemeMode.light,
    );
    addTearDown(controller.dispose);
    await pumpShell(tester, controller);

    unawaited(controller.setMode(ThemeMode.dark));
    await tester.pump();

    expect(painterOf(tester).origin, isNull, reason: '由绘制器取窗口中心兜底');
  });

  testWidgets('只换强调色（明暗不变）不触发扩散', (WidgetTester tester) async {
    final ThemeController controller = ThemeController(
      initialMode: ThemeMode.light,
    );
    addTearDown(controller.dispose);
    await pumpShell(tester, controller);

    unawaited(controller.setSeedColor(const Color(0xFF2196F3)));
    await tester.pump();

    expect(
      find.byKey(ThemeReveal.overlayKey),
      findsNothing,
      reason: '强调色变化按原样瞬时切换；「跟随封面」每换一首歌都会走这条路',
    );
  });

  testWidgets('扩散途中再切一次不会崩，且仍会正常收起', (WidgetTester tester) async {
    final ThemeController controller = ThemeController(
      initialMode: ThemeMode.light,
    );
    addTearDown(controller.dispose);
    await pumpShell(tester, controller);

    unawaited(controller.setMode(ThemeMode.dark));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    unawaited(controller.setMode(ThemeMode.light));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);
    expect(find.byKey(ThemeReveal.overlayKey), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(ThemeReveal.overlayKey), findsNothing);
  });
}

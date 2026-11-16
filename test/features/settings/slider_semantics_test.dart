import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/slider_semantics_scope.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/page_harness.dart';

/// 每个 `Slider` 都必须套 `SliderSemanticsScope`（§6-48）：
/// 少了这层语义边界，Windows 上的无障碍树会冻结，之后任意路由 pop 崩在
/// `accessibility_bridge.cc`，表现为窗口「卡死」。
void _expectAllSlidersScoped(WidgetTester tester, String where) {
  final Iterable<Element> sliders = find.byType(Slider).evaluate();
  expect(sliders, isNotEmpty, reason: '$where 里应该有滑块，用例本身要复核');
  for (final Element slider in sliders) {
    bool scoped = false;
    slider.visitAncestorElements((Element ancestor) {
      if (ancestor.widget is SliderSemanticsScope) {
        scoped = true;
        return false;
      }
      return true;
    });
    expect(
      scoped,
      isTrue,
      reason: '$where 里有 Slider 缺 SliderSemanticsScope：Windows 上会冻结无障碍树',
    );
  }
}

void main() {
  testWidgets('设置页与播放岛上的滑块都套了语义边界', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    _expectAllSlidersScoped(tester, '设置页');
  });

  testWidgets('色相滑块套了语义边界', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ThemeController controller = ThemeController();
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: controller,
        builder: (BuildContext context, Widget? child) => ThemeScope(
          controller: controller,
          child: MaterialApp(
            theme: AppTheme.light(controller.effectiveSeed),
            home: child,
          ),
        ),
        child: const Scaffold(body: SettingsView(trackCount: 1)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('强调色'));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    _expectAllSlidersScoped(tester, '强调色弹窗');
  });
}

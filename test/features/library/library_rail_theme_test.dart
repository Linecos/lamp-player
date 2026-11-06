import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 侧栏底色由 `rail-surface` 这个 Container 绘制
const ValueKey<String> _surfaceKey = ValueKey<String>('rail-surface');

void main() {
  testWidgets('切深浅色时侧栏底色与主题同帧一致，不自己再动画一次', (WidgetTester tester) async {
    final ThemeController controller = ThemeController(
      initialMode: ThemeMode.light,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ThemeScope(
        controller: controller,
        child: ListenableBuilder(
          listenable: controller,
          builder: (BuildContext context, Widget? child) => MaterialApp(
            theme: AppTheme.light(controller.effectiveSeed),
            darkTheme: AppTheme.dark(controller.effectiveSeed),
            themeMode: controller.mode,
            home: Scaffold(
              body: Row(
                children: <Widget>[
                  LibraryRail(
                    expanded: true,
                    section: LibrarySection.music,
                    onSelect: (LibrarySection section) {},
                    onToggle: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color railColor() {
      final Container container = tester.widget<Container>(
        find.byKey(_surfaceKey),
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    Color themeSurface() {
      final BuildContext context = tester.element(find.byKey(_surfaceKey));
      return Theme.of(context).colorScheme.surfaceContainer;
    }

    expect(railColor(), themeSurface(), reason: '静止时两侧必须一致');

    // 切到深色，在 200ms 主题过渡的中段抽查
    unawaited(controller.setMode(ThemeMode.dark));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      railColor(),
      themeSurface(),
      reason:
          '中途也必须同帧一致：侧栏若对底色再套一层隐式动画，'
          '就会一直落后于主题（内容区变完了它还在追）',
    );

    await tester.pumpAndSettle();
    expect(railColor(), themeSurface());
  });
}

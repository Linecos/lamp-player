import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_library.dart';

Widget _harness({ThemeController? controller}) {
  final Widget view = Scaffold(
    body: SettingsView(
      trackCount: 2,
      totalDurationSecs: 125,
      engineAvailable: true,
    ),
  );
  return controller == null
      ? MaterialApp(theme: AppTheme.light, home: view)
      : ThemeScope(
          controller: controller,
          child: MaterialApp(theme: AppTheme.light, home: view),
        );
}

void main() {
  const Size canvas = Size(900, 1000);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('没有 ThemeScope 时降级为只读，点击不弹窗', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('跟随系统'), findsOneWidget);

    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('点击主题行可切换到深色并写入存储', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ThemeController controller = ThemeController();
    await tester.pumpWidget(_harness(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('跟随系统'), findsOneWidget);

    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(controller.mode, ThemeMode.dark);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('深色'), findsOneWidget);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.prefsKey), 'dark');
  });

  testWidgets('应用启动时应用已保存的深色主题', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ThemeController.prefsKey: 'dark',
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      LampApp(
        libraryRepository: FakeLibraryRepository(
          tracks: <Track>[sampleTrack(title: '夜航')],
        ),
        playbackService: FakePlaybackService(),
      ),
    );
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.text('Lamp').first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });
}

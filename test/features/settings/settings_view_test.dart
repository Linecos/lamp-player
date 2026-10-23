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

  testWidgets('设置页可触发添加音乐目录', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SettingsView(
            trackCount: 2,
            totalDurationSecs: 125,
            engineAvailable: true,
            onAddFolder: () => calls += 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('添加音乐目录'));
    await tester.tap(find.text('添加音乐目录'));
    expect(calls, 1);
  });

  testWidgets('扫描中禁用添加目录入口并显示进度', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SettingsView(
            trackCount: 2,
            totalDurationSecs: 125,
            engineAvailable: true,
            scanning: true,
            onAddFolder: () => calls += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('正在扫描并入库…'));
    await tester.tap(find.text('添加音乐目录'));
    expect(calls, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
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

    // 生产路径：main() 先恢复，再把 controller 注入 LampApp
    final ThemeController controller = ThemeController();
    await controller.restore();

    await tester.pumpWidget(
      LampApp(
        themeController: controller,
        libraryRepository: FakeLibraryRepository(
          tracks: <Track>[sampleTrack(title: '夜航')],
        ),
        playbackService: FakePlaybackService(),
      ),
    );
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.text('Lamp Player').first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('音乐目录为空时显示空态提示', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: SettingsView(
            trackCount: 0,
            totalDurationSecs: 0,
            engineAvailable: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有添加音乐目录，先在上方添加一个'), findsOneWidget);
  });

  testWidgets('目录行提供重新扫描与移除回调', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<String> rescanned = <String>[];
    final List<String> removed = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SettingsView(
            trackCount: 3,
            totalDurationSecs: 200,
            engineAvailable: true,
            folders: const <String>['D:/Music', 'E:/Songs'],
            onRescanFolder: rescanned.add,
            onRemoveFolder: removed.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('D:/Music'), findsOneWidget);
    expect(find.text('E:/Songs'), findsOneWidget);
    expect(find.byTooltip('重新扫描'), findsNWidgets(2));

    await tester.tap(find.byTooltip('重新扫描').first);
    expect(rescanned, <String>['D:/Music']);

    await tester.tap(find.byTooltip('从列表移除').last);
    expect(removed, <String>['E:/Songs']);
  });

  testWidgets('独占输出行展示状态并回调开关', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<bool> changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SettingsView(
            trackCount: 3,
            totalDurationSecs: 200,
            engineAvailable: true,
            exclusive: false,
            exclusiveActive: false,
            outputInfo: '共享输出（跟随系统混音格式）',
            onExclusiveChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('独占输出（WASAPI）'), findsOneWidget);
    expect(find.text('共享输出（跟随系统混音格式）'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(changes, <bool>[true]);
  });

  testWidgets('切换输出期间独占开关显示进度且不响应', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SettingsView(
            trackCount: 3,
            totalDurationSecs: 200,
            engineAvailable: true,
            exclusive: true,
            switchingOutput: true,
            onExclusiveChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Switch), findsNothing, reason: '切换中显示进度而不是开关');
    expect(find.text('设备不支持或被占用，当前仍走共享输出'), findsOneWidget);
  });
}

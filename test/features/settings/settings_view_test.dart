import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/features/settings/equalizer_page.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_library.dart';

Widget _harness({ThemeController? controller}) {
  final Widget view = Scaffold(
    body: SettingsView(trackCount: 2, engineAvailable: true),
  );
  return controller == null
      ? MaterialApp(theme: AppTheme.light(AppTheme.defaultSeed), home: view)
      : ThemeScope(
          controller: controller,
          child: MaterialApp(
            theme: AppTheme.light(AppTheme.defaultSeed),
            home: view,
          ),
        );
}

void main() {
  const Size canvas = Size(900, 1400);

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
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 2,
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
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 2,
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
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: const Scaffold(
          body: SettingsView(trackCount: 0, engineAvailable: false),
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
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 3,
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
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 3,
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

    await tester.tap(
      find.byKey(const ValueKey<String>('settings-exclusive-switch')),
    );
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
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 3,
            engineAvailable: true,
            exclusive: true,
            switchingOutput: true,
            onExclusiveChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('settings-exclusive-switch')),
      findsNothing,
      reason: '切换中显示进度而不是开关',
    );
    expect(find.text('设备不支持或被占用，当前仍走共享输出'), findsOneWidget);
  });

  testWidgets('流光背景开关默认开启并回调', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<bool> changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 1,
            engineAvailable: true,
            flowBackground: true,
            onFlowBackgroundChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder toggle = find.byKey(
      const ValueKey<String>('settings-flow-background-switch'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(changes, <bool>[false]);
    expect(find.text('动态流光背景'), findsOneWidget);
  });

  testWidgets('关闭到托盘开关展示状态并回调', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<bool> changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 1,
            engineAvailable: true,
            closeToTray: true,
            onCloseToTrayChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关闭窗口时留在托盘'), findsOneWidget);
    expect(find.text('点 × 只隐藏窗口，音乐继续播放；从托盘菜单退出'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('settings-close-to-tray-switch')),
    );
    await tester.pumpAndSettle();
    expect(changes, <bool>[false]);
  });

  testWidgets('未注入 AppLifecycle 时关闭到托盘开关禁用', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: const Scaffold(
          body: SettingsView(trackCount: 1, engineAvailable: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Switch toggle = tester.widget<Switch>(
      find.byKey(const ValueKey<String>('settings-close-to-tray-switch')),
    );
    expect(toggle.onChanged, isNull);
  });

  testWidgets('均衡器入口打开独立页面', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 1,
            engineAvailable: true,
            eqEnabled: true,
            eqGains: List<double>.filled(10, 0),
            eqPresetName: '摇滚',
            onEqualizerChanged: (_, _, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已开启 · 摇滚'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('eq-band-0')),
      findsNothing,
      reason: '设置页不再内嵌推子',
    );

    await tester.tap(find.text('均衡器'));
    await tester.pumpAndSettle();

    expect(find.byType(EqualizerPage), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('eq-band-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('eq-band-9')), findsOneWidget);
  });

  testWidgets('均衡器未启用时副标题给出说明', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 1,
            engineAvailable: true,
            eqEnabled: false,
            onEqualizerChanged: (_, _, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('10 段参数均衡，可存多套预设'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('eq-band-0')), findsNothing);
  });

  testWidgets('配色弹窗可选预设色并写回控制器', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
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
        child: const Scaffold(
          body: SettingsView(trackCount: 1, engineAvailable: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('强调色'));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('配色'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('seed-card-system')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('variant-dropdown')),
      findsOneWidget,
    );

    // 选蓝色（非默认暖黄）；弹窗保持打开供继续预览
    const Color blue = Color(0xFF2196F3);
    await tester.tap(
      find.byKey(ValueKey<String>('seed-card-${blue.toARGB32()}')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(controller.seedColor, blue);
    expect(controller.effectiveSeed, blue);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(ThemeController.seedPrefsKey),
      blue.toARGB32().toString(),
    );
  });

  testWidgets('自定义取色：点色轮改种子色，默认键回暖黄', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
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
        child: const Scaffold(
          body: SettingsView(trackCount: 1, engineAvailable: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('强调色'));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    // 自定义取色是网格里的一个格子，点开才进取色界面
    final Finder customCard = find.byKey(
      const ValueKey<String>('seed-card-custom'),
    );
    expect(customCard, findsOneWidget, reason: '笔形色卡在系统格之后');
    expect(
      find.byKey(const ValueKey<String>('custom-seed-wheel')),
      findsNothing,
      reason: '未点开前不展示色轮',
    );

    await tester.tap(customCard);
    await tester.pumpAndSettle();

    final Finder wheel = find.byKey(
      const ValueKey<String>('custom-seed-wheel'),
    );
    expect(wheel, findsOneWidget, reason: '色轮在独立弹窗里');
    expect(find.text('自定义颜色'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('custom-seed-value')),
      findsOneWidget,
      reason: '明度单独一条滑杆',
    );

    // 点色轮右侧（红/橙区靠外圈）：种子色应立刻离开默认暖黄
    final Offset center = tester.getCenter(wheel);
    await tester.tapAt(center + const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(controller.seedColor, isNotNull);
    expect(controller.seedColor, isNot(AppTheme.defaultSeed));

    // 点「默认」回到暖黄
    await tester.tap(find.byKey(const ValueKey<String>('custom-seed-reset')));
    await tester.pumpAndSettle();

    expect(controller.seedColor, AppTheme.defaultSeed);
  });

  testWidgets('配色可切回跟随系统', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ThemeController controller = ThemeController();
    const Color custom = Color(0xFF4CAF50);
    await controller.setSeedColor(custom);

    await tester.pumpWidget(
      ThemeScope(
        controller: controller,
        child: MaterialApp(
          theme: AppTheme.light(controller.effectiveSeed),
          home: const Scaffold(
            body: SettingsView(trackCount: 1, engineAvailable: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('强调色'));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('seed-card-system')));
    await tester.pumpAndSettle();

    expect(controller.seedColor, isNull);
    expect(controller.effectiveSeed, AppTheme.defaultSeed);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.seedPrefsKey), 'system');
  });

  testWidgets('配色弹窗可切调色板风格与高对比', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ThemeController controller = ThemeController();
    await tester.pumpWidget(
      ThemeScope(
        controller: controller,
        child: MaterialApp(
          theme: AppTheme.light(controller.effectiveSeed),
          home: const Scaffold(
            body: SettingsView(trackCount: 1, engineAvailable: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('强调色'));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    // 下拉切风格：即时生效，不需要关弹窗
    await tester.tap(find.byKey(const ValueKey<String>('variant-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vibrant').last);
    await tester.pumpAndSettle();
    expect(controller.schemeVariant, DynamicSchemeVariant.vibrant);

    // 高对比开关
    await tester.tap(
      find.byKey(const ValueKey<String>('variant-high-contrast-switch')),
    );
    await tester.pumpAndSettle();
    expect(controller.highContrast, isTrue);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeController.variantPrefsKey), 'vibrant');
    expect(prefs.getString(ThemeController.contrastPrefsKey), '1');
  });

  testWidgets('默认配色是跟随系统（动态取色）', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ThemeController controller = ThemeController();
    await tester.pumpWidget(
      ThemeScope(
        controller: controller,
        child: MaterialApp(
          theme: AppTheme.light(controller.effectiveSeed),
          home: const Scaffold(
            body: SettingsView(trackCount: 1, engineAvailable: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('强调色'));
    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    // 首格（跟随系统）应为选中态；控制器默认 seedColor 为 null
    expect(controller.seedColor, isNull);
    expect(controller.effectiveSeed, AppTheme.defaultSeed);
  });

  testWidgets('可点击行都有 hover 高光，卡片自建 Material 托住墨水', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 2,
            engineAvailable: true,
            onAddFolder: () {},
            onExclusiveChanged: (_) {},
            onCloseToTrayChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final String label in <String>[
      '添加音乐目录',
      '独占输出（WASAPI）',
      '关闭窗口时留在托盘',
      '主题',
      '强调色',
    ]) {
      final Finder row = find
          .ancestor(of: find.text(label), matching: find.byType(InkWell))
          .first;
      expect(
        tester.widget<InkWell>(row).hoverColor,
        isNotNull,
        reason: '「$label」悬停时应能看到高光',
      );
    }

    // 最近的 Material 必须是卡片本身，否则水波纹会被卡片底色盖住
    final Finder rowInk = find
        .ancestor(of: find.text('添加音乐目录'), matching: find.byType(InkWell))
        .first;
    final Material card = tester.widget<Material>(
      find.ancestor(of: rowInk, matching: find.byType(Material)).first,
    );
    expect(card.clipBehavior, Clip.antiAlias);
  });
  testWidgets('输出设备、ReplayGain 与淡变设置回调', (WidgetTester tester) async {
    tester.view.physicalSize = canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<int> devicePicks = <int>[];
    final List<bool> gainPicks = <bool>[];
    final List<double> fades = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: SettingsView(
            trackCount: 1,
            engineAvailable: true,
            devices: const <rust.PlayerDevice>[
              rust.PlayerDevice(index: 1, name: '扬声器', isDefault: true),
              rust.PlayerDevice(index: 2, name: '耳机', isDefault: false),
            ],
            outputDevice: -1,
            onOutputDeviceChanged: devicePicks.add,
            replayGain: false,
            onReplayGainChanged: gainPicks.add,
            crossfadeSeconds: 0,
            onCrossfadeChanged: fades.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 输出设备：默认项之外还能选枚举到的设备
    final Finder deviceRow = find.byKey(
      const ValueKey<String>('settings-output-device'),
    );
    await tester.ensureVisible(deviceRow);
    await tester.tap(deviceRow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('耳机').last);
    await tester.pumpAndSettle();
    expect(devicePicks, <int>[2]);

    // ReplayGain 开关
    final Finder gainSwitch = find.byKey(
      const ValueKey<String>('settings-replay-gain-switch'),
    );
    await tester.ensureVisible(gainSwitch);
    await tester.tap(gainSwitch);
    await tester.pumpAndSettle();
    expect(gainPicks, <bool>[true]);

    // 淡变时长
    final Finder fadeRow = find.byKey(
      const ValueKey<String>('settings-crossfade'),
    );
    await tester.ensureVisible(fadeRow);
    await tester.tap(fadeRow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 秒').last);
    await tester.pumpAndSettle();
    expect(fades, <double>[4]);
  });
}

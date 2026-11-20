import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/update_check.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

Widget _harness({
  required bool autoUpdateCheck,
  ValueChanged<bool>? onAutoChanged,
  ValueChanged<UpdateCheckPeriod>? onPeriodChanged,
  UpdateCheckPeriod period = UpdateCheckPeriod.daily,
  bool checking = false,
  VoidCallback? onCheck,
}) {
  return MaterialApp(
    theme: AppTheme.light(AppTheme.defaultSeed),
    home: Scaffold(
      body: SettingsView(
        autoUpdateCheck: autoUpdateCheck,
        onAutoUpdateCheckChanged: onAutoChanged,
        updateCheckPeriod: period,
        onUpdateCheckPeriodChanged: onPeriodChanged,
        checkingUpdate: checking,
        onCheckUpdate: onCheck,
      ),
    ),
  );
}

Future<void> _scrollToUpdate(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('检查更新'),
    400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {});

  testWidgets('关于区有检查更新、自动检查开关与频率', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(autoUpdateCheck: false));
    await tester.pumpAndSettle();
    await _scrollToUpdate(tester);

    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('自动检查更新'), findsOneWidget);
    expect(find.text('自动检查频率'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('settings-auto-update-switch')),
      findsOneWidget,
    );
    expect(find.text('每天'), findsOneWidget);

    // 关着自动检查时频率下拉不可用
    final DropdownButton<UpdateCheckPeriod> dropdown = tester
        .widget<DropdownButton<UpdateCheckPeriod>>(
          find.byKey(const ValueKey<String>('settings-update-period')),
        );
    expect(dropdown.onChanged, isNull);
  });

  testWidgets('打开开关后可改频率，开关回调带新值', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool? toggled;
    UpdateCheckPeriod? picked;
    await tester.pumpWidget(
      _harness(
        autoUpdateCheck: true,
        onAutoChanged: (bool value) => toggled = value,
        onPeriodChanged: (UpdateCheckPeriod value) => picked = value,
      ),
    );
    await tester.pumpAndSettle();
    await _scrollToUpdate(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('settings-auto-update-switch')),
    );
    await tester.pumpAndSettle();
    expect(toggled, isFalse, reason: '点开关是把当前值取反');

    final DropdownButton<UpdateCheckPeriod> dropdown = tester
        .widget<DropdownButton<UpdateCheckPeriod>>(
          find.byKey(const ValueKey<String>('settings-update-period')),
        );
    expect(dropdown.onChanged, isNotNull, reason: '自动检查打开时频率可选');

    // 选「每周」
    await tester.tap(find.text('每天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周').last);
    await tester.pumpAndSettle();
    expect(picked, UpdateCheckPeriod.weekly);
  });

  testWidgets('点检查更新触发回调；检查期间禁用并转圈', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int taps = 0;
    await tester.pumpWidget(
      _harness(autoUpdateCheck: false, onCheck: () => taps += 1),
    );
    await tester.pumpAndSettle();
    await _scrollToUpdate(tester);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(taps, 1);

    // 转圈动画永不结束：这一段只能用 pump，不能用 pumpAndSettle
    await tester.pumpWidget(
      _harness(
        autoUpdateCheck: false,
        checking: true,
        onCheck: () => taps += 1,
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('检查更新'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('正在检查…'), findsOneWidget);

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(taps, 1, reason: '检查中再点不该再发一次');
  });
}

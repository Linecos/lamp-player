import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/equalizer.dart';
import 'package:lamp_player/src/features/settings/equalizer_curve.dart';
import 'package:lamp_player/src/features/settings/equalizer_page.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool enabled = true,
  List<double>? gains,
  String? presetName,
  List<EqualizerPreset> customPresets = const <EqualizerPreset>[],
  void Function(bool, List<double>, String?)? onChanged,
  ValueChanged<List<EqualizerPreset>>? onPresetsChanged,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: EqualizerPage(
        enabled: enabled,
        gains: gains ?? List<double>.filled(10, 0),
        presetName: presetName,
        customPresets: customPresets,
        onChanged: onChanged,
        onCustomPresetsChanged: onPresetsChanged,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('拖动推子松手才提交，并把曲线标记为自定义', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    await _pump(
      tester,
      presetName: '摇滚',
      onChanged: (bool enabled, List<double> gains, String? name) =>
          changes.add((enabled, gains, name)),
    );

    expect(find.text('预设：摇滚'), findsOneWidget);

    final Finder band = find.byKey(const ValueKey<String>('eq-band-5'));
    await tester.ensureVisible(band);
    // 竖推子：向上拖 = 增益变大
    await tester.dragFrom(tester.getRect(band).center, const Offset(0, -60));
    await tester.pumpAndSettle();

    expect(changes, isNotEmpty, reason: '松手应提交一次');
    expect(changes.last.$2[5], greaterThan(0));
    expect(changes.last.$3, isNull, reason: '手动调过就不再算某个预设');
    expect(find.text('自定义曲线'), findsOneWidget);
  });

  testWidgets('顶部曲线图按当前增益显示读数', (WidgetTester tester) async {
    await _pump(tester, gains: equalizerPresets.last.gains);

    final Finder chart = find.byType(EqualizerCurveChart);
    expect(chart, findsOneWidget);
    expect(
      tester.getRect(chart).top,
      lessThan(
        tester.getRect(find.byKey(const ValueKey<String>('eq-band-0'))).top,
      ),
      reason: '曲线图在推子上面',
    );
    // 重低音首段 +7
    expect(
      find.descendant(of: chart, matching: find.text('+7')),
      findsOneWidget,
    );
    expect(find.descendant(of: chart, matching: find.text('0')), findsWidgets);
  });

  testWidgets('点预设可整条曲线切换', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    await _pump(
      tester,
      onChanged: (bool enabled, List<double> gains, String? name) =>
          changes.add((enabled, gains, name)),
    );

    final Finder chip = find.byKey(const ValueKey<String>('eq-preset-重低音'));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(changes, isNotEmpty);
    final List<double> gains = changes.last.$2;
    expect(changes.last.$3, '重低音');
    expect(gains.first, closeTo(7, 0.01), reason: '重低音抬高低频');
    expect(find.text('预设：重低音'), findsOneWidget);
  });

  testWidgets('全部归零清空所有频段', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    await _pump(
      tester,
      gains: equalizerPresets.first.gains,
      onChanged: (bool enabled, List<double> gains, String? name) =>
          changes.add((enabled, gains, name)),
    );

    final Finder reset = find.byKey(const ValueKey<String>('eq-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(changes.last.$2.every((double gain) => gain == 0), isTrue);
    expect(changes.last.$3, isNull);
  });

  testWidgets('存为新预设会带回名称与增益', (WidgetTester tester) async {
    final List<List<EqualizerPreset>> saved = <List<EqualizerPreset>>[];
    final List<String?> names = <String?>[];
    await _pump(
      tester,
      gains: equalizerPresets.first.gains,
      onChanged: (_, _, String? name) => names.add(name),
      onPresetsChanged: saved.add,
    );

    final Finder save = find.byKey(const ValueKey<String>('eq-save-preset'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('eq-preset-name')),
      '夜间人声',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.single.name, '夜间人声');
    expect(saved.single.single.builtin, isFalse);
    expect(names.last, '夜间人声');
  });

  testWidgets('自定义预设可删除，内置预设没有删除按钮', (WidgetTester tester) async {
    final List<List<EqualizerPreset>> saved = <List<EqualizerPreset>>[];
    await _pump(
      tester,
      customPresets: <EqualizerPreset>[
        EqualizerPreset('我的曲线', List<double>.filled(10, 3)),
      ],
      onChanged: (_, _, _) {},
      onPresetsChanged: saved.add,
    );

    expect(
      find.byKey(const ValueKey<String>('eq-preset-重低音')),
      findsOneWidget,
      reason: '内置预设存在',
    );

    final Finder custom = find.byKey(const ValueKey<String>('eq-preset-我的曲线'));
    await tester.ensureVisible(custom);
    await tester.tap(
      find.descendant(of: custom, matching: find.byIcon(Icons.close)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(saved.single, isEmpty, reason: '删完只剩内置预设');
  });

  testWidgets('关闭开关时不改曲线、只回调禁用', (WidgetTester tester) async {
    final List<bool> enabledStates = <bool>[];
    await _pump(
      tester,
      gains: equalizerPresets.first.gains,
      onChanged: (bool enabled, _, _) => enabledStates.add(enabled),
    );

    await tester.tap(find.byKey(const ValueKey<String>('equalizer-enable')));
    await tester.pumpAndSettle();

    expect(enabledStates, <bool>[false]);
    expect(find.text('开启后可按频段调整音量'), findsOneWidget);
  });
}

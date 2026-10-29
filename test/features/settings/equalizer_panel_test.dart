import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/equalizer.dart';
import 'package:lamp_player/src/features/settings/equalizer_curve.dart';
import 'package:lamp_player/src/features/settings/equalizer_panel.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool enabled = true,
  List<double>? gains,
  String? presetName,
  List<EqualizerPreset> customPresets = const <EqualizerPreset>[],
  void Function(bool, List<double>, String?)? onChanged,
  ValueChanged<List<EqualizerPreset>>? onPresetsChanged,
  Size size = const Size(900, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      // 面板本身只负责内容，外壳在两个入口的弹窗里（`showEqualizerDialog`）
      home: Scaffold(
        body: EqualizerPanel(
          enabled: enabled,
          gains: gains ?? List<double>.filled(10, 0),
          presetName: presetName,
          customPresets: customPresets,
          onChanged: onChanged,
          onCustomPresetsChanged: onPresetsChanged,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 在 [target] 上滚动鼠标滚轮（dy < 0 表示向上滚）
Future<void> _scrollAt(WidgetTester tester, Finder target, double dy) =>
    _scrollAtPoint(tester, tester.getCenter(target), dy);

/// 在任意位置滚动滚轮（dy < 0 表示向上滚）
Future<void> _scrollAtPoint(
  WidgetTester tester,
  Offset point,
  double dy,
) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(point));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('滚轮一格 = 1 dB，合并后下发', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    await _pump(
      tester,
      presetName: '摇滚',
      onChanged: (bool enabled, List<double> gains, String? name) =>
          changes.add((enabled, gains, name)),
    );

    await _scrollAt(
      tester,
      find.byKey(const ValueKey<String>('eq-band-0')),
      -40,
    );
    // 连续滚三格，中间不该每格都下发
    await _scrollAt(
      tester,
      find.byKey(const ValueKey<String>('eq-band-0')),
      -40,
    );
    await _scrollAt(
      tester,
      find.byKey(const ValueKey<String>('eq-band-0')),
      -40,
    );
    expect(changes, isEmpty, reason: '120ms 合并窗口内先不下发');

    await tester.pump(const Duration(milliseconds: 150));
    expect(changes, hasLength(1));
    expect(changes.single.$2.first, 3, reason: '三格共 +3 dB');
    expect(changes.single.$3, isNull, reason: '手动调整后退化成自定义');
  });

  testWidgets('滚轮向下滚动减 1 dB', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    await _pump(
      tester,
      onChanged: (bool enabled, List<double> gains, String? name) =>
          changes.add((enabled, gains, name)),
    );

    await _scrollAt(
      tester,
      find.byKey(const ValueKey<String>('eq-band-9')),
      40,
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(changes.single.$2.last, -1);
  });

  testWidgets('滚轮到 ±15 dB 到顶不再变化', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    final List<double> gains = List<double>.filled(10, 0)
      ..[0] = equalizerMaxGain;
    await _pump(
      tester,
      gains: gains,
      onChanged: (bool enabled, List<double> list, String? name) =>
          changes.add((enabled, list, name)),
    );

    await _scrollAt(
      tester,
      find.byKey(const ValueKey<String>('eq-band-0')),
      -40,
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(changes, isEmpty, reason: '已在 +15 dB，没有变化就不该下发');
  });

  testWidgets('滚轮只认推子中线，两侧空白不响应', (WidgetTester tester) async {
    final List<(bool, List<double>, String?)> changes =
        <(bool, List<double>, String?)>[];
    await _pump(
      tester,
      onChanged: (bool enabled, List<double> gains, String? name) =>
          changes.add((enabled, gains, name)),
    );

    final Offset center = tester.getCenter(
      find.byKey(const ValueKey<String>('eq-band-0')),
    );
    // 列宽约 70，往旁边偏 30 就离开了中线那条感应带
    await _scrollAtPoint(tester, center + const Offset(30, 0), -40);
    await tester.pump(const Duration(milliseconds: 150));
    expect(changes, isEmpty, reason: '没放在杆子上不该改增益');

    await _scrollAtPoint(tester, center, -40);
    await tester.pump(const Duration(milliseconds: 150));
    expect(changes, hasLength(1), reason: '中线附近才响应');
    expect(changes.single.$2.first, 1);
  });

  testWidgets('推子只占中线 28px，光标不会整列都是可拖动', (WidgetTester tester) async {
    await _pump(tester);

    // RotatedBox 会把本地尺寸转过来，用 getRect 看屏幕上的实际矩形
    final Rect slider = tester.getRect(
      find.byKey(const ValueKey<String>('eq-band-0')),
    );
    // Slider 自带 MouseCursor（手型）铺满自身矩形，收窄它才收窄光标范围
    expect(slider.width, closeTo(28, 0.01));
    expect(slider.height, greaterThan(100), reason: '纵向仍要占满，能拖到整个范围');
  });

  testWidgets('最小窗口也摆得下，页面不需要滚动', (WidgetTester tester) async {
    // 900×560 是主窗口允许的最小尺寸
    await _pump(tester, size: const Size(900, 560));

    expect(tester.takeException(), isNull, reason: '不能溢出');
    expect(
      find.byType(Scrollable),
      findsNothing,
      reason: '推子页不该有滚动容器：滚轮要专给推子用',
    );
    expect(find.byKey(const ValueKey<String>('eq-reset')), findsOneWidget);

    final Rect slider = tester.getRect(
      find.byKey(const ValueKey<String>('eq-band-0')),
    );
    expect(slider.height, greaterThan(80), reason: '推子仍要有可拖的长度');
  });

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

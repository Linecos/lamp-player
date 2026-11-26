import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/scroll/smooth_scroll.dart';
import 'package:lamp_player/src/features/settings/font_picker_dialog.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

const List<String> _families = <String>['Arial', 'Microsoft YaHei', 'SimSun'];

/// 点按钮开弹窗，把结果记进 [results]
Widget _harness({
  required String current,
  required String defaultLabel,
  required List<String?> results,
}) {
  return MaterialApp(
    theme: AppTheme.light(AppTheme.defaultSeed),
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async {
            results.add(
              await showFontPickerDialog(
                context,
                current: current,
                defaultLabel: defaultLabel,
                families: _families,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('弹窗按搜索过滤，点行返回字体族名', (WidgetTester tester) async {
    final List<String?> results = <String?>[];
    await tester.pumpWidget(
      _harness(current: '', defaultLabel: '跟随界面字体', results: results),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('选择字体'), findsOneWidget);
    // 默认项永远在列表里，且在第一位
    expect(find.byKey(const ValueKey<String>('font-choice-')), findsOneWidget);
    // 内置表里有中文名的会拼成「微软雅黑（Microsoft YaHei）」
    expect(find.textContaining('Microsoft YaHei'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('font-picker-search')),
      'arial',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Microsoft YaHei'), findsNothing);
    expect(find.text('Arial'), findsOneWidget);

    // 字体列表上百行，滚轮必须走平滑控制器
    expect(
      tester
          .widget<ListView>(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(ListView),
            ),
          )
          .controller,
      isA<SmoothScrollController>(),
    );

    await tester.tap(find.byKey(const ValueKey<String>('font-choice-Arial')));
    await tester.pumpAndSettle();

    expect(results, <String>['Arial']);
  });

  testWidgets('每一项用它自己的字形画，当前项高亮 + 勾选', (WidgetTester tester) async {
    final List<String?> results = <String?>[];
    await tester.pumpWidget(
      _harness(current: 'SimSun', defaultLabel: '跟随界面字体', results: results),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Finder simsun = find.byKey(
      const ValueKey<String>('font-choice-SimSun'),
    );
    final Text text = tester.widget<Text>(
      find.descendant(of: simsun, matching: find.byType(Text)),
    );
    expect(text.style?.fontFamily, 'SimSun');
    expect(
      find.descendant(of: simsun, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // 非当前项没有勾
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('font-choice-Arial')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
  });

  testWidgets('搜不到时给出提示，不崩', (WidgetTester tester) async {
    final List<String?> results = <String?>[];
    await tester.pumpWidget(
      _harness(current: '', defaultLabel: '跟随界面字体', results: results),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('font-picker-search')),
      'zzzz',
    );
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配字体'), findsOneWidget);
  });

  testWidgets('最小窗口 900×560 下弹窗不溢出，列表照常可用', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<String?> results = <String?>[];
    await tester.pumpWidget(
      _harness(current: '', defaultLabel: '跟随界面字体', results: results),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('font-choice-Arial')),
      findsOneWidget,
    );
    // 弹窗整体留在窗口里
    final Rect dialog = tester.getRect(
      find.byKey(const ValueKey<String>('font-picker-dialog')),
    );
    expect(dialog.top, greaterThanOrEqualTo(0));
    expect(dialog.bottom, lessThanOrEqualTo(560));
  });

  testWidgets('关掉弹窗返回 null，调用方不改成第一项', (WidgetTester tester) async {
    final List<String?> results = <String?>[];
    await tester.pumpWidget(
      _harness(current: 'Arial', defaultLabel: '跟随界面字体', results: results),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(results, <String?>[null]);
  });
}

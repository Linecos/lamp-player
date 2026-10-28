import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/shortcuts.dart';
import 'package:lamp_player/src/features/settings/shortcuts_page.dart';

Future<List<List<ShortcutBinding>>> _pump(
  WidgetTester tester, {
  List<ShortcutBinding> bindings = kDefaultShortcuts,
}) async {
  final List<List<ShortcutBinding>> changes = <List<ShortcutBinding>>[];
  await tester.pumpWidget(
    MaterialApp(
      home: ShortcutsPage(
        bindings: bindings,
        onChanged: (List<ShortcutBinding> next) => changes.add(next),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return changes;
}

Future<void> _record(
  WidgetTester tester,
  String label,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? modifier,
}) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  if (modifier != null) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  if (modifier != null) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pumpAndSettle();
}

ShortcutAction _actionOf(ShortcutBinding binding) => binding.action;

void main() {
  testWidgets('录制新组合键后立即回调并更新键帽', (WidgetTester tester) async {
    final List<List<ShortcutBinding>> changes = await _pump(tester);

    await _record(
      tester,
      '播放 / 暂停',
      LogicalKeyboardKey.keyP,
      modifier: LogicalKeyboardKey.controlLeft,
    );

    expect(find.text('Ctrl + P'), findsOneWidget);
    expect(changes, hasLength(1));
    final ShortcutBinding changed = changes.single.firstWhere(
      (ShortcutBinding b) => b.action == ShortcutAction.togglePlay,
    );
    expect(
      shortcutId(changed.activator),
      shortcutId(
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          control: true,
          includeRepeats: false,
        ),
      ),
    );
  });

  testWidgets('组合键和别的动作撞车时拒绝并说明被谁占用', (WidgetTester tester) async {
    final List<List<ShortcutBinding>> changes = await _pump(tester);

    // 空格已经是「播放 / 暂停」，改成「下一首」应当被拒
    await _record(tester, '下一首', LogicalKeyboardKey.space);

    expect(find.textContaining('已被「播放 / 暂停」占用'), findsOneWidget);
    expect(changes, isEmpty, reason: '被拒时不该回调');

    // 仍在录制态，可以直接重按：Ctrl+N 应当成功
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(find.text('Ctrl + N'), findsOneWidget);
  });

  testWidgets('裸字母键被拒，提示需要配合修饰键', (WidgetTester tester) async {
    final List<List<ShortcutBinding>> changes = await _pump(tester);

    await _record(tester, '播放 / 暂停', LogicalKeyboardKey.keyA);

    expect(find.textContaining('配合 Ctrl / Alt / Shift'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('空格 / 方向键这类播放键不要求修饰键', (WidgetTester tester) async {
    final List<List<ShortcutBinding>> changes = await _pump(tester);

    // 把「快进 5 秒」改成 ↑（无修饰键，但属于允许的播放键）
    await _record(tester, '快进 5 秒', LogicalKeyboardKey.arrowUp);

    expect(changes, hasLength(1));
    expect(find.text('↑'), findsOneWidget);
  });

  testWidgets('Esc 取消录制，不改任何键位', (WidgetTester tester) async {
    final List<List<ShortcutBinding>> changes = await _pump(tester);

    await tester.tap(find.text('播放 / 暂停'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正在录制'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.textContaining('正在录制'), findsNothing);
    expect(find.text('空格'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('恢复默认把整张表还原', (WidgetTester tester) async {
    // 起点用一份改过的配置
    final List<ShortcutBinding> custom = <ShortcutBinding>[
      for (final ShortcutBinding binding in kDefaultShortcuts)
        if (binding.action == ShortcutAction.togglePlay)
          const ShortcutBinding(
            ShortcutAction.togglePlay,
            SingleActivator(
              LogicalKeyboardKey.keyP,
              control: true,
              includeRepeats: false,
            ),
          )
        else
          binding,
    ];
    final List<List<ShortcutBinding>> changes = await _pump(
      tester,
      bindings: custom,
    );
    expect(find.text('Ctrl + P'), findsOneWidget);

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    expect(find.text('Ctrl + P'), findsNothing);
    expect(find.text('空格'), findsOneWidget);
    expect(changes, hasLength(1));
    expect(
      changes.single.map(_actionOf).toList(),
      kDefaultShortcuts.map(_actionOf).toList(),
    );
  });

  testWidgets('Tab 留给焦点切换，不参与录制', (WidgetTester tester) async {
    final List<List<ShortcutBinding>> changes = await _pump(tester);

    await _record(tester, '播放 / 暂停', LogicalKeyboardKey.tab);

    expect(find.textContaining('Tab 留给'), findsOneWidget);
    expect(changes, isEmpty);
  });
}

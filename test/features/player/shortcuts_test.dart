import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show ShortcutActivator, SingleActivator, VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/shortcuts.dart';

void main() {
  test('默认表里每个动作只出现一次，组合键互不重复', () {
    final Set<ShortcutAction> actions = <ShortcutAction>{};
    final Set<String> activators = <String>{};
    for (final ShortcutBinding binding in kDefaultShortcuts) {
      expect(
        actions.add(binding.action),
        isTrue,
        reason: '${binding.action.name} 出现两次',
      );
      expect(
        activators.add(shortcutId(binding.activator)),
        isTrue,
        reason: '${describeActivator(binding.activator)} 绑了两个动作',
      );
    }
    expect(
      actions.length,
      ShortcutAction.values.length,
      reason: '新增动作要同时给出默认键位',
    );
  });

  test('按住不放不触发重复（includeRepeats 全为 false）', () {
    for (final ShortcutBinding binding in kDefaultShortcuts) {
      expect(binding.activator.includeRepeats, isFalse);
    }
  });

  test('缺处理器的动作不绑定，页面各取所需', () {
    final Map<ShortcutActivator, VoidCallback> bindings = shortcutBindings(
      <ShortcutAction, VoidCallback>{
        ShortcutAction.togglePlay: () {},
        ShortcutAction.next: () {},
      },
    );

    expect(bindings.length, 2);
    expect(
      bindings.containsKey(
        const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
      ),
      isTrue,
    );
    expect(
      bindings.containsKey(
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          includeRepeats: false,
        ),
      ),
      isFalse,
      reason: '没给 focusSearch 处理器就不该绑定 Ctrl+F',
    );
  });

  test('自定义表覆盖默认键位', () {
    final Map<ShortcutActivator, VoidCallback> bindings = shortcutBindings(
      <ShortcutAction, VoidCallback>{ShortcutAction.togglePlay: () {}},
      bindings: const <ShortcutBinding>[
        ShortcutBinding(
          ShortcutAction.togglePlay,
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
        ),
      ],
    );

    expect(
      bindings.keys.single,
      const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
    );
  });

  test('normalizeShortcuts 补齐缺失动作并保持默认顺序', () {
    final List<ShortcutBinding> fixed = normalizeShortcuts(
      const <ShortcutBinding>[
        ShortcutBinding(
          ShortcutAction.next,
          SingleActivator(LogicalKeyboardKey.keyN, includeRepeats: false),
        ),
      ],
    );

    expect(fixed.length, ShortcutAction.values.length, reason: '缺的要用默认键补上');
    expect(
      fixed.first.action,
      kDefaultShortcuts.first.action,
      reason: '顺序按默认表',
    );
    final ShortcutBinding next = fixed.firstWhere(
      (ShortcutBinding b) => b.action == ShortcutAction.next,
    );
    expect(next.activator.trigger, LogicalKeyboardKey.keyN, reason: '用户的改动要保留');
  });

  test('normalizeShortcuts 丢掉重复组合键，不让两个动作抢同一个键', () {
    final List<ShortcutBinding> fixed = normalizeShortcuts(
      const <ShortcutBinding>[
        ShortcutBinding(
          ShortcutAction.next,
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
        ),
      ],
    );

    final Iterable<ShortcutAction> spaceUsers = fixed
        .where(
          (ShortcutBinding b) =>
              b.activator.trigger == LogicalKeyboardKey.space &&
              !b.activator.control &&
              !b.activator.alt &&
              !b.activator.shift,
        )
        .map((ShortcutBinding b) => b.action);
    expect(spaceUsers, <ShortcutAction>[
      ShortcutAction.next,
    ], reason: '先到先得，空格只留给下一首');
    expect(
      fixed.any((ShortcutBinding b) => b.action == ShortcutAction.togglePlay),
      isFalse,
      reason: '空格被占用后，播放暂停宁可没有绑定也不撞车',
    );
  });

  test('键位编码 / 解码往返一致', () {
    // SingleActivator 没有值相等语义，比较编码结果而不是对象
    for (final ShortcutBinding binding in kDefaultShortcuts) {
      final Map<String, Object?> encoded = encodeShortcut(binding);
      final ShortcutBinding? restored = decodeShortcut(encoded);
      expect(restored, isNotNull, reason: binding.action.name);
      expect(restored!.action, binding.action);
      expect(encodeShortcut(restored), encoded, reason: binding.action.name);
      expect(shortcutId(restored.activator), shortcutId(binding.activator));
    }
  });

  test('解出坏数据时返回 null，交给兜底逻辑', () {
    expect(decodeShortcut(null), isNull);
    expect(
      decodeShortcut(<String, Object?>{'action': 'nope', 'key': 32}),
      isNull,
    );
    expect(
      decodeShortcut(<String, Object?>{'action': 'togglePlay', 'key': 999999}),
      isNull,
    );
  });

  test('组合键文本：符号键与修饰键顺序', () {
    expect(
      describeActivator(
        const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
      ),
      '空格',
    );
    expect(
      describeActivator(
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
          includeRepeats: false,
        ),
      ),
      'Ctrl + ←',
    );
    expect(
      describeActivator(
        const SingleActivator(
          LogicalKeyboardKey.keyM,
          control: true,
          shift: true,
          includeRepeats: false,
        ),
      ),
      'Ctrl + Shift + M',
    );
  });
}

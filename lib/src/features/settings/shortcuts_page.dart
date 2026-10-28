import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/shortcuts.dart';

/// 快捷键设置页：点一行 → 按下想要的组合键 → 立即生效并保存。
///
/// 校验放在这里而不是调用方：录制过程中只有本页知道用户按了什么，越早拒绝
/// 越容易解释（冲突 / 裸键 / Esc 都有明确提示）。
class ShortcutsPage extends StatefulWidget {
  const ShortcutsPage({super.key, required this.bindings, this.onChanged});

  /// 进入时的键位表（通常是 `LibraryPage` 当前生效的那份）
  final List<ShortcutBinding> bindings;

  /// 每次改动后回调；为空时只在本页内生效（测试 / 预览用）
  final ValueChanged<List<ShortcutBinding>>? onChanged;

  @override
  State<ShortcutsPage> createState() => _ShortcutsPageState();
}

class _ShortcutsPageState extends State<ShortcutsPage> {
  late List<ShortcutBinding> _bindings = List<ShortcutBinding>.of(
    normalizeShortcuts(widget.bindings),
  );

  /// 正在等待按键的动作；null 表示没在录制
  ShortcutAction? _recording;

  /// 录制失败的提示（冲突 / 裸键），显示在标题下方
  String? _error;

  final FocusNode _focus = FocusNode(debugLabel: 'shortcut-record');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('快捷键'),
        actions: <Widget>[
          TextButton(onPressed: _restoreDefaults, child: const Text('恢复默认')),
          const SizedBox(width: 8),
        ],
      ),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: <Widget>[
            Text(
              _recording == null
                  ? '点击任意一行，然后按下想要的组合键。'
                  : '正在录制「${_recording!.label}」：按下组合键，Esc 取消。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _recording == null
                    ? scheme.onSurfaceVariant
                    : scheme.primary,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            for (final ShortcutBinding binding in _bindings)
              _ShortcutRow(
                action: binding.action,
                activator: binding.activator,
                recording: _recording == binding.action,
                onTap: () => _startRecording(binding.action),
              ),
            const SizedBox(height: 16),
            Text(
              '只在本应用窗口聚焦时生效（媒体键由系统转发，任何窗口下都能用）。'
              '单个字母 / 数字键需配合 Ctrl、Alt、Shift 之一，避免和输入冲突。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _startRecording(ShortcutAction action) {
    setState(() {
      _recording = action;
      _error = null;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final ShortcutAction? action = _recording;
    if (action == null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _recording = null;
        _error = null;
      });
      return KeyEventResult.handled;
    }
    // 只按了修饰键：继续等主键
    if (_isModifier(key)) {
      return KeyEventResult.handled;
    }

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool control = keyboard.isControlPressed;
    final bool alt = keyboard.isAltPressed;
    final bool shift = keyboard.isShiftPressed;
    final bool meta = keyboard.isMetaPressed;

    // Tab / Shift+Tab 被焦点系统用来切焦点，录进去也会和界面操作打架
    if (key == LogicalKeyboardKey.tab) {
      setState(() => _error = 'Tab 留给界面焦点切换');
      return KeyEventResult.handled;
    }

    if (!control && !alt && !shift && !meta && !_allowsBareKey(key)) {
      setState(() {
        _error =
            '「${describeKey(key)}」需要配合 Ctrl / Alt / Shift 使用，'
            '否则会和输入冲突';
      });
      return KeyEventResult.handled;
    }

    final SingleActivator candidate = SingleActivator(
      key,
      control: control,
      alt: alt,
      shift: shift,
      meta: meta,
      includeRepeats: false,
    );

    for (final ShortcutBinding binding in _bindings) {
      if (binding.action != action &&
          shortcutId(binding.activator) == shortcutId(candidate)) {
        setState(
          () => _error =
              '${describeActivator(candidate)} 已被「${binding.action.label}」占用',
        );
        return KeyEventResult.handled;
      }
    }

    final List<ShortcutBinding> next = <ShortcutBinding>[
      for (final ShortcutBinding binding in _bindings)
        if (binding.action == action)
          ShortcutBinding(action, candidate)
        else
          binding,
    ];
    setState(() {
      _bindings = next;
      _recording = null;
      _error = null;
    });
    widget.onChanged?.call(next);
    return KeyEventResult.handled;
  }

  void _restoreDefaults() {
    setState(() {
      _bindings = kDefaultShortcuts;
      _recording = null;
      _error = null;
    });
    widget.onChanged?.call(kDefaultShortcuts);
  }

  /// 无修饰键也允许的键：空格、方向键、媒体键——它们本来就是播放控制键
  bool _allowsBareKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious;
  }

  bool _isModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.action,
    required this.activator,
    required this.recording,
    required this.onTap,
  });

  final ShortcutAction action;
  final SingleActivator activator;
  final bool recording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(action.label, style: theme.textTheme.bodyLarge),
            ),
            const SizedBox(width: 12),
            if (recording)
              Text(
                '按下组合键…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Text(
                  describeActivator(activator),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            Icon(
              recording ? Icons.keyboard : Icons.edit_outlined,
              size: 18,
              color: scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

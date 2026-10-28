import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show ShortcutActivator, SingleActivator, VoidCallback;

/// 快捷键的唯一来源。
///
/// 曲库页与正在播放页都从这里生成 `CallbackShortcuts` 的绑定：新增 / 改键
/// 只改这一处，两边不会漂移（这两页是独立路由，各自持有一份焦点树）。
///
/// 自定义键位的链路：设置页「快捷键」→ `ShortcutsPage` 录制新组合键 →
/// `LibraryPage` 更新 `_shortcuts` 并写进会话（`SessionSnapshot.shortcutsJson`）→
/// 两个页面的 `CallbackShortcuts` 跟着重建。页面里的 key 判断不涉及具体键位。

/// 能被快捷键触发的动作。
///
/// `label` 同时用于设置页的快捷键一览，措辞按「用户看到的行为」写。
enum ShortcutAction {
  togglePlay('播放 / 暂停'),
  next('下一首'),
  previous('上一首'),
  seekForward('快进 5 秒'),
  seekBackward('快退 5 秒'),
  volumeUp('音量 +5%'),
  volumeDown('音量 -5%'),
  toggleMute('静音切换'),
  focusSearch('聚焦搜索'),
  mediaTogglePlay('播放 / 暂停（媒体键）'),
  mediaNext('下一首（媒体键）'),
  mediaPrevious('上一首（媒体键）');

  const ShortcutAction(this.label);

  final String label;
}

/// 一条键位：动作 + 触发它的组合键。
class ShortcutBinding {
  const ShortcutBinding(this.action, this.activator);

  final ShortcutAction action;

  /// `includeRepeats` 一律为 false：按住不放时播放器不该连续切歌 / 连续 seek。
  final SingleActivator activator;
}

/// 默认键位表；顺序即设置页展示顺序。
const List<ShortcutBinding> kDefaultShortcuts = <ShortcutBinding>[
  ShortcutBinding(
    ShortcutAction.togglePlay,
    SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
  ),
  ShortcutBinding(
    ShortcutAction.seekBackward,
    SingleActivator(LogicalKeyboardKey.arrowLeft, includeRepeats: false),
  ),
  ShortcutBinding(
    ShortcutAction.seekForward,
    SingleActivator(LogicalKeyboardKey.arrowRight, includeRepeats: false),
  ),
  ShortcutBinding(
    ShortcutAction.previous,
    SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      control: true,
      includeRepeats: false,
    ),
  ),
  ShortcutBinding(
    ShortcutAction.next,
    SingleActivator(
      LogicalKeyboardKey.arrowRight,
      control: true,
      includeRepeats: false,
    ),
  ),
  ShortcutBinding(
    ShortcutAction.volumeUp,
    SingleActivator(
      LogicalKeyboardKey.arrowUp,
      control: true,
      includeRepeats: false,
    ),
  ),
  ShortcutBinding(
    ShortcutAction.volumeDown,
    SingleActivator(
      LogicalKeyboardKey.arrowDown,
      control: true,
      includeRepeats: false,
    ),
  ),
  ShortcutBinding(
    ShortcutAction.toggleMute,
    SingleActivator(
      LogicalKeyboardKey.keyM,
      control: true,
      includeRepeats: false,
    ),
  ),
  ShortcutBinding(
    ShortcutAction.focusSearch,
    SingleActivator(
      LogicalKeyboardKey.keyF,
      control: true,
      includeRepeats: false,
    ),
  ),
  // 媒体键：键盘上没有修饰键可用，单独成动作（设置页会如实列出来）
  ShortcutBinding(
    ShortcutAction.mediaTogglePlay,
    SingleActivator(LogicalKeyboardKey.mediaPlayPause, includeRepeats: false),
  ),
  ShortcutBinding(
    ShortcutAction.mediaNext,
    SingleActivator(LogicalKeyboardKey.mediaTrackNext, includeRepeats: false),
  ),
  ShortcutBinding(
    ShortcutAction.mediaPrevious,
    SingleActivator(
      LogicalKeyboardKey.mediaTrackPrevious,
      includeRepeats: false,
    ),
  ),
];

/// 把「动作 → 处理函数」合成 `CallbackShortcuts` 需要的「组合键 → 回调」。
///
/// 页面只提供自己支持的处理器：没有处理器的动作直接跳过（比如正在播放页
/// 不传搜索，就不会绑定 Ctrl+F），这样同一份键位表能同时喂给两个页面。
/// 同一组合键出现多次时后者覆盖前者，[kDefaultShortcuts] 由测试保证不重复。
Map<ShortcutActivator, VoidCallback> shortcutBindings(
  Map<ShortcutAction, VoidCallback> handlers, {
  List<ShortcutBinding> bindings = kDefaultShortcuts,
}) {
  final Map<ShortcutActivator, VoidCallback> result =
      <ShortcutActivator, VoidCallback>{};
  for (final ShortcutBinding binding in bindings) {
    final VoidCallback? handler = handlers[binding.action];
    if (handler != null) {
      result[binding.activator] = handler;
    }
  }
  return result;
}

/// 键位存储的抽象。
///
/// 当前实现直接走 `SessionSnapshot.shortcutsJson`（见 `PrefsSessionStore`），
/// 需要换存储（比如云同步、按设备区分）时实现本接口并替换即可；无论哪种实现，
/// 读出来的表都要过一遍 [normalizeShortcuts]，否则用户误配置（动作缺失、
/// 组合键撞车、键位写坏）会变成「按了没反应」且无从恢复。
abstract interface class ShortcutStore {
  Future<List<ShortcutBinding>> load();

  Future<void> save(List<ShortcutBinding> bindings);
}

/// 把任意外部键位表整理成可用的：缺的动作补默认键、重复组合键只留先出现的。
///
/// 返回值按 [kDefaultShortcuts] 的顺序排列，设置页展示顺序因此稳定。
/// 若某个默认键已经被用户配置占用，对应动作就保持无绑定（宁可少一个快捷键，
/// 也不让两个动作抢同一个组合键）。
List<ShortcutBinding> normalizeShortcuts(List<ShortcutBinding> bindings) {
  final Map<ShortcutAction, ShortcutBinding> chosen =
      <ShortcutAction, ShortcutBinding>{};
  final Set<SingleActivator> used = <SingleActivator>{};
  for (final ShortcutBinding binding in bindings) {
    if (chosen.containsKey(binding.action) ||
        used.contains(binding.activator)) {
      continue;
    }
    chosen[binding.action] = binding;
    used.add(binding.activator);
  }
  for (final ShortcutBinding fallback in kDefaultShortcuts) {
    if (chosen.containsKey(fallback.action) ||
        used.contains(fallback.activator)) {
      continue;
    }
    chosen[fallback.action] = fallback;
    used.add(fallback.activator);
  }
  return <ShortcutBinding>[
    for (final ShortcutBinding binding in kDefaultShortcuts)
      if (chosen[binding.action] != null) chosen[binding.action]!,
  ];
}

/// 整张键位表 → JSON 字符串，直接塞进会话快照 / shared_preferences。
String encodeShortcuts(List<ShortcutBinding> bindings) {
  return jsonEncode(<Map<String, Object?>>[
    for (final ShortcutBinding binding in bindings) encodeShortcut(binding),
  ]);
}

/// [encodeShortcuts] 的逆操作。
///
/// 空串、非列表、坏条目一律当「没有自定义」处理并回落 [kDefaultShortcuts]：
/// 键位配置坏了最多是键位复原，不能因此起不来。解析成功的部分仍会过一遍
/// [normalizeShortcuts]，把漏掉的动作补齐。
List<ShortcutBinding> decodeShortcuts(String json) {
  if (json.isEmpty) {
    return kDefaultShortcuts;
  }
  try {
    final Object? data = jsonDecode(json);
    if (data is! List) {
      return kDefaultShortcuts;
    }
    final List<ShortcutBinding> parsed = <ShortcutBinding>[];
    for (final Object? item in data) {
      final ShortcutBinding? binding = decodeShortcut(item);
      if (binding != null) {
        parsed.add(binding);
      }
    }
    return parsed.isEmpty ? kDefaultShortcuts : normalizeShortcuts(parsed);
  } catch (_) {
    return kDefaultShortcuts;
  }
}

/// 一条键位 → 可持久化的 JSON（存进 shared_preferences / SessionStore 都行）。
///
/// 用 `trigger.keyId` 而不是键名：跨布局 / 输入法稳定，Linux 与 Windows 一致。
Map<String, Object?> encodeShortcut(ShortcutBinding binding) {
  return <String, Object?>{
    'action': binding.action.name,
    'key': binding.activator.trigger.keyId,
    'control': binding.activator.control,
    'alt': binding.activator.alt,
    'shift': binding.activator.shift,
    'meta': binding.activator.meta,
  };
}

/// [encodeShortcut] 的逆操作；数据不合法返回 null（交给 [normalizeShortcuts] 补默认）。
ShortcutBinding? decodeShortcut(Object? json) {
  if (json is! Map) {
    return null;
  }
  final Object? actionName = json['action'];
  final Object? keyId = json['key'];
  if (actionName is! String || keyId is! int) {
    return null;
  }
  ShortcutAction? action;
  for (final ShortcutAction candidate in ShortcutAction.values) {
    if (candidate.name == actionName) {
      action = candidate;
      break;
    }
  }
  final LogicalKeyboardKey? key = LogicalKeyboardKey.findKeyByKeyId(keyId);
  if (action == null || key == null) {
    return null;
  }
  return ShortcutBinding(
    action,
    SingleActivator(
      key,
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      meta: json['meta'] == true,
      includeRepeats: false,
    ),
  );
}

/// 组合键的稳定标识：`ctrl+alt+shift+meta:keyId`。
///
/// `SingleActivator` 没有值相等语义（`==` 比的是对象身份），所以「两个键位是不是
/// 同一个组合键」不能用 `Set<SingleActivator>` 判断，一律走这个字符串。
String shortcutId(SingleActivator activator) {
  final String modifiers = <String>[
    if (activator.control) 'ctrl',
    if (activator.alt) 'alt',
    if (activator.shift) 'shift',
    if (activator.meta) 'meta',
  ].join('+');
  return '$modifiers:${activator.trigger.keyId}';
}

/// 组合键的可读文本，设置页展示用：`Ctrl + Alt + ←`
String describeActivator(SingleActivator activator) {
  return <String>[
    if (activator.control) 'Ctrl',
    if (activator.alt) 'Alt',
    if (activator.shift) 'Shift',
    if (activator.meta) 'Win',
    describeKey(activator.trigger),
  ].join(' + ');
}

/// 单个键的可读文本；媒体键与方向键给符号，其余用系统键名。
String describeKey(LogicalKeyboardKey key) {
  final String? symbol = switch (key) {
    LogicalKeyboardKey.space => '空格',
    LogicalKeyboardKey.arrowLeft => '←',
    LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.arrowUp => '↑',
    LogicalKeyboardKey.arrowDown => '↓',
    LogicalKeyboardKey.mediaPlayPause => '媒体播放键',
    LogicalKeyboardKey.mediaTrackNext => '媒体下一首键',
    LogicalKeyboardKey.mediaTrackPrevious => '媒体上一首键',
    _ => null,
  };
  if (symbol != null) {
    return symbol;
  }
  final String label = key.keyLabel;
  return label.isEmpty ? key.debugName ?? '未知键' : label;
}

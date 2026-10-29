import 'package:flutter/material.dart';

import '../../rust/api/player.dart' as rust;

/// 输出设备选择弹窗。
///
/// 原来这里是右上角的小菜单（`PopupMenuButton`），和播放队列 / 睡眠定时的
/// 弹窗样式不统一；现在改成同一种 AlertDialog：图标 + 标题 + 列表，当前设备
/// 用主色底和勾选标出来，点一行即选中并关窗。
///
/// 返回值：选中的设备下标（-1 = 系统默认）；用户直接关掉时返回 `null`，
/// 调用方不要当成「选了第一项」。
Future<int?> showOutputDeviceDialog(
  BuildContext context, {
  required List<rust.PlayerDevice> devices,
  required int selected,
}) {
  return showDialog<int>(
    context: context,
    builder: (BuildContext context) =>
        _OutputDeviceDialog(devices: devices, selected: selected),
  );
}

class _OutputDeviceDialog extends StatelessWidget {
  const _OutputDeviceDialog({required this.devices, required this.selected});

  final List<rust.PlayerDevice> devices;

  /// 当前选中的设备下标，-1 表示系统默认
  final int selected;

  @override
  Widget build(BuildContext context) {
    // 设备被拔掉后存档里的下标可能已经不在列表里：此时谁都不高亮
    final bool known =
        selected < 0 ||
        devices.any((rust.PlayerDevice d) => d.index == selected);

    return AlertDialog(
      key: const ValueKey<String>('output-device-dialog'),
      // 子节点不允许画到 28px 圆角外面（与播放队列一致）
      clipBehavior: Clip.antiAlias,
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
      contentPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: <Widget>[
          const Icon(Icons.speaker_outlined, size: 22),
          const SizedBox(width: 10),
          const Expanded(child: Text('输出设备')),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        // 设备多的时候（HDMI / USB 声卡 / 虚拟声卡）别把弹窗撑出屏幕
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          // 列表自己的透明 Material：悬停与点击的水波纹只落在列表里
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              children: <Widget>[
                _DeviceRow(
                  index: -1,
                  name: '系统默认',
                  active: known && selected < 0,
                ),
                for (final rust.PlayerDevice device in devices)
                  _DeviceRow(
                    index: device.index,
                    name: device.name,
                    active: known && device.index == selected,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.index,
    required this.name,
    required this.active,
  });

  final int index;
  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : null,
          borderRadius: BorderRadius.circular(16),
        ),
        // 高亮底是 DecoratedBox 自己画的，ListTile 的水波纹得落在它上层：
        // 中间垫一层透明 Material，否则 ListTile 会断言「背景把墨迹挡住了」
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            key: ValueKey<String>('output-device-item-$index'),
            selected: active,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: Icon(
              active ? Icons.speaker : Icons.speaker_outlined,
              size: 20,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: active ? scheme.primary : null,
              ),
            ),
            trailing: active
                ? Icon(Icons.check, size: 20, color: scheme.primary)
                : null,
            onTap: () => Navigator.of(context).pop(index),
          ),
        ),
      ),
    );
  }
}

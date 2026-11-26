import 'package:flutter/material.dart';

import '../../common/scroll/smooth_scroll.dart';
import '../../rust/api/player.dart' as rust;
import '../../theme/tokens.dart';

/// 输出设备选择弹窗。
///
/// 原来这里是右上角的小菜单（`PopupMenuButton`），和播放队列 / 睡眠定时的
/// 弹窗样式不统一；现在改成同一种 AlertDialog：图标 + 标题 + 列表，当前设备
/// 用主色底和勾选标出来，点一行即选中并关窗。
///
/// 返回值：选中的设备下标（-1 = 系统默认）；用户直接关掉时返回 `null`，
/// 调用方不要当成「选了第一项」。
///
/// `theme` 用于「正在播放页」：那一页在浅色模式下给自己套了深色前景，
/// 弹窗会跟着捕获过去；这里覆回应用级主题，弹窗与全站其余弹窗同色。
Future<int?> showOutputDeviceDialog(
  BuildContext context, {
  required List<rust.PlayerDevice> devices,
  required int selected,
  ThemeData? theme,
}) {
  return showDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) {
      final Widget dialog = _OutputDeviceDialog(
        devices: devices,
        selected: selected,
      );
      return theme == null ? dialog : Theme(data: theme, child: dialog);
    },
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
      titlePadding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.sm,
        Spacing.xs,
      ),
      contentPadding: const EdgeInsets.only(bottom: Spacing.xs),
      title: Row(
        children: <Widget>[
          const Icon(Icons.speaker_outlined, size: 22),
          const SizedBox(width: Spacing.sm),
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
            child: SmoothListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                Spacing.xs,
                Spacing.xxs,
                Spacing.xs,
                Spacing.xxs,
              ),
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
    final bool looksLikeHeadphones = _isHeadphoneName(name);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active
              // 选中底与播放队列同一套：次色容器，和主色的图标错开
              ? scheme.secondaryContainer.withValues(alpha: 0.7)
              : null,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        // 高亮底是 DecoratedBox 自己画的，ListTile 的水波纹得落在它上层：
        // 中间垫一层透明 Material，否则 ListTile 会断言「背景把墨迹挡住了」
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            key: ValueKey<String>('output-device-item-$index'),
            selected: active,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            // 耳机类设备单独给一个耳机字形，其余（扬声器 / 声卡 / 系统默认）
            // 仍用音箱：原来那条「音箱柜子」对耳机端点确实不像，但换成清一色
            // 耳机又会让「这是台扬声器」的信息丢掉
            leading: Icon(
              looksLikeHeadphones
                  ? (active ? Icons.headphones : Icons.headphones_outlined)
                  : (active ? Icons.speaker : Icons.speaker_outlined),
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

/// 设备名看起来是不是耳机类。
///
/// 只能按名字猜：`BASS_DEVICEINFO` 里没有可靠的「设备类型」字段，
/// `PlayerDevice` 也只带了 index / name / isDefault，所以从名字里找词。
/// 猜错只是图标不同，不影响能不能选、选哪个。
///
/// 覆盖 Windows 上常见的几种写法：中文「耳机 / 耳麦」、英文
/// headphone(s) / headset / earphone、以及高频的型号词 AirPods / Buds。
bool _isHeadphoneName(String name) {
  final String lower = name.toLowerCase();
  const List<String> markers = <String>[
    '耳机',
    '耳機',
    '耳麦',
    '耳麥',
    'headphone',
    'headset',
    'earphone',
    'airpods',
    'buds',
  ];
  return markers.any(lower.contains);
}

import 'package:flutter/material.dart';

import '../player/equalizer.dart';
import '../settings/equalizer_page.dart';

/// 均衡器弹窗（正在播放页的入口）。
///
/// 原来这里直接 `push` 一整页，和播放队列 / 输出设备 / 睡眠定时的弹窗
/// 风格不统一；现在同一套 Dialog：图标 + 标题 + 关闭叉号，内容与设置页的
/// [EqualizerPanel] 完全一致（开关 / 预设 / 曲线 / 10 段推子）。
Future<void> showEqualizerDialog(
  BuildContext context, {
  required bool enabled,
  required List<double> gains,
  String? presetName,
  List<EqualizerPreset> customPresets = const <EqualizerPreset>[],
  void Function(bool enabled, List<double> gains, String? presetName)?
  onChanged,
  ValueChanged<List<EqualizerPreset>>? onCustomPresetsChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => _EqualizerDialog(
      enabled: enabled,
      gains: gains,
      presetName: presetName,
      customPresets: customPresets,
      onChanged: onChanged,
      onCustomPresetsChanged: onCustomPresetsChanged,
    ),
  );
}

class _EqualizerDialog extends StatelessWidget {
  const _EqualizerDialog({
    required this.enabled,
    required this.gains,
    required this.presetName,
    required this.customPresets,
    required this.onChanged,
    required this.onCustomPresetsChanged,
  });

  final bool enabled;
  final List<double> gains;
  final String? presetName;
  final List<EqualizerPreset> customPresets;
  final void Function(bool enabled, List<double> gains, String? presetName)?
  onChanged;
  final ValueChanged<List<EqualizerPreset>>? onCustomPresetsChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 推子要竖着放得下，同时不能把 560 高的最小窗口撑破
    final Size screen = MediaQuery.sizeOf(context);
    final double height = (screen.height - 120).clamp(360.0, 640.0);
    final double width = (screen.width - 96).clamp(560.0, 760.0);

    return Dialog(
      key: const ValueKey<String>('equalizer-dialog'),
      // 与设置页的均衡器页同底色，弹窗里看着是同一块面板
      backgroundColor: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 4),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.equalizer, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('均衡器', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: EqualizerPanel(
                enabled: enabled,
                gains: gains,
                presetName: presetName,
                customPresets: customPresets,
                onChanged: onChanged,
                onCustomPresetsChanged: onCustomPresetsChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

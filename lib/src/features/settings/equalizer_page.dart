import 'package:flutter/material.dart';

import '../../common/widgets/slider_semantics_scope.dart';
import '../player/equalizer.dart';

/// 均衡器独立页：开关 + 预设切换 + 10 段推子 + 自存预设。
///
/// 预设是"多套命名曲线"，与曲目无关：内置 5 套 + 用户自己命名的若干套，
/// 切换即生效，推子改动后自动退化成「自定义」。
class EqualizerPage extends StatefulWidget {
  const EqualizerPage({
    super.key,
    required this.enabled,
    required this.gains,
    this.customPresets = const <EqualizerPreset>[],
    this.presetName,
    this.onChanged,
    this.onCustomPresetsChanged,
  });

  final bool enabled;
  final List<double> gains;
  final List<EqualizerPreset> customPresets;

  /// 当前套用的预设名；null 表示手动调过
  final String? presetName;

  /// 开关 / 推子 / 选预设都会回调，`presetName` 为 null 表示自定义
  final void Function(bool enabled, List<double> gains, String? presetName)?
  onChanged;

  final ValueChanged<List<EqualizerPreset>>? onCustomPresetsChanged;

  @override
  State<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends State<EqualizerPage> {
  late List<double> _gains = normalizeEqGains(widget.gains);
  late String? _presetName = widget.presetName;
  late bool _enabled = widget.enabled;

  @override
  void didUpdateWidget(EqualizerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!sameEqGains(oldWidget.gains, widget.gains)) {
      _gains = normalizeEqGains(widget.gains);
    }
    if (oldWidget.presetName != widget.presetName) {
      _presetName = widget.presetName;
    }
    if (oldWidget.enabled != widget.enabled) {
      _enabled = widget.enabled;
    }
  }

  void _commit({bool custom = false}) {
    if (custom) {
      _presetName = null;
    }
    widget.onChanged?.call(_enabled, List<double>.of(_gains), _presetName);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      appBar: AppBar(
        title: const Text('均衡器'),
        backgroundColor: scheme.surfaceContainerLow,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          _Card(
            child: SwitchListTile(
              key: const ValueKey<String>('equalizer-enable'),
              value: _enabled,
              onChanged: widget.onChanged == null
                  ? null
                  : (bool value) {
                      setState(() => _enabled = value);
                      _commit();
                    },
              title: const Text('启用均衡器'),
              subtitle: Text(
                _enabled ? '10 段参数均衡，0 dB 为不改动' : '开启后可按频段调整音量',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              secondary: const Icon(Icons.equalizer),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(
            title: '预设',
            trailing: TextButton.icon(
              key: const ValueKey<String>('eq-save-preset'),
              onPressed: widget.onCustomPresetsChanged == null
                  ? null
                  : _savePreset,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('存为新预设'),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final EqualizerPreset preset in equalizerPresets)
                _presetChip(preset),
              for (final EqualizerPreset preset in widget.customPresets)
                _presetChip(preset, deletable: true),
            ],
          ),
          const SizedBox(height: 20),
          _SectionTitle(
            title: _presetName == null ? '自定义曲线' : '预设：$_presetName',
          ),
          const SizedBox(height: 4),
          _Card(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 280,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int index = 0; index < _gains.length; index += 1)
                        _bandColumn(context, index),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey<String>('eq-reset'),
                    onPressed: isEqFlat(_gains) ? null : _resetToFlat,
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('全部归零'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _presetChip(EqualizerPreset preset, {bool deletable = false}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool selected = sameEqGains(_gains, preset.gains);

    return InputChip(
      key: ValueKey<String>('eq-preset-${preset.name}'),
      label: Text(preset.name),
      selected: selected,
      showCheckmark: false,
      selectedColor: scheme.primaryContainer,
      onPressed: widget.onChanged == null
          ? null
          : () {
              setState(() {
                _gains = normalizeEqGains(preset.gains);
                _presetName = preset.name;
              });
              _commit();
            },
      onDeleted: deletable && widget.onCustomPresetsChanged != null
          ? () => _deletePreset(preset)
          : null,
      deleteIcon: const Icon(Icons.close, size: 16),
    );
  }

  /// 单根竖推子：上面增益读数、中间旋转 270° 的滑块、下面频率标签。
  ///
  /// Flutter 没有竖向 Slider，`RotatedBox` 反转后「向上 = 增益变大」。
  Widget _bandColumn(BuildContext context, int index) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double gain = _gains[index];
    final int rounded = gain.round();
    final bool boosted = rounded != 0;

    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            rounded == 0 ? '0' : (rounded > 0 ? '+$rounded' : '$rounded'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: boosted ? scheme.primary : scheme.onSurfaceVariant,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: SliderSemanticsScope(
                  child: Slider(
                    key: ValueKey<String>('eq-band-$index'),
                    value: gain,
                    min: -equalizerMaxGain,
                    max: equalizerMaxGain,
                    divisions: (equalizerMaxGain * 2).round(),
                    onChanged: widget.onChanged == null
                        ? null
                        : (double value) =>
                              setState(() => _gains[index] = value),
                    onChangeEnd: (_) => _commit(custom: true),
                  ),
                ),
              ),
            ),
          ),
          Text(
            equalizerBandLabels[index],
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _resetToFlat() {
    setState(() {
      _gains = normalizeEqGains(const <double>[]);
      _presetName = null;
    });
    _commit();
  }

  Future<void> _savePreset() async {
    final String? name = await _promptPresetName();
    if (name == null || !mounted) {
      return;
    }
    final List<EqualizerPreset> next = <EqualizerPreset>[
      ...widget.customPresets.where(
        (EqualizerPreset preset) => preset.name != name,
      ),
      EqualizerPreset(name, normalizeEqGains(_gains)),
    ];
    setState(() => _presetName = name);
    widget.onCustomPresetsChanged!(next);
    widget.onChanged?.call(widget.enabled, List<double>.of(_gains), name);
  }

  Future<void> _deletePreset(EqualizerPreset preset) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除预设'),
        content: Text('确定删除「${preset.name}」吗？当前曲线不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    widget.onCustomPresetsChanged!(
      widget.customPresets
          .where((EqualizerPreset item) => item.name != preset.name)
          .toList(growable: false),
    );
  }

  Future<String?> _promptPresetName() async {
    String typed = '';
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('存为新预设'),
        content: TextField(
          key: const ValueKey<String>('eq-preset-name'),
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '预设名称',
            hintText: '例如：夜间人声',
          ),
          onChanged: (String value) => typed = value,
          onSubmitted: (String value) =>
              Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(typed.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) {
      return null;
    }
    return result;
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.primary,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

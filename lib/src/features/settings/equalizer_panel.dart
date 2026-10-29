import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/widgets/slider_semantics_scope.dart';
import '../../common/widgets/wheel_step.dart';
import '../player/equalizer.dart';
import 'equalizer_curve.dart';

/// 均衡器面板：开关 + 预设切换 + 10 段推子 + 自存预设。
///
/// 设置页与正在播放页都通过 `showEqualizerDialog` 打开同一个弹窗，本文件只
/// 提供面板本身，外壳（标题 + 关闭按钮）在 `player/equalizer_dialog.dart`。
///
/// 预设是"多套命名曲线"，与曲目无关：内置 5 套 + 用户自己命名的若干套，
/// 切换即生效，推子改动后自动退化成「自定义」。
class EqualizerPanel extends StatefulWidget {
  const EqualizerPanel({
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
  State<EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<EqualizerPanel> {
  late List<double> _gains = normalizeEqGains(widget.gains);

  /// 滚轮连续滚动时的下发合并计时器
  Timer? _wheelCommit;
  late String? _presetName = widget.presetName;
  late bool _enabled = widget.enabled;

  @override
  void didUpdateWidget(EqualizerPanel oldWidget) {
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

  @override
  void dispose() {
    // 关页时把还没下发的滚轮改动补上，否则引擎里留的是旧曲线
    if (_wheelCommit?.isActive ?? false) {
      _wheelCommit!.cancel();
      widget.onChanged?.call(_enabled, List<double>.of(_gains), null);
    }
    super.dispose();
  }

  void _commit({bool custom = false}) {
    if (custom) {
      _presetName = null;
    }
    widget.onChanged?.call(_enabled, List<double>.of(_gains), _presetName);
  }

  @override
  Widget build(BuildContext context) {
    // 不滚动：窗口最小高度 560 时页面也摆得下，滚轮就能专心留给推子。
    // 高度再小（极端小窗）才退回滚动，并且滚轮已由 PointerSignalResolver
    // 抢在 Scrollable 之前，调推子不会顺带滚页面。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool tooShort = constraints.maxHeight < 460;
        final Widget content = Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _pageColumn(context, compact: constraints.maxHeight < 620),
        );
        if (!tooShort) {
          return content;
        }
        return SingleChildScrollView(
          child: SizedBox(height: 460, child: content),
        );
      },
    );
  }

  /// 标题行里的操作按钮：默认 48 高太占地方，压到 32
  static final ButtonStyle _compactAction = TextButton.styleFrom(
    minimumSize: const Size(0, 32),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );

  /// 页面主体：开关 / 预设 / 曲线三段固定，推子吃掉剩余高度。
  ///
  /// 原来整页是 ListView + 固定 280 高的推子，最小窗口下必须滚动；
  /// 滚轮落在推子上时页面跟着滚，两个动作打架。
  Widget _pageColumn(BuildContext context, {required bool compact}) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            secondary: const Icon(Icons.equalizer),
            // 单行紧凑排布：最小窗口（900×560）下推子才留得够长
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        const SizedBox(height: 8),
        _SectionTitle(
          title: '预设',
          trailing: TextButton.icon(
            key: const ValueKey<String>('eq-save-preset'),
            style: _compactAction,
            onPressed: widget.onCustomPresetsChanged == null
                ? null
                : _savePreset,
            icon: const Icon(Icons.add, size: 16),
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
        const SizedBox(height: 8),
        // 高度紧张时曲线自己缩一点，把空间让给推子
        _Card(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: EqualizerCurveChart(
            gains: _gains,
            curveHeight: compact ? 76 : 132,
          ),
        ),
        const SizedBox(height: 8),
        _SectionTitle(
          title: _presetName == null ? '自定义曲线' : '预设：$_presetName',
          trailing: TextButton.icon(
            key: const ValueKey<String>('eq-reset'),
            style: _compactAction,
            onPressed: isEqFlat(_gains) ? null : _resetToFlat,
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('全部归零'),
          ),
        ),
        Expanded(
          child: _Card(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int index = 0; index < _gains.length; index += 1)
                  _bandColumn(context, index),
              ],
            ),
          ),
        ),
      ],
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
  ///
  /// 推子的矩形只留中线 28px：Slider 自带的鼠标光标（手型）会铺满整个控件，
  /// 若让它吃满列宽，鼠标还在两侧空白处就会显示成可拖动，观感上像整列都能拉。
  /// 滚轮感应区正好也是这一条（`WheelStep` 包在同一层）。
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
          const SizedBox(height: 2),
          Expanded(
            child: Center(
              child: SizedBox(
                width: 28,
                child: WheelStep(
                  // 滚轮一格 1 dB，与 Slider 的 divisions 对齐
                  onStep: (int direction) => _nudgeBand(index, direction),
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
              ),
            ),
          ),
          const SizedBox(height: 2),
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

  /// 滚轮一格 = 1 dB（推手拖拽仍按 divisions 细调）
  void _nudgeBand(int index, int direction) {
    // 均衡器关闭 / 引擎不可用时推子本来就不可拖，滚轮也不该动
    if (widget.onChanged == null) {
      return;
    }
    final double next = (_gains[index] + direction).clamp(
      -equalizerMaxGain,
      equalizerMaxGain,
    );
    if (next == _gains[index]) {
      return;
    }
    setState(() => _gains[index] = next);
    // 连续滚动时合并下发：每格都写一次会话 + 一次 FFI 太浪费
    _wheelCommit?.cancel();
    _wheelCommit = Timer(const Duration(milliseconds: 120), () {
      if (mounted) {
        _commit(custom: true);
      }
    });
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
        // 与设置页卡片同一档（28 留给弹窗）
        borderRadius: BorderRadius.circular(32),
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
      // 左边距与卡片内容对齐（页面 16 + 卡片内边距 12）
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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

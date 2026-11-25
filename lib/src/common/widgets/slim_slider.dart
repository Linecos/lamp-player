import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/material.dart';

import 'slider_semantics_scope.dart';
import '../../theme/tokens.dart';

class SlimSlider extends StatefulWidget {
  const SlimSlider({
    super.key,
    required this.value,
    required this.max,
    required this.enabled,
    this.sliderKey,
    this.label,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
    this.tipBuilder,
  });

  final double value;
  final double max;
  final bool enabled;

  /// 挂在内层 `Slider` 上的 key：外部要按 key 取 `Slider` / 量矩形时用
  final Key? sliderKey;

  /// 只喂给 `Slider` 的无障碍值与内部指示器，不直接显示
  final String? label;

  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// 把「滑块位置对应的数值」转成气泡文案；为空则不画气泡
  final String Function(double value)? tipBuilder;

  @override
  State<SlimSlider> createState() => _SlimSliderState();
}

class _SlimSliderState extends State<SlimSlider> {
  /// 鼠标在轨道上的相对位置（0..1），离开就清掉
  double? _hoverFraction;
  bool _dragging = false;

  void _setHover(double fraction) {
    if (widget.tipBuilder == null || fraction == _hoverFraction) {
      return;
    }
    setState(() => _hoverFraction = fraction);
  }

  void _clearHover() {
    if (_hoverFraction == null) {
      return;
    }
    setState(() => _hoverFraction = null);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SliderThemeData base = SliderTheme.of(context);
    final String Function(double value)? tipBuilder = widget.tipBuilder;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        // 拖动时跟着拇指（真实数值），静止时跟鼠标；两者都没有就不画
        final double? at = _dragging
            ? (widget.value.clamp(0.0, widget.max) / widget.max)
            : _hoverFraction;
        final double? fraction =
            (at != null &&
                tipBuilder != null &&
                widget.enabled &&
                widget.max > 0)
            ? at
            : null;

        return MouseRegion(
          // 只用来清悬停：指针离开这块区域时收气泡
          onExit: (_) {
            if (!_dragging) {
              _clearHover();
            }
          },
          child: Listener(
            onPointerHover: (PointerHoverEvent event) {
              if (width <= 0 || _dragging) {
                return;
              }
              final double dx = event.localPosition.dx;
              if (dx < 0 || dx > width) {
                _clearHover();
                return;
              }
              _setHover((dx / width).clamp(0.0, 1.0));
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                SliderTheme(
                  data: base.copyWith(
                    trackHeight: 4,
                    activeTrackColor: scheme.primary,
                    inactiveTrackColor: scheme.surfaceContainerHighest,
                    disabledActiveTrackColor: scheme.outlineVariant,
                    disabledInactiveTrackColor: scheme.surfaceContainerHighest,
                    thumbColor: scheme.primary,
                    disabledThumbColor: scheme.outline,
                    overlayColor: scheme.primary.withValues(alpha: 0.12),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                      disabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    trackShape: const RoundedRectSliderTrackShape(),
                    // 气泡由本组件自己画，关掉框架的 value indicator
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: SliderSemanticsScope(
                    child: Slider(
                      key: widget.sliderKey,
                      label: widget.label,
                      value: widget.value.clamp(0.0, widget.max).toDouble(),
                      max: widget.max,
                      onChangeStart: widget.enabled
                          ? (double value) {
                              // 按下那一刻先把悬停位置清掉：拖完松手若还留着
                              // 它就退回旧位置，气泡看着像「停在原地没走」
                              setState(() {
                                _dragging = true;
                                _hoverFraction = null;
                              });
                              widget.onChangeStart?.call(value);
                            }
                          : null,
                      onChanged: widget.enabled ? widget.onChanged : null,
                      onChangeEnd: widget.enabled
                          ? (double value) {
                              // 松手就收气泡：下一次悬停再按新的鼠标位置出
                              setState(() {
                                _dragging = false;
                                _hoverFraction = null;
                              });
                              widget.onChangeEnd?.call(value);
                            }
                          : null,
                    ),
                  ),
                ),
                if (fraction != null)
                  // Stack 顶部再往上 26：气泡整个落在区域外，不挡轨道也不挡拇指
                  Positioned(
                    top: -26,
                    left: fraction * width,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, 0),
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: _SeekTip(
                            text: tipBuilder!(fraction * widget.max),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 进度条上的时间气泡：深底浅字、带一点阴影，不抢歌词 / 频谱的注意力
class _SeekTip extends StatelessWidget {
  const _SeekTip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.xs),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: Spacing.xxs,
        ),
        child: Text(
          text,
          maxLines: 1,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurface,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

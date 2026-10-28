import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 正在播放页的封面取色背景。
///
/// 用封面色板画三层柔和的径向渐变，再盖一层与主题同色的半透明 scrim。
/// 第二版开始缓慢漂移：动画只让 [CustomPainter] 重绘，不重建歌词与控件；
/// 测试 / golden 可通过 [animate] 关闭。
class CoverFlowBackground extends StatefulWidget {
  const CoverFlowBackground({
    super.key,
    required this.colors,
    required this.child,
    this.animate = true,
  });

  /// 封面主色；为空时用主题 primary / tertiary / secondary 兜底。
  final List<Color>? colors;
  final Widget child;
  final bool animate;

  @override
  State<CoverFlowBackground> createState() => _CoverFlowBackgroundState();
}

class _CoverFlowBackgroundState extends State<CoverFlowBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(CoverFlowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final bool shouldAnimate = widget.animate && !_reduceMotion;
    if (shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 背景色板与深浅色主题解耦：浅色模式也保持同一套深色高饱和配色
    final List<Color> palette = harmonizeCoverColors(
      widget.colors ??
          <Color>[scheme.primary, scheme.tertiary, scheme.secondary],
    );
    final bool animating = widget.animate && !_reduceMotion;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuraPainter(
              colors: palette,
              surface: Color.lerp(palette[1], Colors.black, 0.55)!,
              animation: animating ? _controller : null,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        // 保证歌词与文字在任何封面色上都可读；沉浸模式下也不会被亮斑吃掉
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Colors.black.withValues(alpha: 0.0),
                  Colors.black.withValues(alpha: 0.16),
                ],
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// 按封面的面积占比排主色/副色，并保留色相差异较大的颜色。
///
/// 输入颜色已按桶面积从大到小排序。第一色作为主色，决定大面积背景；
/// 后续只接受色相距离 > 32° 的颜色，避免同一色相堆满，也避免小面积高饱和色
/// 把大面积主色挤掉（黄底 + 小面积绿衣、蓝衣 + 草地/天空等）。
List<Color> harmonizeCoverColors(List<Color> source) {
  if (source.isEmpty) {
    return const <Color>[];
  }
  final List<HSLColor> usable = source
      .map(HSLColor.fromColor)
      .where(_usable)
      .toList();
  final List<HSLColor> pool = usable.isEmpty
      ? source.map(HSLColor.fromColor).toList()
      : usable;

  final List<HSLColor> selected = <HSLColor>[];
  for (final HSLColor candidate in pool) {
    if (selected.length >= 3) {
      break;
    }
    if (selected.every(
      (HSLColor existing) => _hueDistance(existing.hue, candidate.hue) > 32,
    )) {
      selected.add(candidate);
    }
  }
  final HSLColor primary = selected.first;
  while (selected.length < 4) {
    final double delta = selected.length.isEven ? 0.12 : -0.1;
    selected.add(
      primary.withLightness(
        (primary.lightness + delta).clamp(0.16, 0.72).toDouble(),
      ),
    );
  }

  const List<double> targets = <double>[0.17, 0.15, 0.17, 0.14];
  return <Color>[
    for (int i = 0; i < 4; i += 1)
      _liftLuminance(
        selected[i].withSaturation(
          selected[i].saturation.clamp(0.45, 0.95).toDouble(),
        ),
        targets[i],
      ).toColor(),
  ];
}

bool _usable(HSLColor color) {
  return color.saturation > 0.1 &&
      color.lightness > 0.06 &&
      color.lightness < 0.94;
}

HSLColor _liftLuminance(HSLColor color, double target) {
  HSLColor result = color;
  while (result.toColor().computeLuminance() < target &&
      result.lightness < 0.78) {
    result = result.withLightness(result.lightness + 0.02);
  }
  return result;
}

double _hueDistance(double a, double b) {
  final double diff = (a - b).abs() % 360;
  return diff > 180 ? 360 - diff : diff;
}

class _AuraPainter extends CustomPainter {
  _AuraPainter({required this.colors, required this.surface, this.animation})
    : super(repaint: animation);

  final List<Color> colors;
  final Color surface;

  /// 为空时画静态帧；非空时由它驱动重绘。
  final Animation<double>? animation;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = surface);

    final double t = animation?.value ?? 0;
    final double angle = t * math.pi * 2;

    Offset drift(
      double x,
      double y,
      double phase,
      double amplitudeX,
      double amplitudeY,
    ) {
      return Offset(
        size.width * x + math.sin(angle + phase) * size.width * amplitudeX,
        size.height * y + math.cos(angle + phase) * size.height * amplitudeY,
      );
    }

    void spot(Offset center, double radius, Color color, double alpha) {
      final Paint paint = Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, paint);
    }

    spot(
      drift(0.76, 0.3, 0, 0.13, 0.1),
      size.width * 0.82 * (1 + 0.1 * math.sin(angle)),
      _flowColor(colors[0], 0, angle),
      0.9 + 0.06 * math.cos(angle),
    );
    spot(
      drift(0.08, 0.82, 1.7, 0.12, 0.12),
      size.width * 0.58 * (1 + 0.1 * math.cos(angle + 1.2)),
      _flowColor(colors[1], 1.2, angle),
      0.64 + 0.06 * math.sin(angle + 1.2),
    );
    spot(
      drift(0.9, 0.9, 3.1, 0.1, 0.1),
      size.width * 0.48 * (1 + 0.1 * math.sin(angle + 2.4)),
      _flowColor(colors[2], 2.4, angle),
      0.48 + 0.06 * math.cos(angle + 2.4),
    );
    spot(
      drift(0.12, 0.1, 4.6, 0.1, 0.1),
      size.width * 0.42 * (1 + 0.1 * math.cos(angle + 3.3)),
      _flowColor(colors[3], 3.3, angle),
      0.36 + 0.06 * math.sin(angle + 3.3),
    );
  }

  Color _flowColor(Color color, double phase, double angle) {
    final HSLColor hsl = HSLColor.fromColor(color);
    return hsl.withHue((hsl.hue + 7 * math.sin(angle + phase)) % 360).toColor();
  }

  @override
  bool shouldRepaint(covariant _AuraPainter oldDelegate) {
    return !listEquals(oldDelegate.colors, colors) ||
        oldDelegate.surface != surface ||
        oldDelegate.animation != animation;
  }
}

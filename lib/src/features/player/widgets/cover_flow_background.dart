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

/// 以封面中「最鲜艳」的颜色为基准，并取一个色相距离较远的颜色做对比色。
///
/// 输出顺序固定为：对比色亮 / 对比色暗 / 主色亮 / 主色暗，
/// 画面上分别落在左侧和右侧，中间留出暗底，避免整屏均匀一片。
List<Color> harmonizeCoverColors(List<Color> source) {
  final List<HSLColor> sorted = source.map(HSLColor.fromColor).toList()
    ..sort((HSLColor a, HSLColor b) => _vibrancy(b).compareTo(_vibrancy(a)));
  final HSLColor base = sorted.first;

  HSLColor? accent;
  for (final HSLColor candidate in sorted.skip(1)) {
    final double distance = _hueDistance(candidate.hue, base.hue);
    if (candidate.saturation > 0.4 &&
        _vibrancy(candidate) > 0.2 &&
        distance > 50) {
      accent = candidate;
      break;
    }
  }
  final double accentHue = accent?.hue ?? (base.hue + 45) % 360;
  final double accentSaturation =
      accent?.saturation.clamp(0.55, 0.9).toDouble() ?? 0.72;
  final double baseSaturation = base.saturation.clamp(0.6, 0.9).toDouble();

  final List<(double hue, double saturation, double lightness, double target)>
  specs = <(double, double, double, double)>[
    (accentHue - 12, accentSaturation, 0.38, 0.17),
    (accentHue + 24, accentSaturation, 0.3, 0.14),
    (base.hue, baseSaturation, 0.36, 0.18),
    (base.hue + 20, baseSaturation, 0.28, 0.15),
  ];

  return <Color>[
    for (final (double hue, double saturation, double lightness, double target)
        in specs)
      _liftLuminance(
        HSLColor.fromAHSL(1, hue % 360, saturation, lightness),
        target,
      ).toColor(),
  ];
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

double _vibrancy(HSLColor color) {
  // 中间亮度、高饱和优先；纯黑/纯白几乎不会被选中
  final double midWeight = 1 - (color.lightness - 0.5).abs() * 1.6;
  return color.saturation * midWeight.clamp(0.0, 1.0);
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
      drift(0.1, 0.12, 0, 0.15, 0.1),
      size.width * 0.6 * (1 + 0.1 * math.sin(angle)),
      _flowColor(colors[0], 0, angle),
      0.9 + 0.06 * math.cos(angle),
    );
    spot(
      drift(0.03, 0.9, 1.7, 0.12, 0.12),
      size.width * 0.54 * (1 + 0.1 * math.cos(angle + 1.2)),
      _flowColor(colors[1], 1.2, angle),
      0.8 + 0.06 * math.sin(angle + 1.2),
    );
    spot(
      drift(0.9, 0.15, 3.1, 0.15, 0.1),
      size.width * 0.6 * (1 + 0.1 * math.sin(angle + 2.4)),
      _flowColor(colors[2], 2.4, angle),
      0.9 + 0.06 * math.cos(angle + 2.4),
    );
    spot(
      drift(0.96, 0.8, 4.6, 0.12, 0.12),
      size.width * 0.56 * (1 + 0.1 * math.cos(angle + 3.3)),
      _flowColor(colors[3], 3.3, angle),
      0.8 + 0.06 * math.sin(angle + 3.3),
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

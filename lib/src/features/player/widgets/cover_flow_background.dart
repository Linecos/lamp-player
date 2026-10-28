import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 正在播放页的封面取色背景。
///
/// 用封面色板画几层柔和的径向渐变，再盖一层与主题同色的半透明 scrim。
/// 每个色块沿固定方向匀速穿过画面（[sweep]），看起来是「光在流」而不是
/// 「色块在原地呼吸」；动画只让 [CustomPainter] 重绘，不重建歌词与控件；
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
  /// 一个完整循环的时长。
  ///
  /// 只走单向、不 `reverse`：反向播放会让光斑原路退回，看起来是
  /// 「一呼一吸」而不是「流动」。12 秒扫过一整屏约 160 px/s，
  /// 9 秒时偏快、20 秒以上大屏上几乎看不出位移。
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
        _controller.repeat();
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

/// 0 → 1 的平滑过渡（首尾导数为 0）。
double _smoothstep(double edge0, double edge1, double x) {
  final double v = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return v * v * (3 - 2 * v);
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

    void spot(Offset center, double radius, Color color, double alpha) {
      final Paint paint = Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            color.withValues(alpha: alpha.clamp(0.0, 1.0)),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, paint);
    }

    /// 静态底：不随动画变。
    ///
    /// 既决定整页的色调（关闭流光时也靠它），也保证某块流动光刚好淡出时
    /// 背景不会塌成一片近黑。
    spot(
      Offset(size.width * 0.7, size.height * 0.25),
      size.width * 0.95,
      colors[0],
      0.72,
    );
    spot(
      Offset(size.width * 0.12, size.height * 0.85),
      size.width * 0.75,
      colors[1],
      0.5,
    );
    spot(
      Offset(size.width * 0.9, size.height * 0.9),
      size.width * 0.55,
      colors[2],
      0.36,
    );

    /// 一块光沿一条直线匀速穿过画面，到头从另一侧再来。
    ///
    /// 之前是正弦往返：光斑走到底再原路退回，四个斑再怎么错开相位，整体
    /// 观感都是「一起胀缩 / 呼吸」。改成单向匀速穿屏后运动有了方向，才读得
    /// 出「流光」。
    ///
    /// [laps] 是每个循环穿几次（整数，保证循环首尾对齐）；两端用
    /// smoothstep 淡入淡出，换边时不会突然冒出一块光。
    void sweep({
      required double fromX,
      required double fromY,
      required double toX,
      required double toY,
      required double phase,
      required int laps,
      required double radius,
      required double alpha,
      required Color color,
      required double wobble,
    }) {
      final double p = (t * laps + phase) % 1.0;
      final double fade =
          _smoothstep(0, 0.12, p) * (1 - _smoothstep(0.88, 1, p));
      if (fade <= 0.002) {
        return;
      }
      final double x = fromX + (toX - fromX) * p;
      final double y = fromY + (toY - fromY) * p;
      // 垂直于行进方向的一点摆动，避免看起来像一块平移的贴图
      final double sway = math.sin(angle * laps + phase * math.pi * 2) * wobble;
      spot(
        Offset(size.width * x, size.height * (y + sway)),
        size.width * radius * (1 + 0.08 * math.sin(angle * 2 + phase * 6)),
        _flowColor(color, phase * math.pi * 2, angle, 14, laps),
        alpha * fade,
      );
    }

    sweep(
      fromX: -0.15,
      fromY: 0.12,
      toX: 1.15,
      toY: 0.78,
      phase: 0.5,
      laps: 1,
      radius: 0.72,
      alpha: 0.8,
      color: colors[0],
      wobble: 0.03,
    );
    sweep(
      fromX: 1.15,
      fromY: 0.88,
      toX: -0.15,
      toY: 0.22,
      phase: 0.72,
      laps: 1,
      radius: 0.52,
      alpha: 0.6,
      color: colors[1],
      wobble: 0.035,
    );
    sweep(
      fromX: -0.2,
      fromY: 0.92,
      toX: 1.2,
      toY: 0.18,
      phase: 0.06,
      laps: 2,
      radius: 0.42,
      alpha: 0.45,
      color: colors[2],
      wobble: 0.03,
    );
    sweep(
      fromX: 1.2,
      fromY: 0.05,
      toX: -0.2,
      toY: 0.82,
      phase: 0.28,
      laps: 2,
      radius: 0.36,
      alpha: 0.38,
      color: colors[3],
      wobble: 0.035,
    );
  }

  /// 色相也按各自节奏摆动：四个斑同频变色同样会显得「整块一起呼吸」。
  Color _flowColor(
    Color color,
    double phase,
    double angle,
    double hueAmp,
    int rate,
  ) {
    final HSLColor hsl = HSLColor.fromColor(color);
    return hsl
        .withHue((hsl.hue + hueAmp * math.sin(angle * rate + phase)) % 360)
        .toColor();
  }

  @override
  bool shouldRepaint(covariant _AuraPainter oldDelegate) {
    return !listEquals(oldDelegate.colors, colors) ||
        oldDelegate.surface != surface ||
        oldDelegate.animation != animation;
  }
}

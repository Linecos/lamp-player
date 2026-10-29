import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 正在播放页底部的柱形频谱：一排细柱，随音乐实时起伏。
///
/// 设计取舍：
/// * **完全由数据驱动**——没有额外的位移动画。柱子高度就是当前帧的幅度，
///   音乐停在哪里柱子就停在哪里。前一版加了相位漂移，安静时也在动，
///   看起来像「装饰动画」而不是频谱，这里不再有那层；
/// * **铺满全宽**——24 段频谱按 Catmull-Rom 插值重采样成宽度允许的柱数
///   （1280 宽约 200 根），原来的定宽柱子模式最多只占屏幕左边 2/3；
/// * **色彩**——每根柱子按横向位置在 `color → colorMid → colorEnd` 之间取色，
///   越高的柱子越亮，整排看过去是一条色相渐变的墙；
/// * **尺度**——整块只有 [height] 高（默认 72），柱子最高 [maxBarHeight]，
///   贴着控制区上方，不抢歌词的视线；
/// * **只做背景**——内部 `IgnorePointer` 不吃手势，也不占布局高度
///   （调用方用 `Stack` 铺满），歌词照常滚动。
class SpectrumWave extends StatelessWidget {
  const SpectrumWave({
    super.key,
    required this.bands,
    this.color,
    this.colorMid,
    this.colorEnd,
    this.height = 72,
    this.maxBarHeight = 64,
    this.intensity = 1,
  });

  /// 各段幅度（0~1）；空列表表示没在放歌，整排淡出
  final ValueListenable<List<double>> bands;

  /// 左端色；默认取主题主色
  final Color? color;

  /// 中段色；默认由 [color] 的色相 +40° 派生
  final Color? colorMid;

  /// 右端色；默认由 [color] 的色相 +90° 派生
  final Color? colorEnd;

  /// 整块高度
  final double height;

  /// 柱子最大高度
  final double maxBarHeight;

  /// 整体不透明度系数（0~1）
  final double intensity;

  /// 同亮度、同饱和度地旋转色相
  static Color _rotate(Color color, double degrees) {
    final HSLColor hsl = HSLColor.fromColor(color);
    return hsl
        .withHue((hsl.hue + degrees) % 360)
        .withSaturation(hsl.saturation.clamp(0.55, 1.0))
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    final Color left = color ?? Theme.of(context).colorScheme.primary;
    // 色相按 0° / +40° / +90° 推开：三色跨度够大才有渐变感，
    // 直接用主题的 primary/tertiary/secondary 常常撞在同一个色相上
    final Color mid = colorMid ?? _rotate(left, 40);
    final Color right = colorEnd ?? _rotate(left, 90);
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: RepaintBoundary(
            child: ValueListenableBuilder<List<double>>(
              valueListenable: bands,
              builder: (BuildContext context, List<double> values, Widget? _) {
                // 暂停时数据源会清空：整排淡出，而不是「冻住一帧」
                return AnimatedOpacity(
                  opacity: values.isEmpty ? 0 : 1,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _BarsPainter(
                      values: values,
                      colors: <Color>[left, mid, right],
                      maxBarHeight: maxBarHeight,
                      intensity: intensity,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.colors,
    required this.maxBarHeight,
    required this.intensity,
  });

  final List<double> values;
  final List<Color> colors;
  final double maxBarHeight;
  final double intensity;

  /// 柱宽与间隙（逻辑像素）：4.5 + 4.5 在 1280 宽下约 142 根。
  /// 再密就糊成一片「草」，看不出是一根根柱子
  static const double _barWidth = 4.5;
  static const double _gap = 4.5;

  /// 静音时也留一线，柱子「在不在」看得出来
  static const double _minBar = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width < 4 || size.height < 4) {
      return;
    }
    final double strength = intensity.clamp(0.0, 1.0);
    if (strength <= 0) {
      return;
    }
    final double step = _barWidth + _gap;
    final int count = (size.width / step).ceil().clamp(4, 512);
    // 按实际柱数反算柱宽：柱子刚好铺满整宽，右侧不会留一条缝
    final double bar = math.max(1.0, (size.width - _gap * (count - 1)) / count);
    final double maxHeight = math.min(maxBarHeight, size.height);
    final int last = values.length - 1;
    final Paint paint = Paint()..isAntiAlias = true;

    for (int i = 0; i < count; i += 1) {
      final double t = count == 1 ? 0 : i / (count - 1);
      final double value = _sample(last * t).clamp(0.0, 1.0);
      // 中部权重：两端收到 30%，变化集中在屏幕中间，看起来更聚拢
      final double weight = 0.30 + 0.70 * math.sin(math.pi * t);
      final double height = math.max(
        _minBar,
        maxHeight * math.pow(value, 1.1).toDouble() * weight,
      );
      final double x = i * (bar + _gap);
      final Color base = _tint(t);
      // 两端 6% 内淡出。以前是整排 `saveLayer` + 渐变 mask 再 `dstIn`，
      // 每帧都要开一张离屏图层、建一个线性渐变着色器；直接把系数乘进
      // 每根柱子的 alpha，效果一样，代价只剩一次乘法。
      final double fade = _edgeFade(t);
      // 越高的柱子越亮：安静的段落整排淡下去，鼓点一敲就亮起来
      final double alpha = (0.26 + 0.40 * value) * strength * fade;
      final double top = size.height - height;
      paint.color = base.withValues(alpha: alpha);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, bar, height),
          Radius.circular(bar / 2),
        ),
        paint,
      );
      // 柱顶压一小段更亮的块：一排亮顶比整根纯色更有「频谱」的力量感
      if (height > 3) {
        paint.color = base.withValues(alpha: math.min(1.0, alpha * 1.45));
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, top, bar, math.min(2.2, height * 0.35)),
            Radius.circular(bar / 2),
          ),
          paint,
        );
      }
    }
  }

  /// 两端 6% 内线性淡出，中段保持 1（与原渐变 mask 的 stops 一致）
  static double _edgeFade(double t) {
    const double edge = 0.06;
    if (t < edge) {
      return t / edge;
    }
    if (t > 1 - edge) {
      return (1 - t) / edge;
    }
    return 1;
  }

  /// 横向色相：左端 → 中段 → 右端
  Color _tint(double t) {
    if (t <= 0.55) {
      return Color.lerp(colors[0], colors[1], t / 0.55)!;
    }
    return Color.lerp(colors[1], colors[2], (t - 0.55) / 0.45)!;
  }

  /// 24 段之间 Catmull-Rom 插值
  double _sample(double t) {
    final int last = values.length - 1;
    if (last <= 0) {
      return values.first;
    }
    final int index = t.floor().clamp(0, last);
    final double f = t - index;
    final double p0 = values[(index - 1).clamp(0, last)];
    final double p1 = values[index];
    final double p2 = values[(index + 1).clamp(0, last)];
    final double p3 = values[(index + 2).clamp(0, last)];
    final double value =
        0.5 *
        (2 * p1 +
            (-p0 + p2) * f +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f +
            (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f);
    return value.isFinite ? value : p1;
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) =>
      !listEquals(oldDelegate.values, values) ||
      !listEquals(oldDelegate.colors, colors) ||
      oldDelegate.maxBarHeight != maxBarHeight ||
      oldDelegate.intensity != intensity;
}

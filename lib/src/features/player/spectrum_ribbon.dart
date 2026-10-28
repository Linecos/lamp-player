import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 正在播放页底部的「音浪」：几条叠在一起的渐变光波。
///
/// 形态：3 条相位错开的平滑曲线，从左到右走 `color → colorMid → colorEnd`
/// 的色相渐变，每条先用同色描边做一层柔光、再压一根细实线；频谱数据作为
/// **振幅包络**——低频强的段落起伏大，安静段落几乎贴成直线。
///
/// 尺度：整块固定 [height] 高（默认 96），波峰最多 [amplitude]（默认 26），
/// 也就是视觉上最多占底部五十来个像素，不会变成半屏的大色块。
///
/// 相位由 [animate] 驱动缓慢漂移（14 秒一圈），即使数据帧刚好停住，波形
/// 也仍在流动；系统开了「减少动态效果」或测试里传 false 时用固定相位。
///
/// 只做背景：内部 `IgnorePointer` 不吃手势，也不占布局高度（调用方用
/// `Stack` 铺满），歌词照常滚动。
class SpectrumRibbon extends StatefulWidget {
  const SpectrumRibbon({
    super.key,
    required this.bands,
    this.color,
    this.colorMid,
    this.colorEnd,
    this.animate = true,
    this.height = 104,
    this.amplitude = 38,
    this.intensity = 1,
  });

  /// 各段幅度（0~1）；空列表表示没在放歌，整条淡出
  final ValueListenable<List<double>> bands;

  /// 左端色；默认取主题主色
  final Color? color;

  /// 中段色；默认由 [color] 的色相 +40° 派生
  final Color? colorMid;

  /// 右端色；默认由 [color] 的色相 +90° 派生
  final Color? colorEnd;

  /// 是否让相位缓慢流动
  final bool animate;

  /// 整块高度（逻辑像素）
  final double height;

  /// 波峰最大高度（会自动夹在整块高度的一半以内）
  final double amplitude;

  /// 整体不透明度系数（0~1）
  final double intensity;

  @override
  State<SpectrumRibbon> createState() => _SpectrumRibbonState();
}

class _SpectrumRibbonState extends State<SpectrumRibbon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(SpectrumRibbon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      _sync();
    }
  }

  void _sync() {
    if (widget.animate && !_reduceMotion) {
      if (!_phase.isAnimating) {
        _phase.repeat();
      }
    } else {
      _phase
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

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
    final Color left = widget.color ?? Theme.of(context).colorScheme.primary;
    // 色相按 0° / +40° / +90° 推开：三色跨度够大才有「渐变光波」的感觉，
    // 直接用主题的 primary/tertiary/secondary 常常撞在同一个色相上
    final Color mid = widget.colorMid ?? _rotate(left, 40);
    final Color right = widget.colorEnd ?? _rotate(left, 90);
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: RepaintBoundary(
            child: ValueListenableBuilder<List<double>>(
              valueListenable: widget.bands,
              builder: (BuildContext context, List<double> values, Widget? _) {
                // 暂停时数据源会清空：整条淡出，而不是「冻住一帧」
                return AnimatedOpacity(
                  opacity: values.isEmpty ? 0 : 1,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _WavePainter(
                      values: values,
                      colors: <Color>[left, mid, right],
                      amplitude: widget.amplitude,
                      intensity: widget.intensity,
                      phase: widget.animate && !_reduceMotion ? _phase : null,
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

/// 一层波形的形状与轻重
class _Layer {
  const _Layer({
    required this.cycles,
    required this.offset,
    required this.amplitudeScale,
    required this.alpha,
    required this.strokeWidth,
    required this.shift,
  });

  /// 整屏几个完整波峰
  final double cycles;

  /// 相位偏移（0~1 圈）
  final double offset;

  /// 振幅比例
  final double amplitudeScale;

  /// 实线不透明度
  final double alpha;

  final double strokeWidth;

  /// 包络的横向偏移，让三层不完全同步
  final double shift;
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.values,
    required this.colors,
    required this.amplitude,
    required this.intensity,
    required this.phase,
  }) : super(repaint: phase);

  final List<double> values;
  final List<Color> colors;
  final double amplitude;
  final double intensity;

  /// 相位来源；为空时用固定相位
  final Animation<double>? phase;

  /// 每 3px 一个采样点：1280 宽约 427 点，曲线足够顺
  static const double _step = 3;

  static const List<_Layer> _layers = <_Layer>[
    _Layer(
      cycles: 1.9,
      offset: 0,
      amplitudeScale: 1,
      alpha: 0.55,
      strokeWidth: 1.7,
      shift: 0,
    ),
    _Layer(
      cycles: 2.8,
      offset: 0.42,
      amplitudeScale: 0.72,
      alpha: 0.36,
      strokeWidth: 1.3,
      shift: 0.07,
    ),
    _Layer(
      cycles: 3.7,
      offset: 0.78,
      amplitudeScale: 0.48,
      alpha: 0.24,
      strokeWidth: 1.1,
      shift: -0.09,
    ),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width < 8 || size.height < 8) {
      return;
    }
    final double strength = intensity.clamp(0.0, 1.0);
    if (strength <= 0) {
      return;
    }
    final double centerY = size.height * 0.55;
    // 波峰最高不超过整块的四成，柔光才不会被裁掉
    final double maxAmp = math.min(amplitude, size.height * 0.4);
    final int columns = (size.width / _step).ceil().clamp(32, 640);
    final Rect rect = Offset.zero & size;
    // 透明度必须烤进 shader：Paint 上同时给了 shader 和 color 时，shader 说了算
    Shader gradient(double alpha) => LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: <Color>[
        for (final Color color in colors) color.withValues(alpha: alpha),
      ],
      stops: const <double>[0, 0.55, 1],
    ).createShader(rect);
    final double turn = phase?.value ?? 0;

    canvas.saveLayer(rect, Paint());
    for (final _Layer layer in _layers) {
      final Path path = Path();
      for (int i = 0; i <= columns; i += 1) {
        final double t = i / columns;
        final double envelope = _envelope((t + layer.shift).clamp(0.0, 1.0));
        final double wave = math.sin(
          2 * math.pi * (layer.cycles * t + turn + layer.offset),
        );
        final double y =
            centerY +
            maxAmp * layer.amplitudeScale * (0.22 + 0.78 * envelope) * wave;
        if (i == 0) {
          path.moveTo(0, y);
        } else {
          path.lineTo(t * size.width, y);
        }
      }
      // 一条波画三层：宽而淡的柔光、中等宽度的带状底色、细亮的核心线。
      // 这样才是「有厚度的光带」，只画一根 1px 线会像心电图
      for (final (double widthScale, double alphaScale, double blur)
          in <(double, double, double)>[
            (7.0, 0.10, 5),
            (2.6, 0.30, 2),
            (1.0, 1.0, 0),
          ]) {
        canvas.drawPath(
          path,
          Paint()
            ..isAntiAlias = true
            ..style = PaintingStyle.stroke
            ..strokeWidth = layer.strokeWidth * widthScale
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..shader = gradient(layer.alpha * alphaScale * strength)
            ..maskFilter = blur == 0
                ? null
                : MaskFilter.blur(BlurStyle.normal, blur),
        );
      }
    }
    // 两端渐隐，全宽铺开时不会出现硬切边
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          colors: <Color>[
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: <double>[0, 0.09, 0.91, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  /// 频谱包络：24 段之间 Catmull-Rom 插值，映射到 0~1
  double _envelope(double t) {
    final int last = values.length - 1;
    if (last <= 0) {
      return values.first.clamp(0.0, 1.0);
    }
    final double position = last * t;
    final int index = position.floor().clamp(0, last);
    final double f = position - index;
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
    return (value.isFinite ? value : p1).clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      !identical(oldDelegate.values, values) ||
      !listEquals(oldDelegate.colors, colors) ||
      oldDelegate.amplitude != amplitude ||
      oldDelegate.intensity != intensity ||
      oldDelegate.phase != phase;
}

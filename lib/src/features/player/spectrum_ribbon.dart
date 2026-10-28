import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 正在播放页底部的「音浪」：贴着页面底边、铺满整宽的一条低矮波形。
///
/// 设计取舍：
/// * **只占底部一条**——最高 [maxHeight]（默认 10% 屏高、封顶 [maxPixelHeight]），
///   波峰落在歌词下方，不跟歌词抢视线；
/// * **铺满全宽**——24 段频谱按 Catmull-Rom 插值重采样到整宽，
///   原来的定宽柱子模式最多只占屏幕左边 2/3；
/// * **两层轮廓**——主浪后面垫一条更矮、更平滑、色相偏冷的副浪，
///   两层不完全重合才有纵深，否则就是一块渐变色的「沙丘」；
/// * **只做背景**——内部 `IgnorePointer` 不吃手势，也不占布局高度
///   （调用方用 `Stack` 铺满），歌词照常滚动。
///
/// 整体透明度压得很低（填充 0.2 以下），压在歌词下面不影响可读性。
class SpectrumRibbon extends StatelessWidget {
  const SpectrumRibbon({
    super.key,
    required this.bands,
    this.color,
    this.colorEnd,
    this.maxHeight = 0.085,
    this.maxPixelHeight = 62,
    this.intensity = 1,
  });

  /// 各段幅度（0~1）；空列表表示没在放歌，整条淡出
  final ValueListenable<List<double>> bands;

  /// 主色；默认取主题主色（与进度条、播放键同色系）
  final Color? color;

  /// 右端色相：与 [color] 不同的颜色会让波浪从左到右淡出一层色相变化；
  /// 为空时沿用 [color]
  final Color? colorEnd;

  /// 波峰最大高度（相对整块高度）
  final double maxHeight;

  /// 波峰最大高度上限（逻辑像素）：窗口再高也只是一条，不会变成半屏
  final double maxPixelHeight;

  /// 整体不透明度系数（0~1），留给不同页面的克制程度
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color tone = color ?? scheme.primary;
    final Color toneEnd = colorEnd ?? tone;
    return IgnorePointer(
      child: RepaintBoundary(
        child: ValueListenableBuilder<List<double>>(
          valueListenable: bands,
          builder: (BuildContext context, List<double> values, Widget? _) {
            // 暂停时数据源会清空：整条淡出，而不是「冻住一帧」
            return AnimatedOpacity(
              opacity: values.isEmpty ? 0 : 1,
              duration: const Duration(milliseconds: 480),
              curve: Curves.easeOutCubic,
              child: CustomPaint(
                size: Size.infinite,
                painter: _RibbonPainter(
                  values: values,
                  color: tone,
                  colorEnd: toneEnd,
                  shadowColor:
                      Color.lerp(toneEnd, scheme.tertiary, 0.5) ?? tone,
                  maxHeight: maxHeight,
                  maxPixelHeight: maxPixelHeight,
                  intensity: intensity,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter({
    required this.values,
    required this.color,
    required this.colorEnd,
    required this.shadowColor,
    required this.maxHeight,
    required this.maxPixelHeight,
    required this.intensity,
  });

  final List<double> values;
  final Color color;
  final Color colorEnd;

  /// 副浪颜色：比主浪更冷一点，叠在一起才有纵深
  final Color shadowColor;

  final double maxHeight;
  final double maxPixelHeight;
  final double intensity;

  /// 每列宽度（逻辑像素）：4px 一列在 1280 宽下是 320 列，曲线够顺
  static const double _columnWidth = 4;

  /// 列数上限：超宽屏（4K 全屏）也不让每帧多画几百个点
  static const int _maxColumns = 320;

  /// 副浪高度比例：主浪的 0.7，紧跟在后面才看得出是第二层
  static const double _shadowScale = 0.7;

  /// 静音时也留一线，波形不会凭空消失
  static const double _minAmplitude = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width < 2 || size.height < 4) {
      return;
    }
    final double strength = intensity.clamp(0.0, 1.0);
    if (strength <= 0) {
      return;
    }
    final double floorY = size.height;
    final double cap = math.min(size.height * maxHeight, maxPixelHeight);
    if (cap <= 1) {
      return;
    }
    final int columns = (size.width / _columnWidth).ceil().clamp(
      16,
      _maxColumns,
    );
    final int last = values.length - 1;

    final List<double> amplitudes = List<double>.filled(columns + 1, 0);
    for (int i = 0; i <= columns; i += 1) {
      final double t = last == 0 ? 0 : last * i / columns;
      final double band = _sample(t).clamp(0.0, 1.0);
      // 1.15 次幂：小信号压下去、鼓点顶上来，波形才不是一条平缓的坡
      amplitudes[i] = math.max(
        _minAmplitude,
        cap * math.pow(band, 1.15).toDouble(),
      );
    }
    // 副浪用平滑过的幅度：形状比主浪更「钝」，两层错开才有层次
    final List<double> shadow = List<double>.filled(columns + 1, 0);
    for (int i = 0; i <= columns; i += 1) {
      final double left = amplitudes[(i - 1).clamp(0, columns)];
      final double center = amplitudes[i];
      final double right = amplitudes[(i + 1).clamp(0, columns)];
      shadow[i] = (left + center * 2 + right) / 4 * _shadowScale;
    }

    final Rect rect = Offset.zero & size;
    // 整条波形画在一个图层里，最后用 dstIn 抹掉左右两端：
    // 直接画到屏上就成了「硬切边」，全宽铺起来很显眼
    canvas.saveLayer(rect, Paint());

    // 副浪先画：更矮、更淡、色相偏冷，主浪压在上面才有前后关系
    canvas.drawPath(
      _surface(size, shadow, floorY),
      Paint()
        ..isAntiAlias = true
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                shadowColor.withValues(alpha: 0),
                shadowColor.withValues(alpha: 0.035 * strength),
                shadowColor.withValues(alpha: 0.075 * strength),
              ],
              stops: const <double>[0, 0.55, 1],
            ).createShader(
              Rect.fromLTRB(0, floorY - cap * _shadowScale, size.width, floorY),
            ),
    );

    // 主浪：从波峰往下越来越实，像水面一样贴着底部
    canvas.drawPath(
      _surface(size, amplitudes, floorY),
      Paint()
        ..isAntiAlias = true
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            color.withValues(alpha: 0.02 * strength),
            color.withValues(alpha: 0.055 * strength),
            color.withValues(alpha: 0.115 * strength),
          ],
          stops: const <double>[0, 0.5, 1],
        ).createShader(Rect.fromLTRB(0, floorY - cap, size.width, floorY)),
    );

    // 波峰一道细亮边：整条带子的「骨」，没有它就只是一团渐变色块。
    // 先铺一层宽的当柔光，再压一根实线；左右偏一点色相，
    // 全宽 1000px 以上才不像一条画上去的折线
    final Path crest = _crest(size, amplitudes, floorY);
    Shader ridge(double alpha) => LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: <Color>[
        color.withValues(alpha: alpha * strength),
        colorEnd.withValues(alpha: alpha * strength * 1.1),
      ],
    ).createShader(rect);
    canvas.drawPath(
      crest,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..shader = ridge(0.085)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    // 上面那层 blur 只提供柔光，这里再压一根实线保证「骨」是清晰的
    canvas.drawPath(
      crest,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round
        ..shader = ridge(0.26),
    );

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
          stops: <double>[0, 0.08, 0.92, 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  /// 贴底的一块面：上缘跟着波形走，下缘就是页面底边
  Path _surface(Size size, List<double> amplitudes, double floorY) {
    final int columns = amplitudes.length - 1;
    double x(int index) => size.width * index / columns;
    final Path path = Path()..moveTo(0, floorY - amplitudes[0]);
    for (int i = 1; i <= columns; i += 1) {
      path.lineTo(x(i), floorY - amplitudes[i]);
    }
    return path
      ..lineTo(size.width, floorY)
      ..lineTo(0, floorY)
      ..close();
  }

  /// 只要上缘那一根线
  Path _crest(Size size, List<double> amplitudes, double floorY) {
    final int columns = amplitudes.length - 1;
    double x(int index) => size.width * index / columns;
    final Path path = Path()..moveTo(0, floorY - amplitudes[0]);
    for (int i = 1; i <= columns; i += 1) {
      path.lineTo(x(i), floorY - amplitudes[i]);
    }
    return path;
  }

  /// 在 24 个频段之间做 Catmull-Rom 插值：曲线过每一段、又不抖
  double _sample(double t) {
    final int last = values.length - 1;
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
  bool shouldRepaint(_RibbonPainter oldDelegate) =>
      !identical(oldDelegate.values, values) ||
      oldDelegate.color != color ||
      oldDelegate.colorEnd != colorEnd ||
      oldDelegate.shadowColor != shadowColor ||
      oldDelegate.maxHeight != maxHeight ||
      oldDelegate.maxPixelHeight != maxPixelHeight ||
      oldDelegate.intensity != intensity;
}

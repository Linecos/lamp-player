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

  /// 横向色相分几档、透明度分几档。
  ///
  /// 逐根 `drawRRect` 时 1600 宽要画 170 根 × 2 次（柱身 + 亮顶）；
  /// 实测（`tool/spectrum_bench.dart`，1600×220、240Hz 屏、窗口在前台）
  /// raster 均 1.85ms，是这个页面里最大的一笔。同档柱子攒进一条 `Path`
  /// 一次画完之后降到 1.02ms。档位取得够细：色相每档 5~6°、alpha 每档
  /// 0.0625（误差 ≤0.03，看不出来）。
  static const int _tintBuckets = 16;
  static const int _alphaLevels = 16;

  /// 几何与取色只跟尺寸 / 配色有关，帧间不变（窗口不缩放时一直命中）
  static _BarGeometry? _geometry;

  /// 复用的画笔，别每帧新建
  static final Paint _paint = Paint()..isAntiAlias = true;

  /// 分档路径池：柱身一批、亮顶一批，每帧先 reset 再攒
  static final List<Path> _bodyPaths = List<Path>.generate(
    _tintBuckets * _alphaLevels,
    (_) => Path(),
  );
  static final List<Path> _topPaths = List<Path>.generate(
    _tintBuckets * _alphaLevels,
    (_) => Path(),
  );

  /// 本帧用到了哪些档位（`Path` 没有 `isEmpty`，只能自己记）
  static final Uint8List _bodyUsed = Uint8List(_tintBuckets * _alphaLevels);
  static final Uint8List _topUsed = Uint8List(_tintBuckets * _alphaLevels);

  /// 每档色相的代表色（0xRRGGBB，不含 alpha），配色变了才重算
  static final Int32List _bucketRgb = Int32List(_tintBuckets);
  static List<Color>? _bucketColors;

  /// `pow(v, 1.1)` 查表：256 级线性插值的误差远小于一个色阶
  static final Float64List _gain = Float64List(257)
    ..setAll(0, <double>[
      for (int i = 0; i <= 256; i += 1) math.pow(i / 256, 1.1).toDouble(),
    ]);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width < 4 || size.height < 4) {
      return;
    }
    final double strength = intensity.clamp(0.0, 1.0);
    if (strength <= 0) {
      return;
    }
    final _BarGeometry geometry = _fit(size);
    _syncBuckets();
    final int count = geometry.count;
    final double bar = geometry.barWidth;
    final double maxHeight = math.min(maxBarHeight, size.height);
    final int last = values.length - 1;

    for (int i = 0; i < _bodyPaths.length; i += 1) {
      _bodyPaths[i].reset();
      _topPaths[i].reset();
    }
    _bodyUsed.fillRange(0, _bodyUsed.length, 0);
    _topUsed.fillRange(0, _topUsed.length, 0);

    for (int i = 0; i < count; i += 1) {
      final double t = count == 1 ? 0 : i / (count - 1);
      final double value = _sample(last * t).clamp(0.0, 1.0);
      final double height = math.max(
        _minBar,
        maxHeight * _gain[(value * 256).round()] * geometry.weight[i],
      );
      // 两端 6% 内淡出。以前是整排 `saveLayer` + 渐变 mask 再 `dstIn`，
      // 每帧都要开一张离屏图层、建一个线性渐变着色器；直接把系数乘进
      // 每根柱子的 alpha，效果一样，代价只剩一次乘法。
      // 越高的柱子越亮：安静的段落整排淡下去，鼓点一敲就亮起来
      final double alpha = (0.26 + 0.40 * value) * strength * geometry.fade[i];
      if (alpha <= 0.004) {
        // 最外侧那两根的淡出系数正好是 0：量化后仍会留下 3% 的灰点
        continue;
      }
      final double x = geometry.left[i];
      final double top = size.height - height;
      final int bucket = geometry.bucket[i];
      final int slot = bucket * _alphaLevels + _alphaLevel(alpha);
      _bodyPaths[slot].addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, bar, height),
          Radius.circular(bar / 2),
        ),
      );
      _bodyUsed[slot] = 1;
      // 柱顶压一小段更亮的块：一排亮顶比整根纯色更有「频谱」的力量感
      if (height > 3) {
        final int topSlot = bucket * _alphaLevels + _alphaLevel(alpha * 1.45);
        _topPaths[topSlot].addRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, top, bar, math.min(2.2, height * 0.35)),
            Radius.circular(bar / 2),
          ),
        );
        _topUsed[topSlot] = 1;
      }
    }

    for (int slot = 0; slot < _bodyPaths.length; slot += 1) {
      final int bucket = slot ~/ _alphaLevels;
      final int level = slot % _alphaLevels;
      final int rgb = _bucketRgb[bucket];
      final double alpha = _levelAlpha(level);
      if (_bodyUsed[slot] != 0) {
        _paint.color = Color((_alphaByte(alpha) << 24) | rgb);
        canvas.drawPath(_bodyPaths[slot], _paint);
      }
      if (_topUsed[slot] != 0) {
        _paint.color = Color(
          (_alphaByte(math.min(1.0, alpha * 1.45)) << 24) | rgb,
        );
        canvas.drawPath(_topPaths[slot], _paint);
      }
    }
  }

  /// alpha 量化到 [_alphaLevels] 档（16 档 → 步长 0.0625）
  static int _alphaLevel(double alpha) =>
      (alpha * _alphaLevels).floor().clamp(0, _alphaLevels - 1);

  /// 档位还原成 alpha（取档位中点，整排不至于整体偏暗）
  static double _levelAlpha(int level) => (level + 0.5) / _alphaLevels;

  static int _alphaByte(double alpha) =>
      (alpha.clamp(0.0, 1.0) * 255).round() & 0xFF;

  /// 按尺寸 / 配色取几何，命中缓存就不重算
  static _BarGeometry _fit(Size size) {
    final _BarGeometry? cached = _geometry;
    if (cached != null && cached.size == size) {
      return cached;
    }
    final double step = _barWidth + _gap;
    final int count = (size.width / step).ceil().clamp(4, 512);
    // 按实际柱数反算柱宽：柱子刚好铺满整宽，右侧不会留一条缝
    final double bar = math.max(1.0, (size.width - _gap * (count - 1)) / count);
    final Float64List left = Float64List(count);
    final Float64List weight = Float64List(count);
    final Float64List fade = Float64List(count);
    final Uint8List bucket = Uint8List(count);
    for (int i = 0; i < count; i += 1) {
      final double t = count == 1 ? 0 : i / (count - 1);
      left[i] = i * (bar + _gap);
      // 中部权重：两端收到 30%，变化集中在屏幕中间，看起来更聚拢
      weight[i] = 0.30 + 0.70 * math.sin(math.pi * t);
      fade[i] = _edgeFade(t);
      bucket[i] = (t * _tintBuckets).floor().clamp(0, _tintBuckets - 1);
    }
    return _geometry = _BarGeometry(
      size: size,
      count: count,
      barWidth: bar,
      left: left,
      weight: weight,
      fade: fade,
      bucket: bucket,
    );
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
  static Color _tint(List<Color> colors, double t) {
    if (t <= 0.55) {
      return Color.lerp(colors[0], colors[1], t / 0.55)!;
    }
    return Color.lerp(colors[1], colors[2], (t - 0.55) / 0.45)!;
  }

  /// 每个色相档的代表色；配色变了才重算
  void _syncBuckets() {
    if (listEquals(_bucketColors, colors)) {
      return;
    }
    _bucketColors = List<Color>.unmodifiable(colors);
    for (int b = 0; b < _tintBuckets; b += 1) {
      _bucketRgb[b] =
          _tint(colors, (b + 0.5) / _tintBuckets).toARGB32() & 0x00FFFFFF;
    }
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

/// 柱状频谱的布局缓存：柱位、中部权重、两端淡出、色相档位。
///
/// 只跟尺寸有关，窗口不缩放时帧间完全不变，没必要每帧重算 170 次
/// `sin(pi * t)` 与色相插值。
class _BarGeometry {
  const _BarGeometry({
    required this.size,
    required this.count,
    required this.barWidth,
    required this.left,
    required this.weight,
    required this.fade,
    required this.bucket,
  });

  final Size size;
  final int count;
  final double barWidth;
  final Float64List left;
  final Float64List weight;
  final Float64List fade;

  /// 每根柱子所属的色相档位
  final Uint8List bucket;
}

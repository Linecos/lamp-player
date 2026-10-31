import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../common/ui_clock.dart';

/// 网格渐变的网格密度（列 × 行）。
///
/// 颜色只给在顶点上，三角形内部由 Skia 做线性插值：网格太粗时每块三角形
/// 是一道折痕，整屏看着像低模的立方体；24×16 后折痕小到看不出来。
/// 425 个顶点、768 个三角形仍然只有一次 `drawVertices`。
const int _meshColumns = 24;
const int _meshRows = 16;

/// 背景压暗系数：整页背景要比封面暗，白字才压得住
const double _meshDim = 0.62;

/// 颜色权重的幂次：越大每块区域越「纯」、过渡带越窄，混出来才不发灰
const double _meshPower = 1.9;

/// 正在播放页的封面取色背景。
///
/// 整屏一块网格渐变：四个色板色按平滑的波形场加权，波形随时间缓慢漂移，
/// 看起来是「颜色在流」。以前是几团预渲染的径向光斑平移，团块之间总有
/// 边缘、叠起来又互相冲淡；网格渐变靠插值出过渡，既没有边也没有叠加。
///
/// 测试 / golden 可通过 [animate] 关闭动画。
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

/// 换色板时的过渡时长。
const Duration _paletteFadeDuration = Duration(milliseconds: 360);

class _CoverFlowBackgroundState extends State<CoverFlowBackground>
    with SingleTickerProviderStateMixin {
  bool _reduceMotion = false;

  /// 动画起点（[UiClock.slow] 秒）：重新打开流光时从头开始漂
  double _origin = UiClock.slow.seconds;

  /// 当前色板（[harmonizeCoverColors] 之后固定 4 色）
  List<Color>? _palette;

  /// 正在淡出的上一套色板：换歌时整屏背景硬切比封面过渡明显得多
  List<Color>? _fadingPalette;

  late final AnimationController _paletteFade = AnimationController(
    vsync: this,
    duration: _paletteFadeDuration,
    value: 1,
  );

  late final CurvedAnimation _paletteMix = CurvedAnimation(
    parent: _paletteFade,
    curve: Curves.easeInOutCubic,
  );

  /// 连切时只认最后一次：动画结束的回调对不上就留着下一套
  int _fadeToken = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  }

  @override
  void didUpdateWidget(CoverFlowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      // 重新打开流光时从相位 0 开始，和关掉前的位置无关
      _origin = UiClock.slow.seconds;
    }
  }

  @override
  void dispose() {
    // 先解掉对 controller 的监听，再销毁 controller
    _paletteMix.dispose();
    _paletteFade.dispose();
    super.dispose();
  }

  void _syncPalette(List<Color> palette) {
    if (listEquals(_palette, palette)) {
      return;
    }
    final List<Color>? previous = _palette;
    _palette = palette;
    if (previous == null) {
      return;
    }
    _fadingPalette = previous;
    final int token = ++_fadeToken;
    _paletteFade.forward(from: 0).whenComplete(() {
      if (!mounted || token != _fadeToken) {
        return;
      }
      setState(() => _fadingPalette = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 背景色板与深浅色主题解耦：浅色模式也保持同一套深色高饱和配色
    _syncPalette(
      harmonizeCoverColors(
        widget.colors ??
            <Color>[scheme.primary, scheme.tertiary, scheme.secondary],
      ),
    );
    final bool animating = widget.animate && !_reduceMotion;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: CustomPaint(
            painter: _MeshPainter(
              palette: _palette!,
              previousPalette: _fadingPalette,
              mix: _fadingPalette == null ? null : _paletteMix,
              animate: animating,
              origin: _origin,
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

/// sRGB 通道 → 线性光
double _toLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// 线性光 → sRGB 通道
double _toSrgb(double c) => c <= 0.0031308
    ? c * 12.92
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

/// sRGB → OKLab。
///
/// 直接在 sRGB 里按权重混色，互补色会一起往灰里掉（红 + 绿 = 脏橄榄）；
/// OKLab 是感知均匀空间，混出来的中间色仍然干净。
List<double> _toOklab(Color color) {
  final double r = _toLinear(color.r);
  final double g = _toLinear(color.g);
  final double b = _toLinear(color.b);
  final double l = math
      .pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3)
      .toDouble();
  final double m = math
      .pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3)
      .toDouble();
  final double s = math
      .pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3)
      .toDouble();
  return <double>[
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

/// OKLab → sRGB，顺带按 [_meshDim] 压暗
Color _fromOklab(double lightness, double a, double b) {
  final double l = math
      .pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
      .toDouble();
  final double m = math
      .pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
      .toDouble();
  final double s = math
      .pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
      .toDouble();
  double channel(double linear) =>
      (_toSrgb(linear.clamp(0.0, 1.0)) * _meshDim).clamp(0.0, 1.0);
  return Color.from(
    alpha: 1,
    red: channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    green: channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    blue: channel(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
  );
}

/// 三个不同方向、不同速度的行波叠加成 [0, 1] 的标量场。
///
/// 单个行波在屏幕上的表现就是「整片颜色从右往左挪」，一眼看得出方向；
/// 三个方向叠起来，图案是原地变形，没有整体平移。
double _flow(double u, double v, double seconds, double phase) {
  double wave(double x) => math.sin(x * math.pi * 2);
  final double sum =
      wave(u * 0.9 + v * 0.4 + seconds * 0.13 + phase) +
      wave(-u * 0.55 + v * 0.75 - seconds * 0.10 + phase + 0.37) +
      wave(u * 0.35 - v * 0.65 + seconds * 0.17 + phase + 0.71);
  return (0.5 + sum / 6).clamp(0.0, 1.0);
}

/// 顶点 (u, v) 在 [seconds] 时刻四个色板色的权重（和为 1）。
///
/// 两个场分别取 (u, v) 和 (v, u)，色块就不会是规整的棋盘，而是缓慢变形的色团。
List<double> _meshWeights(double u, double v, double seconds) {
  final double n1 = _flow(u, v, seconds, 0);
  final double n2 = _flow(v, u, seconds, 0.5);
  double weight(double x) => math.pow(x, _meshPower).toDouble();
  final double a = weight((1 - n1) * n2);
  final double b = weight(n1 * n2);
  final double c = weight(n1 * (1 - n2));
  final double d = weight((1 - n1) * (1 - n2));
  final double sum = a + b + c + d;
  return <double>[a / sum, b / sum, c / sum, d / sum];
}

/// 整屏网格渐变，每帧一次 `drawVertices`。
///
/// 相位来自 [UiClock.slow]（15fps）：整屏重绘没必要跟显示器刷新率走。
class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.palette,
    this.previousPalette,
    this.mix,
    this.animate = false,
    this.origin = 0,
  }) : super(
         repaint: Listenable.merge(<Listenable?>[
           if (animate) UiClock.slow,
           mix,
         ]),
       );

  /// 当前色板（固定 4 色）
  final List<Color> palette;

  /// 换色板前的色板：过渡期间按 [mix] 与新色板插值
  final List<Color>? previousPalette;

  /// 0 = 全是旧色板，1 = 全是新色板；为空表示没有过渡
  final Animation<double>? mix;

  /// false 时画静态帧（golden / 关闭流光 / 系统要求减少动效）。
  final bool animate;

  /// 相位零点（[UiClock.slow] 秒）
  final double origin;

  @override
  void paint(Canvas canvas, Size size) {
    final double seconds = animate ? UiClock.slow.seconds - origin : 0;
    final double m = mix?.value ?? 1;
    final List<List<double>> lab = palette.map(_toOklab).toList();
    final List<List<double>>? previousLab = previousPalette
        ?.map(_toOklab)
        .toList();

    final List<Offset> positions = <Offset>[];
    final List<Color> colors = <Color>[];
    for (int j = 0; j <= _meshRows; j += 1) {
      for (int i = 0; i <= _meshColumns; i += 1) {
        final double u = i / _meshColumns;
        final double v = j / _meshRows;
        positions.add(Offset(u * size.width, v * size.height));
        final List<double> weights = _meshWeights(u, v, seconds);
        final List<double> current = _blendLab(lab, weights);
        final List<List<double>>? old = previousLab;
        if (old != null) {
          final List<double> oldColor = _blendLab(old, weights);
          for (int k = 0; k < 3; k += 1) {
            current[k] = oldColor[k] + (current[k] - oldColor[k]) * m;
          }
        }
        colors.add(_fromOklab(current[0], current[1], current[2]));
      }
    }

    final List<int> indices = <int>[];
    for (int j = 0; j < _meshRows; j += 1) {
      for (int i = 0; i < _meshColumns; i += 1) {
        final int a = j * (_meshColumns + 1) + i;
        final int b = a + 1;
        final int c = a + _meshColumns + 1;
        final int d = c + 1;
        indices.addAll(<int>[a, b, c, b, d, c]);
      }
    }

    canvas.drawVertices(
      ui.Vertices(
        ui.VertexMode.triangles,
        positions,
        colors: colors,
        indices: indices,
      ),
      BlendMode.src,
      Paint(),
    );
  }

  @override
  bool shouldRepaint(covariant _MeshPainter oldDelegate) {
    return !identical(oldDelegate.palette, palette) ||
        !identical(oldDelegate.previousPalette, previousPalette) ||
        oldDelegate.animate != animate ||
        oldDelegate.origin != origin ||
        oldDelegate.mix != mix;
  }
}

/// 按权重混合四个 OKLab 颜色
List<double> _blendLab(List<List<double>> lab, List<double> weights) {
  return <double>[
    for (int k = 0; k < 3; k += 1)
      lab[0][k] * weights[0] +
          lab[1][k] * weights[1] +
          lab[2][k] * weights[2] +
          lab[3][k] * weights[3],
  ];
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

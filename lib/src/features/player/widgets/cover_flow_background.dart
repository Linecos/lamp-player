import 'dart:math' as math;
import 'dart:typed_data';
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
// 色域转换与权重幂次是每顶点都要做的非线性函数。查表只建一次，
// 线性插值保留平滑过渡，避免流光每秒做数万次 pow。
const int _lookupSteps = 4096;
final List<double> _srgbLookup = List<double>.generate(_lookupSteps + 1, (
  int i,
) {
  final double c = i / _lookupSteps;
  return c <= 0.0031308
      ? c * 12.92
      : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;
});
final List<double> _weightLookup = List<double>.generate(
  _lookupSteps + 1,
  (int i) => math.pow(i / _lookupSteps, _meshPower).toDouble(),
);

double _lookup(List<double> table, double x) {
  final double scaled = x.clamp(0.0, 1.0) * _lookupSteps;
  final int index = scaled.floor();
  if (index == _lookupSteps) return table[index];
  return table[index] + (table[index + 1] - table[index]) * (scaled - index);
}

double _toSrgb(double c) => _lookup(_srgbLookup, c);

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

/// OKLab → sRGB，顺带按 [_meshDim] 压暗；直接写成一个 32 位 ARGB。
///
/// 每帧要给 425 个顶点取色，返回 [Color] 等于每帧新建 425 个对象；这里只产出
/// 一个 int，直接写进复用的颜色缓冲。
int _oklabArgb(double lightness, double a, double b) {
  final double lc = lightness + 0.3963377774 * a + 0.2158037573 * b;
  final double mc = lightness - 0.1055613458 * a - 0.0638541728 * b;
  final double sc = lightness - 0.0894841775 * a - 1.2914855480 * b;
  final double l = lc * lc * lc;
  final double m = mc * mc * mc;
  final double s = sc * sc * sc;
  double channel(double linear) =>
      (_toSrgb(linear.clamp(0.0, 1.0)) * _meshDim).clamp(0.0, 1.0);
  final int r =
      (channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s) * 255)
          .round();
  final int g =
      (channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s) * 255)
          .round();
  final int b2 =
      (channel(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s) * 255)
          .round();
  return 0xFF000000 | (r << 16) | (g << 8) | b2;
}

/// 单个行波会让整片颜色平移；三组不同方向/速度的波叠加后原地变形。
/// 每个顶点固定的空间相位只在网格尺寸变化时算一次，时间相位每帧只算三次。
/// sin(a+b) = sin(a)cos(b) + cos(a)sin(b)，避免每帧 425×6 次 sin。
class _MeshWave {
  _MeshWave(double u, double v) {
    final List<double> phases = <double>[
      u * 0.9 + v * 0.4,
      -u * 0.55 + v * 0.75 + 0.37,
      u * 0.35 - v * 0.65 + 0.71,
      v * 0.9 + u * 0.4 + 0.5,
      -v * 0.55 + u * 0.75 + 0.87,
      v * 0.35 - u * 0.65 + 1.21,
    ];
    for (final double phase in phases) {
      final double angle = phase * math.pi * 2;
      sine.add(math.sin(angle));
      cosine.add(math.cos(angle));
    }
  }

  final List<double> sine = <double>[];
  final List<double> cosine = <double>[];
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
  }) : _lab = palette.map(_toOklab).toList(),
       _previousLab = previousPalette?.map(_toOklab).toList(),
       super(
         repaint: Listenable.merge(<Listenable?>[
           if (animate) UiClock.slow,
           mix,
         ]),
       );

  // 色板只在换歌/换主题时变；不在每次 paint 中重复做 sRGB → OKLab。
  final List<List<double>> _lab;
  final List<List<double>>? _previousLab;

  // 网格拓扑及顶点坐标只随窗口尺寸变化。
  static _MeshGeometry? _geometry;

  /// 描边参数恒定，建一次就够（每帧 new 一个 Paint 也是白扔）
  static final Paint _paint = Paint();

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

  // 顶点色与渐变几何都写进 [_MeshGeometry] 的复用缓冲；每帧只读标量。
  @override
  void paint(Canvas canvas, Size size) {
    final double seconds = animate ? UiClock.slow.seconds - origin : 0;
    final double m = mix?.value ?? 1;
    final _MeshGeometry geometry = _geometry?.size == size
        ? _geometry!
        : (_geometry = _MeshGeometry(size));
    final double turns = seconds * math.pi * 2;
    // 三组波的时间相位：每帧只算 6 次三角函数
    final double s0 = math.sin(turns * 0.13);
    final double s1 = math.sin(-turns * 0.10);
    final double s2 = math.sin(turns * 0.17);
    final double c0 = math.cos(turns * 0.13);
    final double c1 = math.cos(-turns * 0.10);
    final double c2 = math.cos(turns * 0.17);

    final List<_MeshWave> waves = geometry.waves;
    final Int32List colors = geometry.colors32;
    final List<List<double>> lab = _lab;
    final List<List<double>>? previous = _previousLab;
    final List<double> l0 = lab[0];
    final List<double> l1 = lab[1];
    final List<double> l2 = lab[2];
    final List<double> l3 = lab[3];
    final bool blending = previous != null && m < 1;
    final List<double>? p0 = blending ? previous[0] : null;
    final List<double>? p1 = blending ? previous[1] : null;
    final List<double>? p2 = blending ? previous[2] : null;
    final List<double>? p3 = blending ? previous[3] : null;

    for (int i = 0; i < waves.length; i += 1) {
      final _MeshWave wave = waves[i];
      final List<double> sine = wave.sine;
      final List<double> cosine = wave.cosine;
      // 两个行波场；sin(a+b) = sin a cos b + cos a sin b
      final double n1 =
          (0.5 +
                  (sine[0] * c0 +
                          cosine[0] * s0 +
                          sine[1] * c1 +
                          cosine[1] * s1 +
                          sine[2] * c2 +
                          cosine[2] * s2) /
                      6)
              .clamp(0.0, 1.0);
      final double n2 =
          (0.5 +
                  (sine[3] * c0 +
                          cosine[3] * s0 +
                          sine[4] * c1 +
                          cosine[4] * s1 +
                          sine[5] * c2 +
                          cosine[5] * s2) /
                      6)
              .clamp(0.0, 1.0);
      final double wa = _lookup(_weightLookup, (1 - n1) * n2);
      final double wb = _lookup(_weightLookup, n1 * n2);
      final double wc = _lookup(_weightLookup, n1 * (1 - n2));
      final double wd = _lookup(_weightLookup, (1 - n1) * (1 - n2));
      final double inv = 1 / (wa + wb + wc + wd);
      final double a0 = wa * inv;
      final double a1 = wb * inv;
      final double a2 = wc * inv;
      final double a3 = wd * inv;

      double lightness = l0[0] * a0 + l1[0] * a1 + l2[0] * a2 + l3[0] * a3;
      double axisA = l0[1] * a0 + l1[1] * a1 + l2[1] * a2 + l3[1] * a3;
      double axisB = l0[2] * a0 + l1[2] * a1 + l2[2] * a2 + l3[2] * a3;
      if (blending) {
        final double oldL =
            p0![0] * a0 + p1![0] * a1 + p2![0] * a2 + p3![0] * a3;
        final double oldA = p0[1] * a0 + p1[1] * a1 + p2[1] * a2 + p3[1] * a3;
        final double oldB = p0[2] * a0 + p1[2] * a1 + p2[2] * a2 + p3[2] * a3;
        lightness = oldL + (lightness - oldL) * m;
        axisA = oldA + (axisA - oldA) * m;
        axisB = oldB + (axisB - oldB) * m;
      }
      colors[i] = _oklabArgb(lightness, axisA, axisB);
    }

    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        geometry.positions32,
        colors: colors,
        indices: geometry.indices16,
      ),
      BlendMode.src,
      _paint,
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

/// 网格坐标与三角形索引只在尺寸变化时生成，动画帧只更新顶点色。
///
/// 坐标 / 索引 / 颜色都存成**可复用的类型化数组**：`ui.Vertices` 的构造函数
/// 会把手里的 `List<Offset>` / `List<Color>` 重新编码成 Float32List / Int32List，
/// 每帧做一次等于每秒扔掉上百 KB 的临时缓冲；坐标和索引明明一帧都不变。
class _MeshGeometry {
  _MeshGeometry(this.size) {
    for (int j = 0; j <= _meshRows; j += 1) {
      for (int i = 0; i <= _meshColumns; i += 1) {
        final double u = i / _meshColumns;
        final double v = j / _meshRows;
        positions.add(Offset(u * size.width, v * size.height));
        waves.add(_MeshWave(u, v));
      }
    }
    for (int j = 0; j < _meshRows; j += 1) {
      for (int i = 0; i < _meshColumns; i += 1) {
        final int a = j * (_meshColumns + 1) + i;
        final int b = a + 1;
        final int c = a + _meshColumns + 1;
        final int d = c + 1;
        indices.addAll(<int>[a, b, c, b, d, c]);
      }
    }

    final int count = positions.length;
    positions32 = Float32List(count * 2);
    for (int i = 0; i < count; i += 1) {
      positions32[i * 2] = positions[i].dx;
      positions32[i * 2 + 1] = positions[i].dy;
    }
    indices16 = Uint16List.fromList(indices);
    // 每帧原地改写，不再新建
    colors32 = Int32List(count);
  }

  final Size size;
  final List<Offset> positions = <Offset>[];
  final List<_MeshWave> waves = <_MeshWave>[];
  final List<int> indices = <int>[];

  late final Float32List positions32;
  late final Uint16List indices16;

  /// 顶点色缓冲：每帧被 [_MeshPainter.paint] 原地覆盖
  late final Int32List colors32;
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

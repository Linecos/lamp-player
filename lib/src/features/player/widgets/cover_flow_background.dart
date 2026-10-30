import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../common/ui_clock.dart';

/// 光斑位图每边的像素数。
///
/// 光斑本身是很柔的径向渐变，放大到整屏也看不出像素块；192² 一张约 150KB，
/// 28 张合计约 4MB，换来的是每帧零着色器创建。
const int _spotImageSize = 192;

/// 每个色板色预渲染几档色相（在 ±[_spotHueAmp]° 内等分）。
const int _spotHueSteps = 7;

/// 流动光斑的色相摆动幅度（度）；与原先每帧算 HSL 时的幅度保持一致。
const double _spotHueAmp = 14;

/// 测试用：预渲染光斑的累计张数，用来确认动画帧不会反复重建位图。
@visibleForTesting
int coverFlowSpotRenderCount = 0;

/// 正在播放页的封面取色背景。
///
/// 用封面色板画几层柔和的径向渐变，再盖一层与主题同色的半透明 scrim。
/// 每个色块沿固定方向匀速穿过画面（[sweep]），看起来是「光在流」而不是
/// 「色块在原地呼吸」；动画只让 [CustomPainter] 重绘，不重建歌词与控件；
/// 测试 / golden 可通过 [animate] 关闭。
///
/// 光斑按「色板色 × 色相档」预渲染成位图，每帧只做 `drawImageRect`：
/// 直接每帧 `RadialGradient.createShader` 时，圆心 / 半径每帧都不同，
/// Skia 无法命中着色器缓存，进程提交内存会以每秒上百 MB 的速度上涨。
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

/// 一个完整循环的时长。
///
/// 只走单向、不 `reverse`：反向播放会让光斑原路退回，看起来是
/// 「一呼一吸」而不是「流动」。12 秒扫过一整屏约 160 px/s，
/// 9 秒时偏快、20 秒以上大屏上几乎看不出位移。
const double _auraPeriod = 12;

/// 换色板时的过渡时长：和封面的换图过渡同一个量级，整页才像「一起换过去」
const Duration _paletteFadeDuration = Duration(milliseconds: 360);

class _CoverFlowBackgroundState extends State<CoverFlowBackground>
    with SingleTickerProviderStateMixin {
  bool _reduceMotion = false;

  /// 动画起点（[UiClock.slow] 秒）：相位从 0 开始算，打开流光时从头扫
  double _origin = UiClock.slow.seconds;

  /// 当前色板对应的预渲染光斑（`[色板色][色相档]`）；色板变化时整组重建
  List<List<ui.Image>>? _spots;
  List<Color>? _spotPalette;

  /// 正在淡出的上一组光斑与底色：换歌时整屏背景要是硬切，比封面那点
  /// 过渡明显得多。过渡结束后释放
  List<List<ui.Image>>? _fadingSpots;
  Color? _fadingSurface;

  late final AnimationController _paletteFade = AnimationController(
    vsync: this,
    duration: _paletteFadeDuration,
    value: 1,
  );

  late final CurvedAnimation _paletteMix = CurvedAnimation(
    parent: _paletteFade,
    curve: Curves.easeInOutCubic,
  );

  /// 连切时只认最后一次：动画结束的回调对不上就把旧组放回去
  int _fadeToken = 0;

  /// 底色：色板第二色压暗，决定整页的基调
  static Color _surfaceOf(List<Color> palette) =>
      Color.lerp(palette[1], Colors.black, 0.55)!;

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
    _disposeGroup(_fadingSpots);
    // 先解掉对 controller 的监听，再销毁 controller
    _paletteMix.dispose();
    _paletteFade.dispose();
    _disposeSpots();
    super.dispose();
  }

  void _disposeGroup(List<List<ui.Image>>? spots) {
    if (spots == null || identical(spots, _spots)) {
      return;
    }
    for (final List<ui.Image> row in spots) {
      for (final ui.Image image in row) {
        image.dispose();
      }
    }
  }

  void _disposeSpots() {
    final List<List<ui.Image>>? spots = _spots;
    _spots = null;
    _spotPalette = null;
    _disposeGroup(spots);
  }

  /// 按色板预渲染光斑位图（色板色 × 色相档）。
  ///
  /// 只在换歌 / 换主题时跑一次；画的时候挑对应档位直接贴图。
  List<List<ui.Image>> _buildSpots(List<Color> palette) {
    return <List<ui.Image>>[
      for (final Color color in palette)
        <ui.Image>[
          for (int step = 0; step < _spotHueSteps; step += 1)
            _renderSpot(color, step),
        ],
    ];
  }

  ui.Image _renderSpot(Color color, int step) {
    final HSLColor hsl = HSLColor.fromColor(color);
    final double shift =
        -_spotHueAmp + 2 * _spotHueAmp * step / (_spotHueSteps - 1);
    final Color shifted = hsl.withHue((hsl.hue + shift) % 360).toColor();

    final Rect rect = Rect.fromLTWH(
      0,
      0,
      _spotImageSize.toDouble(),
      _spotImageSize.toDouble(),
    );
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[shifted, shifted.withValues(alpha: 0)],
        ).createShader(rect),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(_spotImageSize, _spotImageSize);
    picture.dispose();
    coverFlowSpotRenderCount += 1;
    return image;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 背景色板与深浅色主题解耦：浅色模式也保持同一套深色高饱和配色
    final List<Color> palette = harmonizeCoverColors(
      widget.colors ??
          <Color>[scheme.primary, scheme.tertiary, scheme.secondary],
    );
    if (_spots == null || !listEquals(_spotPalette, palette)) {
      final List<List<ui.Image>>? previous = _spots;
      final List<Color>? previousPalette = _spotPalette;
      _spots = _buildSpots(palette);
      _spotPalette = palette;
      if (previous != null && previousPalette != null) {
        // 旧的留在下面淡出，等过渡结束再释放（连切时直接丢掉更早的那组）
        _disposeGroup(_fadingSpots);
        _fadingSpots = previous;
        _fadingSurface = _surfaceOf(previousPalette);
        final int token = ++_fadeToken;
        _paletteFade.forward(from: 0).whenComplete(() {
          if (!mounted || token != _fadeToken) {
            return;
          }
          final List<List<ui.Image>>? stale = _fadingSpots;
          setState(() {
            _fadingSpots = null;
            _fadingSurface = null;
          });
          _disposeGroup(stale);
        });
      }
    }
    final bool animating = widget.animate && !_reduceMotion;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 静态底单独一层：不挂动画，只在换色板时重画。和流光共用一张画布时，
        // 这三块整屏光斑每帧都要重新混合一遍，白白吃掉一半填充率
        RepaintBoundary(
          child: CustomPaint(
            painter: _BasePainter(
              surface: _surfaceOf(palette),
              spots: _spots!,
              previousSurface: _fadingSurface,
              previousSpots: _fadingSpots,
              mix: _fadingSpots == null ? null : _paletteMix,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuraPainter(
              spots: _spots!,
              animate: animating,
              origin: _origin,
              previousSpots: _fadingSpots,
              mix: _fadingSpots == null ? null : _paletteMix,
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

/// 贴一块预渲染光斑：位图是「色板色 → 透明」的径向渐变，[Paint] 的 alpha
/// 负责整体浓淡（`drawImageRect` 只取 Paint 的 alpha，不取 RGB）。
void _paintSpot(
  Canvas canvas,
  Paint paint,
  List<List<ui.Image>> spots,
  Rect src,
  Offset center,
  double radius,
  int colorIndex,
  int hueStep,
  double alpha,
) {
  final double a = alpha.clamp(0.0, 1.0);
  if (a <= 0.002) {
    return;
  }
  paint.color = Colors.white.withValues(alpha: a);
  canvas.drawImageRect(
    spots[colorIndex][hueStep],
    src,
    Rect.fromCircle(center: center, radius: radius),
    paint,
  );
}

/// 光斑位图的源矩形（整张）。
Rect get _spotSrc =>
    Rect.fromLTWH(0, 0, _spotImageSize.toDouble(), _spotImageSize.toDouble());

/// 无色相偏移的那一档（静态底用它）。
const int _neutralHueStep = (_spotHueSteps - 1) ~/ 2;

/// 不随动画变的底：底色 + 三块静态光斑。
///
/// 单独一层（外层 `RepaintBoundary`），只画一次；既决定整页的色调（关闭
/// 流光时也靠它），也保证某块流动光刚好淡出时背景不会塌成一片近黑。
class _BasePainter extends CustomPainter {
  _BasePainter({
    required this.surface,
    required this.spots,
    this.previousSurface,
    this.previousSpots,
    this.mix,
  }) : super(repaint: mix);

  final Color surface;

  /// 色板色 × 色相档的预渲染光斑。
  final List<List<ui.Image>> spots;

  /// 换色板前的底色 / 光斑：过渡期间压在下面淡出
  final Color? previousSurface;
  final List<List<ui.Image>>? previousSpots;

  /// 0 = 全是旧色板，1 = 全是新色板；为空表示没有过渡
  final Animation<double>? mix;

  @override
  void paint(Canvas canvas, Size size) {
    final double m = mix?.value ?? 1;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.lerp(previousSurface ?? surface, surface, m)!,
    );
    final Paint paint = Paint()..filterQuality = FilterQuality.low;
    final Rect src = _spotSrc;

    void block(List<List<ui.Image>> set, double weight) {
      if (weight <= 0.002) {
        return;
      }
      _paintSpot(
        canvas,
        paint,
        set,
        src,
        Offset(size.width * 0.7, size.height * 0.25),
        size.width * 0.95,
        0,
        _neutralHueStep,
        0.72 * weight,
      );
      _paintSpot(
        canvas,
        paint,
        set,
        src,
        Offset(size.width * 0.12, size.height * 0.85),
        size.width * 0.75,
        1,
        _neutralHueStep,
        0.5 * weight,
      );
      _paintSpot(
        canvas,
        paint,
        set,
        src,
        Offset(size.width * 0.9, size.height * 0.9),
        size.width * 0.55,
        2,
        _neutralHueStep,
        0.36 * weight,
      );
    }

    final List<List<ui.Image>>? previous = previousSpots;
    if (previous != null) {
      block(previous, 1 - m);
    }
    block(spots, m);
  }

  @override
  bool shouldRepaint(covariant _BasePainter oldDelegate) {
    return !identical(oldDelegate.spots, spots) ||
        !identical(oldDelegate.previousSpots, previousSpots) ||
        oldDelegate.surface != surface ||
        oldDelegate.previousSurface != previousSurface ||
        oldDelegate.mix != mix;
  }
}

/// 每帧重绘的四条流动光斑（背景完全透明，压在 [_BasePainter] 上面）。
///
/// 相位来自 [UiClock.slow]（15fps），不跟着显示器刷新率走：240Hz 屏上按刷新率
/// 出帧等于每帧把整屏混合四遍，CPU 白烧十几倍。这层是整窗大小，每帧都是一次
/// 全屏重绘，实测占了正在播放页一半的 CPU，所以单独降到 15fps。
class _AuraPainter extends CustomPainter {
  _AuraPainter({
    required this.spots,
    this.animate = false,
    this.origin = 0,
    this.previousSpots,
    this.mix,
  }) : super(
         repaint: Listenable.merge(<Listenable?>[
           if (animate) UiClock.slow,
           mix,
         ]),
       );

  /// 色板色 × 色相档的预渲染光斑；画的时候直接挑一张贴上去。
  final List<List<ui.Image>> spots;

  /// false 时画静态帧（golden / 关闭流光 / 系统要求减少动效）。
  final bool animate;

  /// 相位零点（[UiClock.slow] 秒）
  final double origin;

  /// 换色板前的光斑：过渡期间一起画，按 [mix] 分权重淡出
  final List<List<ui.Image>>? previousSpots;

  /// 0 = 全是旧色板，1 = 全是新色板；为空表示没有过渡
  final Animation<double>? mix;

  @override
  void paint(Canvas canvas, Size size) {
    final double m = mix?.value ?? 1;
    final List<List<ui.Image>>? previous = previousSpots;
    final double t = animate
        ? ((UiClock.slow.seconds - origin) / _auraPeriod) % 1
        : 0;
    final double angle = t * math.pi * 2;
    // 一个 Paint 用到底：只有 alpha 在变，贴图方式不变
    final Paint paint = Paint()..filterQuality = FilterQuality.low;
    final Rect src = _spotSrc;

    /// 贴一块光斑：位图是「色板色 → 透明」的径向渐变，`paint` 的 alpha
    /// 负责整体浓淡（`drawImageRect` 只取 Paint 的 alpha，不取 RGB）。
    ///
    /// 换色板过渡期间同位置画两遍：旧的挑 1-m、新的挑 m，光斑位置与相位
    /// 一致，看着就是颜色慢慢换过去
    void spot(
      Offset center,
      double radius,
      int colorIndex,
      int hueStep,
      double alpha,
    ) {
      if (previous != null) {
        _paintSpot(
          canvas,
          paint,
          previous,
          src,
          center,
          radius,
          colorIndex,
          hueStep,
          alpha * (1 - m),
        );
      }
      _paintSpot(
        canvas,
        paint,
        spots,
        src,
        center,
        radius,
        colorIndex,
        hueStep,
        alpha * m,
      );
    }

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
      required int colorIndex,
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
      final double wave = math.sin(angle * laps + phase * math.pi * 2);
      final double sway = wave * wobble;
      // 色相也按各自节奏摆动：四个斑同频变色同样会显得「整块一起呼吸」。
      // 摆动值量化到预渲染档位，省掉每帧的 HSL 换算。
      final int hueStep = ((wave + 1) / 2 * (_spotHueSteps - 1)).round().clamp(
        0,
        _spotHueSteps - 1,
      );
      spot(
        Offset(size.width * x, size.height * (y + sway)),
        size.width * radius * (1 + 0.08 * math.sin(angle * 2 + phase * 6)),
        colorIndex,
        hueStep,
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
      colorIndex: 0,
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
      colorIndex: 1,
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
      colorIndex: 2,
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
      colorIndex: 3,
      wobble: 0.035,
    );
  }

  @override
  bool shouldRepaint(covariant _AuraPainter oldDelegate) {
    return !identical(oldDelegate.spots, spots) ||
        !identical(oldDelegate.previousSpots, previousSpots) ||
        oldDelegate.animate != animate ||
        oldDelegate.origin != origin ||
        oldDelegate.mix != mix;
  }
}

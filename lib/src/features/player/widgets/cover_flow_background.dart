import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 正在播放页的静态封面取色背景（第一版）。
///
/// 用封面色板画三层柔和的径向渐变，再盖一层与主题同色的半透明 scrim；
/// 这里不做动画，先把取色、回退和文字对比度稳定下来。
class CoverFlowBackground extends StatelessWidget {
  const CoverFlowBackground({
    super.key,
    required this.colors,
    required this.child,
  });

  /// 封面主色；为空时用主题 primary / tertiary / secondary 兜底。
  final List<Color>? colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    final List<Color> palette = _harmonize(
      colors ?? <Color>[scheme.primary, scheme.tertiary, scheme.secondary],
      dark: dark,
    );

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuraPainter(
              colors: palette,
              surface: scheme.surfaceContainerLow,
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
                  scheme.surfaceContainerLow.withValues(
                    alpha: dark ? 0.05 : 0.08,
                  ),
                  scheme.surfaceContainerLow.withValues(
                    alpha: dark ? 0.42 : 0.55,
                  ),
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }

  /// 把封面色压到适合做背景的亮度/饱和度区间；浅色主题下反向提亮。
  List<Color> _harmonize(List<Color> source, {required bool dark}) {
    final List<Color> result = <Color>[];
    for (int i = 0; i < 3; i += 1) {
      final Color raw = source[i % source.length];
      final HSLColor hsl = HSLColor.fromColor(raw);
      final double lightness = dark
          ? hsl.lightness.clamp(0.18, 0.45).toDouble()
          : hsl.lightness.clamp(0.68, 0.88).toDouble();
      final double saturation = dark
          ? hsl.saturation.clamp(0.4, 0.8).toDouble()
          : hsl.saturation.clamp(0.3, 0.6).toDouble();
      result.add(
        hsl.withLightness(lightness).withSaturation(saturation).toColor(),
      );
    }
    return result;
  }
}

class _AuraPainter extends CustomPainter {
  const _AuraPainter({required this.colors, required this.surface});

  final List<Color> colors;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = surface);

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
      Offset(size.width * 0.86, size.height * 0.1),
      size.width * 0.8,
      colors[0],
      0.65,
    );
    spot(
      Offset(size.width * 0.98, size.height * 0.72),
      size.width * 0.72,
      colors[1],
      0.55,
    );
    spot(
      Offset(size.width * 0.12, size.height * 0.98),
      size.width * 0.85,
      colors[2],
      0.5,
    );
  }

  @override
  bool shouldRepaint(covariant _AuraPainter oldDelegate) {
    return !listEquals(oldDelegate.colors, colors) ||
        oldDelegate.surface != surface;
  }
}

import 'package:flutter/material.dart';

import '../player/equalizer.dart';

/// 均衡器曲线：把 10 段增益画成一条平滑曲线，底下跟着每段的读数。
///
/// 节点按等距排布（不是对数频率轴），这样正下方推子的列位置一一对应，
/// 调哪一段就能看到曲线哪个点动。
class EqualizerCurveChart extends StatelessWidget {
  const EqualizerCurveChart({
    super.key,
    required this.gains,
    this.curveHeight = 132,
  });

  final List<double> gains;
  final double curveHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<double> values = normalizeEqGains(gains);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: curveHeight,
          width: double.infinity,
          child: CustomPaint(
            painter: _CurvePainter(
              gains: values,
              curveColor: scheme.primary,
              gridColor: scheme.outlineVariant.withValues(alpha: 0.6),
              baselineColor: scheme.outlineVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            for (final double value in values)
              Expanded(
                child: Text(
                  _formatGain(value),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: value.round() == 0
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  static String _formatGain(double value) {
    final int rounded = value.round();
    if (rounded == 0) {
      return '0';
    }
    return rounded > 0 ? '+$rounded' : '$rounded';
  }
}

class _CurvePainter extends CustomPainter {
  const _CurvePainter({
    required this.gains,
    required this.curveColor,
    required this.gridColor,
    required this.baselineColor,
  });

  final List<double> gains;
  final Color curveColor;
  final Color gridColor;
  final Color baselineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (gains.isEmpty || size.isEmpty) {
      return;
    }
    final List<Offset> points = _points(size);
    final double zeroY = _yForGain(0, size.height);

    // 竖直网格：每段一条，端点略内缩，避免贴住边框
    final Paint grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final double step = size.width / gains.length;
    for (int index = 0; index < gains.length; index += 1) {
      final double x = step * (index + 0.5);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    // 0 dB 基线
    final Paint baseline = Paint()
      ..color = baselineColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), baseline);

    // 曲线下方填充：从曲线连到基线再闭合，像参考图那样一眼看出提/削
    final Path curve = _smoothPath(points);
    final Path fill = Path.from(curve)
      ..lineTo(points.last.dx, zeroY)
      ..lineTo(points.first.dx, zeroY)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            curveColor.withValues(alpha: 0.28),
            curveColor.withValues(alpha: 0.04),
          ],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      curve,
      Paint()
        ..color = curveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 节点小圆点：让「推子 ↔ 曲线」的对应关系更明确
    final Paint dot = Paint()..color = curveColor;
    for (final Offset point in points) {
      canvas.drawCircle(point, 2.6, dot);
    }
  }

  List<Offset> _points(Size size) {
    final double step = size.width / gains.length;
    return <Offset>[
      for (int index = 0; index < gains.length; index += 1)
        Offset(step * (index + 0.5), _yForGain(gains[index], size.height)),
    ];
  }

  /// 增益 → 纵坐标；上下各留 6px，避免顶到边
  double _yForGain(double gain, double height) {
    const double padding = 6;
    final double usable = height - padding * 2;
    final double ratio =
        (equalizerMaxGain - gain.clamp(-equalizerMaxGain, equalizerMaxGain)) /
        (equalizerMaxGain * 2);
    return padding + usable * ratio;
  }

  /// Catmull-Rom 转三次贝塞尔，曲线才平滑而不是折线
  Path _smoothPath(List<Offset> points) {
    final Path path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int index = 0; index < points.length - 1; index += 1) {
      final Offset p0 = index == 0 ? points[index] : points[index - 1];
      final Offset p1 = points[index];
      final Offset p2 = points[index + 1];
      final Offset p3 = index + 2 < points.length
          ? points[index + 2]
          : points[index + 1];
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(_CurvePainter oldDelegate) {
    return !sameEqGains(oldDelegate.gains, gains) ||
        oldDelegate.curveColor != curveColor ||
        oldDelegate.gridColor != gridColor;
  }
}

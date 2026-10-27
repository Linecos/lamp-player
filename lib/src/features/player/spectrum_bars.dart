import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 频谱柱：把 [bands] 里的 0~1 幅度画成一排圆角柱。
///
/// 只重绘自己（`RepaintBoundary` + `CustomPaint`）：30fps 刷新时不会带着
/// 播放条 / 歌词一起重建。
class SpectrumBars extends StatelessWidget {
  const SpectrumBars({
    super.key,
    required this.bands,
    this.height = 64,
    this.barWidth = 4,
    this.gap = 4,
    this.barCount,
    this.minBar = 2,
    this.stretch = false,
    this.color,
  });

  /// 各段幅度（0~1）；空列表表示没在放歌，什么都不画
  final ValueListenable<List<double>> bands;

  final double height;
  final double barWidth;
  final double gap;

  /// 最多画几根柱：段数比它多时按组取峰值（迷你条用）
  final int? barCount;

  /// 静音时也留一点高度，柱子在不在「立着」看得出来
  final double minBar;

  /// true 时按可用宽度均分柱子（大频谱铺满），false 时按 [barWidth] 定宽居中
  final bool stretch;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color tone = color ?? Theme.of(context).colorScheme.primary;
    final int? limit = barCount;
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        child: ValueListenableBuilder<List<double>>(
          valueListenable: bands,
          builder: (BuildContext context, List<double> values, Widget? _) {
            final List<double> shown = limit == null || values.length <= limit
                ? values
                : _pool(values, limit);
            return CustomPaint(
              size: Size.infinite,
              painter: _SpectrumPainter(
                values: shown,
                color: tone,
                barWidth: barWidth,
                gap: gap,
                minBar: minBar,
                stretch: stretch,
              ),
            );
          },
        ),
      ),
    );
  }

  /// 把 [values] 折成 [count] 组，每组取最大值：低频细节保留在左侧
  static List<double> _pool(List<double> values, int count) {
    final List<double> pooled = List<double>.filled(count, 0);
    for (int i = 0; i < count; i += 1) {
      final int start = (i * values.length / count).floor();
      final int end = ((i + 1) * values.length / count).ceil();
      double peak = 0;
      for (int at = start; at < end && at < values.length; at += 1) {
        if (values[at] > peak) {
          peak = values[at];
        }
      }
      pooled[i] = peak;
    }
    return pooled;
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.values,
    required this.color,
    required this.barWidth,
    required this.gap,
    required this.minBar,
    required this.stretch,
  });

  final List<double> values;
  final Color color;
  final double barWidth;
  final double gap;
  final double minBar;
  final bool stretch;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.height <= 0) {
      return;
    }
    final double step = barWidth + gap;
    final int fit = ((size.width + gap) / step).floor().clamp(1, values.length);
    // 定宽模式整体居中（窗口变宽时两侧一起留白）；
    // 铺满模式按可用宽度重算柱宽，让 24 根柱子撑满整行
    final double used = fit * step - gap;
    final double left = stretch ? 0 : (size.width - used) / 2;
    final double width = stretch
        ? ((size.width - gap * (fit - 1)) / fit).clamp(1.0, step * 2)
        : barWidth;
    final double advance = width + gap;
    final Paint paint = Paint()..isAntiAlias = true;

    for (int i = 0; i < fit; i += 1) {
      final double value = values[i].clamp(0.0, 1.0);
      final double barHeight = (size.height * value).clamp(minBar, size.height);
      final Rect rect = Rect.fromLTWH(
        left + i * advance,
        size.height - barHeight,
        width,
        barHeight,
      );
      // 从底部的实色渐变到顶部的浅色：矮柱子也不会糊成一团
      paint.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: <Color>[color, color.withValues(alpha: 0.45)],
      ).createShader(rect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(width / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.color != color ||
      oldDelegate.barWidth != barWidth ||
      oldDelegate.gap != gap ||
      oldDelegate.minBar != minBar ||
      oldDelegate.stretch != stretch;
}

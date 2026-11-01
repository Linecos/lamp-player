// 一次性诊断脚本：频谱柱「逐根 drawRRect」vs「分档 drawPath」的每帧代价。
//
//   flutter run -d windows --release -t tool/spectrum_bench.dart
//
// 三组：A 生产组件（现状）／B 不画频谱（基线）／C 分档批处理。
// A−B 是现在频谱的真实开销，C−B 是批处理版的开销。数字只用于组间比较。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lamp_player/src/features/player/spectrum_wave.dart';
import 'package:window_manager/window_manager.dart';

const double _w = 1600;
const double _h = 220;

class _Rec {
  final List<FrameTiming> frames = <FrameTiming>[];
  bool _on = false;

  void start() {
    frames.clear();
    if (_on) {
      return;
    }
    _on = true;
    SchedulerBinding.instance.addTimingsCallback(frames.addAll);
  }

  void stop() {
    if (!_on) {
      return;
    }
    _on = false;
    SchedulerBinding.instance.removeTimingsCallback(frames.addAll);
  }

  String report() {
    if (frames.isEmpty) {
      return '无采样';
    }
    final List<int> rasters = <int>[
      for (final FrameTiming t in frames) t.rasterDuration.inMicroseconds,
    ]..sort();
    double mean(List<int> v) => v.reduce((int a, int b) => a + b) / v.length;
    int p(List<int> v, double q) =>
        v[(v.length * q).floor().clamp(0, v.length - 1)];
    String ms(num us) => (us / 1000).toStringAsFixed(2);
    return '帧 ${frames.length}｜raster 均 ${ms(mean(rasters))} '
        'P50 ${ms(p(rasters, 0.5))} P95 ${ms(p(rasters, 0.95))} '
        '最大 ${ms(rasters.last)}';
  }
}

// ---------------------------------------------------------------- 生产组件（A）

// ---------------------------------------------------------------- 分档版（C）

/// 分档批处理：同档柱子的 RRect 攒进一条 Path，一次 drawPath 画完。
class BatchedBars extends CustomPainter {
  BatchedBars({required this.values, required this.colors});

  final List<double> values;
  final List<Color> colors;

  static const double _barWidth = 4.5;
  static const double _gap = 4.5;
  static const double _minBar = 1.5;
  static const int _tintBuckets = 16;
  static const int _alphaLevels = 16;

  static final List<Path> _body = List<Path>.generate(
    _tintBuckets * _alphaLevels,
    (_) => Path(),
  );
  static final List<Path> _top = List<Path>.generate(
    _tintBuckets * _alphaLevels,
    (_) => Path(),
  );
  static final Uint8List _bodyUsed = Uint8List(_tintBuckets * _alphaLevels);
  static final Uint8List _topUsed = Uint8List(_tintBuckets * _alphaLevels);
  static final Int32List _bucketRgb = Int32List(_tintBuckets);
  static List<Color>? _bucketColors;

  /// pow(v, 1.1) 查表
  static final Float64List _gain = Float64List(257)
    ..setAll(0, <double>[
      for (int i = 0; i <= 256; i += 1) math.pow(i / 256, 1.1).toDouble(),
    ]);

  static final Paint _paint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width < 4 || size.height < 4) {
      return;
    }
    final double step = _barWidth + _gap;
    final int count = (size.width / step).ceil().clamp(4, 512);
    final double bar = math.max(1.0, (size.width - _gap * (count - 1)) / count);
    final double maxHeight = math.min(size.height, _h);
    final int last = values.length - 1;

    if (!listEquals(_bucketColors, colors)) {
      _bucketColors = List<Color>.unmodifiable(colors);
      for (int b = 0; b < _tintBuckets; b += 1) {
        _bucketRgb[b] =
            _tint(colors, (b + 0.5) / _tintBuckets).toARGB32() & 0x00FFFFFF;
      }
    }
    for (int i = 0; i < _body.length; i += 1) {
      _body[i].reset();
      _top[i].reset();
    }
    _bodyUsed.fillRange(0, _bodyUsed.length, 0);
    _topUsed.fillRange(0, _topUsed.length, 0);

    for (int i = 0; i < count; i += 1) {
      final double t = count == 1 ? 0 : i / (count - 1);
      final double value = _sample(values, last * t).clamp(0.0, 1.0);
      final double weight = 0.30 + 0.70 * math.sin(math.pi * t);
      final double height = math.max(
        _minBar,
        maxHeight * _gain[(value * 256).round()] * weight,
      );
      final double top = size.height - height;
      final double x = i * (bar + _gap);
      final double alpha = (0.26 + 0.40 * value) * _edgeFade(t);
      final int bucket = (t * _tintBuckets).floor().clamp(0, _tintBuckets - 1);
      final int slot = bucket * _alphaLevels + _alphaLevel(alpha);
      _body[slot].addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, bar, height),
          Radius.circular(bar / 2),
        ),
      );
      _bodyUsed[slot] = 1;
      if (height > 3) {
        final int topSlot =
            bucket * _alphaLevels + _alphaLevel(math.min(1.0, alpha * 1.45));
        _top[topSlot].addRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, top, bar, math.min(2.2, height * 0.35)),
            Radius.circular(bar / 2),
          ),
        );
        _topUsed[topSlot] = 1;
      }
    }

    for (int slot = 0; slot < _body.length; slot += 1) {
      final int bucket = slot ~/ _alphaLevels;
      final int level = slot % _alphaLevels;
      final int rgb = _bucketRgb[bucket];
      if (_bodyUsed[slot] != 0) {
        _paint.color = Color((_alphaByte(_levelAlpha(level)) << 24) | rgb);
        canvas.drawPath(_body[slot], _paint);
      }
      if (_topUsed[slot] != 0) {
        _paint.color = Color(
          (_alphaByte(math.min(1.0, _levelAlpha(level) * 1.45)) << 24) | rgb,
        );
        canvas.drawPath(_top[slot], _paint);
      }
    }
  }

  static int _alphaLevel(double alpha) =>
      (alpha.clamp(0.0, 1.0) * _alphaLevels).floor().clamp(0, _alphaLevels - 1);

  static double _levelAlpha(int level) => (level + 0.5) / _alphaLevels;

  static int _alphaByte(double a) => (a.clamp(0.0, 1.0) * 255).round() & 0xFF;

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

  static Color _tint(List<Color> colors, double t) {
    if (t <= 0.55) {
      return Color.lerp(colors[0], colors[1], t / 0.55)!;
    }
    return Color.lerp(colors[1], colors[2], (t - 0.55) / 0.45)!;
  }

  static double _sample(List<double> values, double t) {
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
  bool shouldRepaint(BatchedBars old) => !listEquals(old.values, values);
}

// ---------------------------------------------------------------- 驾驶

class _Bench extends StatefulWidget {
  const _Bench();

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final ValueNotifier<List<double>> _bands = ValueNotifier<List<double>>(
    const <double>[],
  );
  final _Rec _rec = _Rec();
  Timer? _feeder;
  String _mode = 'A';
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _feeder = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _tick += 1;
      _bands.value = <double>[
        for (int i = 0; i < 24; i += 1)
          (0.5 + 0.45 * math.sin(_tick * 0.35 + i * 0.4)).clamp(0.02, 1.0),
      ];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final String mode in <String>['A', 'B', 'C', 'A', 'B', 'C']) {
      setState(() => _mode = mode);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      _rec.start();
      await Future<void>.delayed(const Duration(seconds: 2));
      _rec.stop();
      debugPrint('BENCH $mode: ${_rec.report()}');
    }
    exit(0);
  }

  @override
  void dispose() {
    _feeder?.cancel();
    _bands.dispose();
    super.dispose();
  }

  Widget _layer() {
    return switch (_mode) {
      'B' => const SizedBox.expand(),
      // 必须跟着 bands 重建，否则分档版一帧都不重画 -> 采不到帧
      'C' => ValueListenableBuilder<List<double>>(
        valueListenable: _bands,
        builder: (BuildContext context, List<double> values, Widget? _) =>
            CustomPaint(
              size: const Size(_w, _h),
              painter: BatchedBars(
                values: values,
                colors: const <Color>[
                  Color(0xFF7C6BF5),
                  Color(0xFFB36BF5),
                  Color(0xFFF56BE0),
                ],
              ),
            ),
      ),
      _ => SpectrumWave(
        bands: _bands,
        height: _h,
        color: const Color(0xFF7C6BF5),
        colorMid: const Color(0xFFB36BF5),
        colorEnd: const Color(0xFFF56BE0),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF15151C),
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(width: _w, height: _h, child: _layer()),
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const WindowOptions options = WindowOptions(
    size: Size(1680, 400),
    center: true,
    title: 'spectrum-bench',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(true);
  });
  runApp(const _Bench());
}

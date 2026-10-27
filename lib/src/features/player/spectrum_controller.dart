import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rust/api/player.dart' as rust;

/// 频谱数据源：全局单例，按「有谁在看」开关注释掉的 frb 流。
///
/// 引擎线程每 33ms 算一帧（24 段，0~1），这里只做视觉平滑：上升立刻跟上、
/// 回落慢一点，柱子才不会一闪一闪。没人看时立刻停流，避免空转。
class SpectrumController {
  SpectrumController._();

  static final SpectrumController instance = SpectrumController._();

  /// 平滑后的各段幅度；没在放歌时是空列表
  final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
    const <double>[],
  );

  StreamSubscription<Float32List>? _subscription;
  int _refs = 0;
  List<double> _smoothed = const <double>[];

  /// 下落速度：每帧保留上一帧的 0.72，视觉上是「余韵」而不是「抖」
  static const double _decay = 0.72;

  /// 有人开始看频谱
  void attach() {
    _refs += 1;
    if (_refs == 1) {
      _start();
    }
  }

  /// 没人看了：停流并把柱子清空，下次开局不会先闪一帧旧数据
  void detach() {
    if (_refs == 0) {
      return;
    }
    _refs -= 1;
    if (_refs == 0) {
      _stop();
    }
  }

  void _start() {
    try {
      _subscription = rust.playerSpectrumStream().listen(
        _onFrame,
        onError: (Object _) => _stop(),
        cancelOnError: true,
      );
    } catch (_) {
      // 引擎不可用（非 Windows / DLL 缺失）：不显示频谱，别影响播放
      _stop();
    }
  }

  void _stop() {
    final StreamSubscription<Float32List>? subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _smoothed = const <double>[];
    if (bands.value.isNotEmpty) {
      bands.value = const <double>[];
    }
  }

  void _onFrame(Float32List frame) {
    if (frame.isEmpty) {
      return;
    }
    if (_smoothed.length != frame.length) {
      _smoothed = List<double>.filled(frame.length, 0);
    }
    final List<double> next = List<double>.filled(frame.length, 0);
    for (int i = 0; i < frame.length; i += 1) {
      final double value = frame[i].clamp(0.0, 1.0);
      final double previous = _smoothed[i] * _decay;
      next[i] = value > previous ? value : previous;
    }
    _smoothed = next;
    bands.value = next;
  }
}

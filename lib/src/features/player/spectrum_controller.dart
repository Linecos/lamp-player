import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rust/api/player.dart' as rust;

/// 打开一条频谱流（引擎侧线程按 33ms 推帧）
typedef SpectrumSource = Stream<Float32List> Function();

/// 取一帧频谱快照（走普通 frb 调用）
typedef SpectrumSampler = Future<Float32List> Function();

/// 频谱数据源：全局单例，按「有谁在看」开关数据采集。
///
/// 引擎线程每 33ms 算一帧（24 段，0~1），这里只做三件事：
/// 1. 视觉平滑：起音立刻跟上、回落慢一点，波形才不会抽搐；
/// 2. **流挂了会自愈**：报错按 400ms→4s 退避重连，2.1 秒收不到帧就换一条；
/// 3. **流不争气就改轮询**：[streamGrace] 内一帧有效数据都没有（引擎侧推流
///    失败、StreamSink 建不起来）时，退化成每 [pollInterval] 调一次
///    `player_spectrum()`。两条路都走不通才会真的没有波形——以前只有第一条
///    路，挂了就永远停在空列表里，表现就是「在放歌但波浪不动」。
class SpectrumController {
  SpectrumController._()
    : _open = rust.playerSpectrumStream,
      _sample = rust.playerSpectrum;

  /// 测试用：注入自己的流 / 采样函数，不碰 Rust
  @visibleForTesting
  SpectrumController.withSource(SpectrumSource open, {SpectrumSampler? sample})
    : _open = open,
      _sample = sample ?? _emptySample;

  static Future<Float32List> _emptySample() async => Float32List(0);

  /// 全局单例：曲库页订阅、正在播放页只读同一份数据
  static final SpectrumController instance = SpectrumController._();

  final SpectrumSource _open;
  final SpectrumSampler _sample;

  /// 平滑后的各段幅度；没在放歌时是空列表
  final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
    const <double>[],
  );

  /// 起音系数：鼓点一敲就得升上去
  static const double _attack = 0.75;

  /// 回落系数：每帧回 30%，30fps 下约 0.15 秒落到一半。
  /// 柱子要靠这个「掉下来」才有跳动感，太慢会像在飘
  static const double _release = 0.30;

  /// 多久没收到帧就认为流僵死（正常 33ms 一帧）。
  ///
  /// 用「看门狗空转了几次」判断而不是记时间戳：帧本身就是定时推的，
  /// 数空转次数不受系统时间跳变影响，也能在测试的虚拟时钟里跑。
  static final Duration stallTimeout = _watchdogInterval * _stallTicks;

  /// 看门狗检查间隔
  static const Duration _watchdogInterval = Duration(milliseconds: 700);

  /// 连续几次检查都没有新帧就重连（约 2.1 秒）
  static const int _stallTicks = 3;

  /// 流启动后多久还没有有效帧就改轮询
  static const Duration streamGrace = Duration(milliseconds: 1600);

  /// 轮询间隔，与引擎侧推帧频率一致
  static const Duration pollInterval = Duration(milliseconds: 33);

  /// 重连退避：400ms → 800ms → … → 4s
  static const Duration _retryMin = Duration(milliseconds: 400);
  static const Duration _retryMax = Duration(seconds: 4);

  /// 全零帧连续多少帧后重启一次（约 5 秒）：静音段也会有零帧，
  /// 但真实音频不会有「24 段全部严格为 0」持续 5 秒
  static const int _silentFramesBeforeRestart = 150;

  StreamSubscription<Float32List>? _subscription;
  Timer? _watchdog;
  Timer? _retryTimer;
  Timer? _graceTimer;
  Timer? _pollTimer;
  Duration _retryDelay = _retryMin;

  /// 累计收到的帧数；看门狗靠它的增量判断流是不是停了
  int _frames = 0;
  int _framesSeen = 0;
  int _idleTicks = 0;
  int _silentFrames = 0;
  int _refs = 0;
  bool _polling = false;
  bool _sampling = false;

  /// 这一轮有没有收到过「有内容」的帧（全零不算）
  bool _sawSignal = false;

  List<double> _smoothed = const <double>[];

  /// 是否正在采集（测试用）
  bool get isListening => _subscription != null || _polling;

  /// 是否已经退化成轮询（测试用）
  bool get isPolling => _polling;

  /// 有人开始看频谱
  void attach() {
    _refs += 1;
    // 不能只看 `_refs == 1`：流如果在上一次看的过程中挂掉过，
    // `_subscription` 已经是 null，但 `_refs` 还停在上一次的值上
    if (_subscription == null && !_polling) {
      _start();
    }
    _startWatchdog();
  }

  /// 没人看了：停采集并把波形清空，下次开局不会先闪一帧旧数据
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
    if (_refs == 0) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _framesSeen = _frames;
    _idleTicks = 0;
    try {
      _subscription = _open().listen(
        _onFrame,
        onError: (Object _) => _onBroken(),
        onDone: _onBroken,
        cancelOnError: true,
      );
    } catch (_) {
      // 引擎不可用（非 Windows / DLL 缺失）：不显示频谱，别影响播放
      _onBroken();
    }
    _armGrace();
  }

  /// 流启动后盯着它：一直没出有效帧就别耗着了，改轮询
  void _armGrace() {
    _graceTimer?.cancel();
    _sawSignal = false;
    _graceTimer = Timer(streamGrace, () {
      _graceTimer = null;
      if (_refs == 0 || _polling || _sawSignal) {
        return;
      }
      _startPolling();
    });
  }

  void _startPolling() {
    if (_polling || _refs == 0) {
      return;
    }
    _polling = true;
    _graceTimer?.cancel();
    _graceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final StreamSubscription<Float32List>? stream = _subscription;
    _subscription = null;
    unawaited(stream?.cancel());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _sampleOnce());
    _sampleOnce();
    assert(() {
      debugPrint('频谱流没有出帧，已切换为轮询（playerSpectrum，每 33ms 一次）');
      return true;
    }());
  }

  void _sampleOnce() {
    if (_sampling || _refs == 0) {
      return;
    }
    _sampling = true;
    _sample().then(
      (Float32List frame) {
        _sampling = false;
        if (_refs == 0) {
          return;
        }
        _onFrame(frame);
      },
      onError: (Object _) {
        _sampling = false;
      },
    );
  }

  /// 流断了：按退避重连，不清空已有数据（避免一帧闪没）
  void _onBroken() {
    if (_refs == 0 || _polling) {
      return;
    }
    final StreamSubscription<Float32List>? broken = _subscription;
    _subscription = null;
    unawaited(broken?.cancel());
    _retryTimer?.cancel();
    final Duration delay = _retryDelay;
    _retryDelay = _retryDelay * 2 > _retryMax ? _retryMax : _retryDelay * 2;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _start();
    });
  }

  void _startWatchdog() {
    _watchdog ??= Timer.periodic(_watchdogInterval, (_) => _check());
  }

  void _check() {
    if (_refs == 0) {
      return;
    }
    if (_polling) {
      return;
    }
    if (_subscription == null) {
      // 重连计时器在跑就让它跑，别把退避绕过去
      if (_retryTimer == null) {
        _start();
      }
      return;
    }
    if (_framesSeen == _frames) {
      _idleTicks += 1;
      if (_idleTicks >= _stallTicks) {
        // 没报错但不再出帧：当作僵死，换一条新流
        _restart();
      }
      return;
    }
    _framesSeen = _frames;
    _idleTicks = 0;
  }

  /// 主动丢掉当前流并立刻重连（僵死 / 全零帧）
  ///
  /// [resetSilence] 为 false 时保留静默计数：全零帧重启只做一次，
  /// 直到真的重新收到有内容的帧才归零
  void _restart({bool resetSilence = true}) {
    final StreamSubscription<Float32List>? stale = _subscription;
    _subscription = null;
    unawaited(stale?.cancel());
    _framesSeen = _frames;
    _idleTicks = 0;
    if (resetSilence) {
      _silentFrames = 0;
    }
    _start();
  }

  void _stop() {
    _watchdog?.cancel();
    _watchdog = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _retryDelay = _retryMin;
    _polling = false;
    _sampling = false;
    _sawSignal = false;
    final StreamSubscription<Float32List>? subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _smoothed = const <double>[];
    _silentFrames = 0;
    if (bands.value.isNotEmpty) {
      bands.value = const <double>[];
    }
  }

  void _onFrame(Float32List frame) {
    if (frame.isEmpty || _refs == 0) {
      return;
    }
    _frames += 1;
    if (_silentFrames == 0) {
      // 收到有内容的帧才算「这一轮连上了」，退避重置
      _retryDelay = _retryMin;
    }
    if (_smoothed.length != frame.length) {
      _smoothed = List<double>.filled(frame.length, 0);
    }
    final List<double> next = List<double>.filled(frame.length, 0);
    double loudest = 0;
    for (int i = 0; i < frame.length; i += 1) {
      final double value = frame[i].clamp(0.0, 1.0);
      final double previous = _smoothed[i];
      final double coefficient = value > previous ? _attack : _release;
      final double smoothed = previous + (value - previous) * coefficient;
      next[i] = smoothed;
      if (smoothed > loudest) {
        loudest = smoothed;
      }
    }
    _smoothed = next;
    bands.value = next;

    if (loudest < 0.001) {
      if (_polling) {
        // 轮询拿到全零就是真的没声音，不必重启任何东西
        return;
      }
      _silentFrames += 1;
      if (_silentFrames == 60) {
        // 两秒全是 0：数据到了，但引擎没在出声（独占被抢 / 静音 / 设备不对）
        assert(() {
          debugPrint('频谱连续 2 秒全是 0：引擎可能没有输出（检查独占模式、静音、输出设备）');
          return true;
        }());
      }
      if (_silentFrames == _silentFramesBeforeRestart) {
        // 只重启一次：真的没声音时不至于每 5 秒拉一条新流
        _restart(resetSilence: false);
      }
      return;
    }
    _silentFrames = 0;
    if (!_sawSignal) {
      _sawSignal = true;
      _graceTimer?.cancel();
      _graceTimer = null;
      assert(() {
        debugPrint('频谱开始出帧（首帧峰值 ${loudest.toStringAsFixed(3)}）');
        return true;
      }());
    }
  }
}

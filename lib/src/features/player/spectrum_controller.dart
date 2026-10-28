import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rust/api/player.dart' as rust;

/// 频谱数据源：全局单例，按「有谁在看」开关注释掉的 frb 流。
///
/// 引擎线程每 33ms 算一帧（24 段，0~1），这里只做两件事：
/// 1. 视觉平滑：起音立刻跟上、回落慢一点，丝带才不会抽搐；
/// 2. **自愈**：流挂掉（引擎刚启动还没就绪、命令超时、线程退出）时按退避
///    重连，帧停了超过 [stallTimeout] 也重连。以前一次失败就再也不重启，
///    界面表现为「波浪不动」或者「点进去什么都没有」。
/// 打开一条频谱流；测试注入假实现，生产环境走 frb
typedef SpectrumSource = Stream<Float32List> Function();

class SpectrumController {
  SpectrumController._() : _open = rust.playerSpectrumStream;

  /// 测试用：注入自己的流，不碰 Rust
  @visibleForTesting
  SpectrumController.withSource(SpectrumSource open) : _open = open;

  final SpectrumSource _open;

  static final SpectrumController instance = SpectrumController._();

  /// 平滑后的各段幅度；没在放歌时是空列表
  final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
    const <double>[],
  );

  /// 起音系数：鼓点一敲就得升上去
  static const double _attack = 0.65;

  /// 回落系数：每帧只回 16%，30fps 下约 0.4 秒落到一半
  static const double _release = 0.16;

  /// 多久没收到帧就认为流僵死（正常 33ms 一帧）。
  ///
  /// 用「看门狗空转了几次」判断而不是记时间戳：帧本身就是定时推的，
  /// 数空转次数不受系统时间跳变影响，也能在测试的虚拟时钟里跑。
  static final Duration stallTimeout = _watchdogInterval * _stallTicks;

  /// 看门狗检查间隔
  static const Duration _watchdogInterval = Duration(milliseconds: 700);

  /// 连续几次检查都没有新帧就重连（约 2.1 秒）
  static const int _stallTicks = 3;

  /// 重连退避：400ms → 800ms → … → 4s
  static const Duration _retryMin = Duration(milliseconds: 400);
  static const Duration _retryMax = Duration(seconds: 4);

  /// 全零帧连续多少帧后重启一次（约 5 秒）：静音段也会有零帧，
  /// 但真实音频不会有「24 段全部严格为 0」持续 5 秒
  static const int _silentFramesBeforeRestart = 150;

  StreamSubscription<Float32List>? _subscription;
  Timer? _watchdog;
  Timer? _retryTimer;
  Duration _retryDelay = _retryMin;

  /// 累计收到的帧数；看门狗靠它的增量判断流是不是停了
  int _frames = 0;
  int _framesSeen = 0;
  int _idleTicks = 0;
  int _silentFrames = 0;
  int _refs = 0;
  List<double> _smoothed = const <double>[];

  /// 是否正在收帧（测试用）
  bool get isListening => _subscription != null;

  /// 有人开始看频谱
  void attach() {
    _refs += 1;
    // 不能只看 `_refs == 1`：流如果在上一次看的过程中挂掉过，
    // `_subscription` 已经是 null，但 `_refs` 还停在上一次的值上
    if (_subscription == null) {
      _start();
    }
    _startWatchdog();
  }

  /// 没人看了：停流并把丝带清空，下次开局不会先闪一帧旧数据
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
  }

  /// 流断了：按退避重连，不清空已有数据（避免一帧闪没）
  void _onBroken() {
    if (_refs == 0) {
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
    _retryDelay = _retryMin;
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
      _silentFrames += 1;
      if (_silentFrames == _silentFramesBeforeRestart) {
        // 只重启一次：真的没声音时不至于每 5 秒拉一条新流
        _restart(resetSilence: false);
        return;
      }
    } else {
      _silentFrames = 0;
    }
  }
}

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// 装饰动画的统一节拍。
///
/// Flutter 在 Windows 上按显示器刷新率出帧：只要有一个 [AnimationController]
/// 在 repeat，引擎就会一直以刷新率出帧。240Hz 屏上流光背景、封面旋转、逐字
/// 歌词染色都会按 240fps 重绘整页 —— 这些慢速动画用不上这个帧率，白烧 CPU
/// （实测正在播放页单核 92%，换成定时器驱动后约 26%）。
///
/// 用定时器而不是 Ticker：没人监听时定时器直接停，连「空帧」都不出。
/// 时间源用 `package:clock` 而不是 `Stopwatch`：widget 测试里 fake_async 会把
/// `clock` 换成假时钟，`tester.pump(6s)` 才能推动动画。
///
/// 分三档，但**只有一个定时器**：
/// * [fast]（60fps）——封面旋转这类对时间分辨率敏感的动作，15fps 看得出一顿一顿；
/// * [instance]（30fps）——逐字歌词染色、频谱柱，需要跟手；
/// * [slow]（15fps）——流光背景，本身就是缓慢漂移，低帧率看不出来。
///
/// 定时器周期按「有没有 [fast] 监听」切换：只有 60fps 档在用时才按 16ms 跑，
/// 否则按 33ms 跑（此时 30fps 档每拍、15fps 档每两拍通知）。三档必须同源：
/// 以前各开一个 `Timer.periodic`，两个定时器相位错开，30fps + 15fps 实际会要出
/// 2~3 倍于 30fps 的帧（每拍都可能落在上一帧的绘制过程中，于是引擎再补一帧）。
/// 同一拍里通知完各档，一帧就能画完。
class UiClock extends ChangeNotifier {
  UiClock._();

  /// 60fps：时间分辨率敏感的动画（封面旋转）
  static final UiClock fast = UiClock._();

  /// 30fps：跟手的动画（逐字歌词、频谱）
  static final UiClock instance = UiClock._();

  /// 15fps：慢速装饰动画（流光背景）
  static final UiClock slow = UiClock._();

  /// 基准节拍（30fps）；测试里用它推进虚拟时间。
  static const Duration interval = Duration(milliseconds: 33);

  /// 有 [fast] 监听时的节拍（60fps）
  static const Duration fastInterval = Duration(milliseconds: 16);

  /// 所有档共用同一个零点：跨档比较 [seconds] 才有意义
  static final DateTime _epoch = clock.now();

  /// 唯一的定时器。**三档共用**，所以状态必须是静态的：写成实例字段的话
  /// `slow.addListener` 会在 `slow` 上另起一个定时器（两档各跑一份，帧数翻倍）
  static Timer? _timer;

  /// 当前定时器周期；null 表示没在跑
  static Duration? _armed;

  /// 当前周期里跳了几拍：各档按拍数取模通知
  static int _ticks = 0;

  /// 时钟启动以来的秒数：动画相位用它算，别自己再攒一份时间。
  double get seconds => clock.now().difference(_epoch).inMicroseconds / 1000000;

  bool get _hasAnyListener =>
      instance.hasListeners || slow.hasListeners || fast.hasListeners;

  /// 有 60fps 监听就按 16ms 跑，否则回到 33ms
  Duration get _wantedInterval => fast.hasListeners ? fastInterval : interval;

  void _arm() {
    final Duration want = _wantedInterval;
    if (_armed == want && _timer != null) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (!_hasAnyListener) {
      _armed = null;
      _ticks = 0;
      return;
    }
    _armed = want;
    // 换周期时拍数归零：各档的相位重新对齐
    _ticks = 0;
    _timer = Timer.periodic(want, (_) => _tick());
  }

  void _tick() {
    _ticks += 1;
    // 16ms 周期下：60fps 每拍、30fps 每 2 拍、15fps 每 4 拍
    // 33ms 周期下：30fps 每拍、15fps 每 2 拍
    final bool fastClock = _armed == fastInterval;
    if (fastClock && fast.hasListeners) {
      fast.notifyListeners();
    }
    if (_ticks % (fastClock ? 2 : 1) == 0) {
      instance.notifyListeners();
    }
    if (_ticks % (fastClock ? 4 : 2) == 0 && slow.hasListeners) {
      slow.notifyListeners();
    }
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    // 三档共用同一个定时器：谁先被监听都由它起表（必要时换周期）
    _arm();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_hasAnyListener) {
      _arm();
      return;
    }
    _timer?.cancel();
    _timer = null;
    _armed = null;
    _ticks = 0;
  }
}

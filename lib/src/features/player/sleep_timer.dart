import 'dart:async';

import 'package:flutter/foundation.dart';

/// 睡眠定时：到点自动暂停。
///
/// 这个状态以前挂在 `NowPlayingPage` 的 State 上，而那个页面的 `dispose()`
/// 里会 `_sleepTimer.cancel()` —— 设完定时按 Esc 回曲库继续听，定时就没了；
/// 可「边听边睡」恰恰是关掉界面之后才需要它生效。现在由曲库页持有（那层
/// 到进程结束都不销毁），播放页只负责弹窗与按钮。
class SleepTimer extends ChangeNotifier {
  SleepTimer({
    required this._isPlaying,
    required this._position,
    required this._duration,
    required this._pause,
    this._onFired,
  });

  final bool Function() _isPlaying;
  final double Function() _position;
  final double Function() _duration;
  final Future<void> Function() _pause;
  final void Function(String message)? _onFired;

  Timer? _timer;

  /// 到点时刻；null 表示未开启
  DateTime? _until;

  /// 本轮定时是否已经为「听完当前曲目」顺延过一次
  bool _extended = false;

  /// 到点时若本曲没播完，是否顺延到播完（浮窗里的开关，默认开）
  bool extendToTrackEnd = true;

  /// 到点时刻；null 表示未开启
  DateTime? get until => _until;

  bool get active => _until != null;

  /// 浮窗回填用的剩余分钟数；未开启为 null
  int? get remainingMinutes {
    final DateTime? until = _until;
    if (until == null) {
      return null;
    }
    return (until.difference(DateTime.now()).inSeconds / 60).ceil().clamp(
      1,
      60,
    );
  }

  /// 按钮提示：还剩几分钟 / 正在等这首放完
  String get tooltip {
    final DateTime? until = _until;
    if (until == null) {
      return '睡眠定时';
    }
    final Duration left = until.difference(DateTime.now());
    if (left.inSeconds <= 0) {
      return '睡眠定时：即将暂停';
    }
    final int minutes = (left.inSeconds / 60).ceil();
    return _extended ? '睡眠定时：播完当前曲目后暂停' : '睡眠定时：还剩 $minutes 分钟';
  }

  /// 重新计时；[delay] 为 0（或负值）等于取消
  void arm(Duration delay) {
    _timer?.cancel();
    _timer = null;
    // 重新设定后允许再顺延一次
    _extended = false;
    if (delay <= Duration.zero) {
      _until = null;
      notifyListeners();
      return;
    }
    _timer = Timer(delay, _fire);
    _until = DateTime.now().add(delay);
    notifyListeners();
  }

  void cancel() => arm(Duration.zero);

  /// 到点：正在播就暂停（不停止，醒来点一下就能接着听）。
  ///
  /// 当前曲目还没播完就不掐：先把这首听完再暂停，只顺延一次——顺延到点后
  /// 哪怕用户又拖回前段也直接暂停，免得变成永远不睡。
  void _fire() {
    _timer = null;
    // 时长取播放器上报的值，不是标签里的 durationSecs：后者可能还没解析出来，
    // 会让顺延判断失效
    final double duration = _duration();
    final double left = duration - _position();
    if (extendToTrackEnd &&
        !_extended &&
        _isPlaying() &&
        duration > 0 &&
        left > 1) {
      _extended = true;
      final Duration rest = Duration(milliseconds: (left * 1000).round() + 200);
      _timer = Timer(rest, _fire);
      _until = DateTime.now().add(rest);
      notifyListeners();
      return;
    }
    final bool wasPlaying = _isPlaying();
    _extended = false;
    _until = null;
    notifyListeners();
    if (wasPlaying) {
      unawaited(_pauseSafely());
    }
    _onFired?.call('睡眠定时已到，已暂停播放');
  }

  /// 暂停失败只影响「该睡没睡」，不该变成未处理异常
  Future<void> _pauseSafely() async {
    try {
      await _pause();
    } catch (error) {
      debugPrint('睡眠定时暂停失败：$error');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

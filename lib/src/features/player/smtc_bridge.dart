import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rust/api/media.dart' as media;
import 'playback_queue.dart';

/// 播放状态（只保留 SMTC 关心的三种，页面不必依赖生成的 `MediaPlayState`）
enum MediaSessionState { playing, paused, stopped }

/// 把播放状态同步到 Windows 系统媒体控制（SMTC），并把系统按钮转成播放动作。
///
/// - 键盘媒体键、耳机线控、任务栏缩略图按钮 → [onPlay] / [onPause] / ...
/// - 当前曲目与播放状态 → Windows 音量浮层、锁屏信息
///
/// 非 Windows 或系统不支持时 [start] 静默失败，其余方法都退化为空操作：
/// 「系统浮层没出来」绝不能影响播放本身。
class SmtcBridge {
  SmtcBridge({
    required this.onPlay,
    required this.onPause,
    required this.onNext,
    required this.onPrevious,
    required this.onStop,
    required this.onRepeatChanged,
    required this.onShuffleChanged,
  });

  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onStop;

  /// 系统浮层里改了循环（顺序 / 列表 / 单曲）
  final void Function(LoopMode repeat) onRepeatChanged;

  /// 系统浮层里改了随机开关
  final void Function(bool shuffle) onShuffleChanged;

  StreamSubscription<media.MediaCommand>? _subscription;
  bool _available = false;
  bool _starting = false;

  /// 上一次**成功**上报的曲目路径：同一首不重复上传封面（WinRT 那边要拷一份图片）
  String? _lastPath;

  /// 失败的那一首与已失败次数：失败后允许重试，同一首连败 3 次就不再纠缠，
  /// 免得每次播放状态变化都触发一次必定失败的 WinRT 调用
  String? _failedPath;
  int _failedCount = 0;

  bool get available => _available;

  Future<void> start() async {
    // 整个流程都要包住：widget 测试里 Rust 桥接没初始化，
    // `mediaIsSupported()` 这类同步调用会直接抛 StateError。
    try {
      if (!media.mediaIsSupported()) {
        return;
      }
      await media.mediaInit();
      _subscription = media.mediaCommands().listen(_handleCommand);
      _available = true;
    } catch (_) {
      // 非 Windows、系统禁用 SMTC、或 widget 测试里桥接未初始化：
      // 都只是「没有系统浮层」，不影响播放，也不需要打扰日志
    }
  }

  /// 初始化失败后重试一次：`start()` 只在页面创建时调过一次，失败就
  /// `_available` 一直 false，媒体键到重启前都无效。Rust 侧 `media_init` 幂等，
  /// 反复调用没有副作用；用 `_starting` 挡住并发重入。
  Future<void> _ensureStarted() async {
    if (_available || _starting) {
      return;
    }
    _starting = true;
    try {
      await start();
    } finally {
      _starting = false;
    }
  }

  Future<void> updateTrack({
    required String path,
    required String title,
    String? artist,
    String? album,
    String? coverPath,
  }) async {
    if (!_available) {
      await _ensureStarted();
    }
    if (!_available || path == _lastPath) {
      return;
    }
    if (path == _failedPath && _failedCount >= _maxTrackFailures) {
      return;
    }
    try {
      await media.mediaSetTrack(
        title: title,
        artist: artist ?? '',
        album: album ?? '',
        coverPath: coverPath,
      );
      // 只在成功时记账：失败留着重试，否则这一首在系统浮层里永远是上一首
      _lastPath = path;
      _failedPath = null;
      _failedCount = 0;
    } catch (error) {
      _failedCount = path == _failedPath ? _failedCount + 1 : 1;
      _failedPath = path;
      debugPrint('更新系统曲目信息失败：$error');
    }
  }

  /// 同一首连续失败多少次后不再重试
  static const int _maxTrackFailures = 3;

  Future<void> setState(MediaSessionState state) async {
    if (!_available) {
      await _ensureStarted();
    }
    if (!_available) {
      return;
    }
    final media.MediaPlayState mapped = switch (state) {
      MediaSessionState.playing => media.MediaPlayState.playing,
      MediaSessionState.paused => media.MediaPlayState.paused,
      MediaSessionState.stopped => media.MediaPlayState.stopped,
    };
    try {
      await media.mediaSetState(state: mapped);
    } catch (error) {
      debugPrint('同步系统播放状态失败：$error');
    }
  }

  Future<void> clear() async {
    if (!_available) {
      return;
    }
    _lastPath = null;
    _failedPath = null;
    _failedCount = 0;
    try {
      await media.mediaClear();
    } catch (error) {
      debugPrint('清理系统媒体信息失败：$error');
    }
  }

  /// 把循环 / 随机同步给系统浮层。
  ///
  /// 不只是显示：Windows 的循环、随机按钮要在会话里报过这两个属性之后才可点，
  /// 之前一直不报，浮层里那颗按钮就是灰的、按不动。
  Future<void> setPlayMode({
    required LoopMode repeat,
    required bool shuffle,
  }) async {
    if (!_available) {
      await _ensureStarted();
    }
    if (!_available) {
      return;
    }
    final media.MediaRepeatMode mapped = switch (repeat) {
      LoopMode.off => media.MediaRepeatMode.off,
      LoopMode.all => media.MediaRepeatMode.all,
      LoopMode.one => media.MediaRepeatMode.one,
    };
    try {
      await media.mediaSetPlayMode(repeat: mapped, shuffle: shuffle);
    } catch (error) {
      debugPrint('同步系统播放模式失败：$error');
    }
  }

  void _handleCommand(media.MediaCommand command) {
    // 命令回调是同步的、动作是异步的：不接异常的话，播放服务里抛出的错误
    // 会以「未处理的异步异常」进 zone，日志里只剩一段没有上下文的堆栈。
    void run(Future<void> Function() action) {
      unawaited(
        action().catchError((Object error) {
          debugPrint('执行系统媒体命令失败：$error');
        }),
      );
    }

    switch (command) {
      case media.MediaCommand.play:
        run(onPlay);
      case media.MediaCommand.pause:
        run(onPause);
      case media.MediaCommand.next:
        run(onNext);
      case media.MediaCommand.previous:
        run(onPrevious);
      case media.MediaCommand.stop:
        run(onStop);
      // 循环 / 随机是同步请求，不走异步动作链：回调里只改队列状态
      case media.MediaCommand.repeatOff:
        onRepeatChanged(LoopMode.off);
      case media.MediaCommand.repeatAll:
        onRepeatChanged(LoopMode.all);
      case media.MediaCommand.repeatOne:
        onRepeatChanged(LoopMode.one);
      case media.MediaCommand.shuffleOn:
        onShuffleChanged(true);
      case media.MediaCommand.shuffleOff:
        onShuffleChanged(false);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await clear();
    _available = false;
  }
}

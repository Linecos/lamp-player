import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rust/api/media.dart' as media;

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
  });

  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onStop;

  StreamSubscription<media.MediaCommand>? _subscription;
  bool _available = false;

  /// 上一次上报的曲目路径：同一首不重复上传封面（WinRT 那边要拷一份图片）
  String? _lastPath;

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

  Future<void> updateTrack({
    required String path,
    required String title,
    String? artist,
    String? album,
    String? coverPath,
  }) async {
    if (!_available || path == _lastPath) {
      return;
    }
    _lastPath = path;
    try {
      await media.mediaSetTrack(
        title: title,
        artist: artist ?? '',
        album: album ?? '',
        coverPath: coverPath,
      );
    } catch (error) {
      debugPrint('更新系统曲目信息失败：$error');
    }
  }

  Future<void> setState(MediaSessionState state) async {
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
    try {
      await media.mediaClear();
    } catch (error) {
      debugPrint('清理系统媒体信息失败：$error');
    }
  }

  void _handleCommand(media.MediaCommand command) {
    switch (command) {
      case media.MediaCommand.play:
        unawaited(onPlay());
      case media.MediaCommand.pause:
        unawaited(onPause());
      case media.MediaCommand.next:
        unawaited(onNext());
      case media.MediaCommand.previous:
        unawaited(onPrevious());
      case media.MediaCommand.stop:
        unawaited(onStop());
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await clear();
    _available = false;
  }
}

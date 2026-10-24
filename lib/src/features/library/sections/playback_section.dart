part of '../library_page.dart';

/// 播放控制、队列与进度
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _PlaybackSection on _LibraryPageState {
  /* ---------------------------------------------------------------- 播放 */

  /// 从 [tracks] 这份列表里播放 [track]，整份列表成为播放队列。
  Future<void> _playFrom(List<Track> tracks, Track track) async {
    if (tracks.isEmpty) {
      return;
    }
    int index = tracks.indexWhere((Track item) => item.path == track.path);
    if (index < 0) {
      index = 0;
      tracks = <Track>[track];
    }
    _queue.reset(tracks, index: index);
    await _startCurrent();
  }

  /// 播放队列当前曲目；[startAt] 用于恢复上次播放位置。
  Future<bool> _startCurrent({double startAt = 0}) async {
    final Track? track = _queue.current;
    if (track == null) {
      return false;
    }
    final double duration = track.durationSecs;
    _update(() {
      _currentTrack = track;
      _duration = duration;
      _position = duration > 0 ? startAt.clamp(0.0, duration) : startAt;
      _pendingResumePosition = null;
      _isPlaying = false;
    });
    _publishProgress();
    _scheduleSessionSave();
    if (!_isAvailable) {
      _showEngineNotice();
      return false;
    }
    try {
      await _playback.play(track.path);
    } catch (error) {
      if (!mounted) {
        return false;
      }
      _update(() => _isPlaying = false);
      _publishProgress();
      // 独占下失败往往是设备被抢走、引擎已回落共享：把最新输出刷给设置页
      unawaited(_refreshOutputInfo());
      _showMessage('播放失败：${ErrorRetry.describe(error)}');
      return false;
    }
    if (startAt > 0) {
      // seek 失败不能按「播放失败」处理：引擎已经在出声，置回 stopped 会让
      // 播放条显示暂停、进度轮询也不启动，于是进度条冻在旧位置。
      try {
        await _playback.seek(startAt);
      } catch (error) {
        if (!mounted) {
          return false;
        }
        _update(() => _position = 0);
        _showMessage('从上次位置继续失败，已从头播放：${ErrorRetry.describe(error)}');
      }
    }
    if (!mounted) {
      return false;
    }
    _update(() => _isPlaying = true);
    _publishProgress();
    _startPositionPolling();
    unawaited(_recordPlay(track.path));
    _saveSessionNow();
    return true;
  }

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    await _playFrom(tracks, tracks.first);
  }

  /// 历史记录失败不影响播放，只记录日志。
  Future<void> _recordPlay(String path) async {
    try {
      await _repository.recordPlay(path);
    } catch (error) {
      debugPrint('记录播放历史失败：$error');
    }
  }

  Future<void> _togglePlayback() async {
    if (!_isAvailable) {
      _showEngineNotice();
      return;
    }
    if (_currentTrack == null) {
      return;
    }
    try {
      // 自然播完后 stream 停在末尾，resume 不会回到开头；按重新播放处理。
      // 先看真实状态，避免本地 _isPlaying 还没被轮询刷新的窗口里误走 pause。
      if (_playback.state == rust.PlaybackState.stopped) {
        final double startAt = _pendingResumePosition ?? 0;
        await _startCurrent(startAt: startAt);
        return;
      }
      if (_isPlaying) {
        await _playback.pause();
      } else {
        await _playback.resume();
      }
      if (!mounted) {
        return;
      }
      _update(() => _isPlaying = !_isPlaying);
      _publishProgress();
      if (_isPlaying) {
        _startPositionPolling();
      } else {
        _stopPositionPolling();
        _saveSessionNow();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('操作失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 下一首；[auto] 表示自然播完（单曲循环时重播本曲）。
  ///
  /// `advance` 返回 null 有两层含义，必须分开处理：自然播完时音频已经停了，
  /// 只需把界面切到“结束”；手动点下一首而队列到头时音频还在放，此时若照搬
  /// “结束”分支，就会出现进度条冻在末尾、图标变播放，但歌还在响。
  Future<void> _next({bool auto = false}) async {
    if (_queue.isEmpty) {
      return;
    }
    final int? index = _queue.advance(auto: auto);
    if (index == null) {
      if (!auto) {
        _showMessage('已经是最后一首');
        return;
      }
      _stopPositionPolling();
      if (!mounted) {
        return;
      }
      _update(() {
        _isPlaying = false;
        _position = _duration;
      });
      _publishProgress();
      _saveSessionNow();
      return;
    }
    await _startCurrent();
  }

  /// 上一首：播放超过 3 秒先回到本曲开头，符合桌面播放器习惯。
  Future<void> _previous() async {
    if (_currentTrack == null) {
      return;
    }
    if (!_isStopped && _position > 3) {
      await _seekTo(0);
      return;
    }
    final int? index = _queue.retreat();
    if (index == null) {
      await _seekTo(0);
      return;
    }
    await _startCurrent();
  }

  /// 轮询发现引擎已停止：只有“本来在播”才自动切歌，
  /// 避免暂停 / 初始化阶段误触发。
  Future<void> _handleTrackEnded() async {
    if (_handlingEnd) {
      return;
    }
    _handlingEnd = true;
    try {
      await _next(auto: true);
    } finally {
      _handlingEnd = false;
    }
  }

  void _cycleRepeat() {
    _update(() => _queue.setRepeat(_queue.repeat.next));
    _saveSessionNow();
  }

  void _toggleShuffle() {
    _update(() => _queue.setShuffle(!_queue.shuffle));
    _saveSessionNow();
  }

  Future<void> _showQueue() {
    return showPlaybackQueueDialog(
      context,
      queue: _queue,
      onChanged: _onQueueChanged,
    );
  }

  /// 队列被面板修改后同步播放状态。
  ///
  /// 删除当前曲目时切到顶上来的那首；队列清空时停下并清掉播放条。
  /// 原本暂停就保持暂停，不因为删了一首突然出声。
  Future<void> _onQueueChanged() async {
    if (!mounted) {
      return;
    }
    final Track? target = _queue.current;
    final Track? current = _currentTrack;

    if (target == null) {
      _stopPositionPolling();
      if (_isAvailable && current != null) {
        try {
          await _playback.stop();
        } catch (error) {
          debugPrint('停止播放失败：$error');
        }
      }
      if (!mounted) {
        return;
      }
      _update(() {
        _currentTrack = null;
        _isPlaying = false;
        _position = 0;
        _duration = 0;
        _pendingResumePosition = null;
      });
      _publishProgress();
      _saveSessionNow();
      return;
    }

    if (current?.path == target.path) {
      _update(() {});
      _saveSessionNow();
      return;
    }

    final bool wasPlaying = _isPlaying;
    if (current != null) {
      _stopPositionPolling();
      if (_isAvailable) {
        try {
          await _playback.stop();
        } catch (error) {
          debugPrint('停止播放失败：$error');
        }
      }
      if (!mounted) {
        return;
      }
    }

    final double duration = target.durationSecs;
    _update(() {
      _currentTrack = target;
      _duration = duration;
      _position = 0;
      _pendingResumePosition = null;
      _isPlaying = false;
    });
    _publishProgress();
    _saveSessionNow();
    if (wasPlaying) {
      await _startCurrent();
    }
  }

  /// 曲目右键菜单的统一入口。
  void _onTrackContext(
    List<Track> tracks,
    Track track,
    TrackContextAction action,
  ) {
    switch (action) {
      case TrackContextAction.play:
        unawaited(_playFrom(tracks, track));
      case TrackContextAction.playNext:
        _playNext(track);
      case TrackContextAction.addToQueue:
        _enqueue(track);
      case TrackContextAction.toggleFavorite:
        unawaited(_toggleFavorite(track));
      case TrackContextAction.addToPlaylist:
        unawaited(_addToPlaylist(track));
      case TrackContextAction.revealInExplorer:
        unawaited(_revealInExplorer(track));
      case TrackContextAction.copyPath:
        unawaited(_copyPath(track));
    }
  }

  void _playNext(Track track) {
    if (_queue.isEmpty) {
      unawaited(_playFrom(<Track>[track], track));
      return;
    }
    if (_queue.current?.path == track.path) {
      _showMessage('正在播放这首');
      return;
    }
    final bool added = _queue.insertNext(track);
    _update(() {});
    _saveSessionNow();
    _showMessage(added ? '已设为下一首：${track.title}' : '队列里已经有这首');
  }

  void _enqueue(Track track) {
    if (_queue.isEmpty) {
      unawaited(_playFrom(<Track>[track], track));
      return;
    }
    if (_queue.current?.path == track.path) {
      _showMessage('正在播放这首');
      return;
    }
    final bool added = _queue.append(track);
    _update(() {});
    _saveSessionNow();
    _showMessage(added ? '已加入队列：${track.title}' : '队列里已经有这首');
  }

  Future<void> _revealInExplorer(Track track) async {
    if (!Platform.isWindows) {
      _showMessage('当前平台暂不支持打开文件位置');
      return;
    }
    try {
      await Process.run('explorer.exe', <String>['/select,', track.path]);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('打开文件位置失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _copyPath(Track track) async {
    await Clipboard.setData(ClipboardData(text: track.path));
    if (!mounted) {
      return;
    }
    _showMessage('已复制文件路径');
  }

  /// 拖动进度时停掉轮询，否则下一次 tick 会把滑块拉回原位置。
  void _onSeekStart(double _) {
    _seeking = true;
    _stopPositionPolling();
  }

  void _onSeekChanged(double seconds) {
    _update(() => _position = seconds);
    _publishProgress();
  }

  Future<void> _seekTo(double seconds) async {
    if (!_isAvailable) {
      return;
    }
    try {
      await _playback.seek(seconds);
      if (!mounted) {
        return;
      }
      _update(() => _position = seconds);
      _publishProgress();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('跳转失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _onSeekEnd(double seconds) async {
    _seeking = false;
    // 已停止（播完 / 未开始）时不要 seek：位置会改变但播放键会从头重播，
    // 等于白拖。滑块此时本身就是禁用的，这里再兜一层。
    final bool canSeek = _isAvailable && !_isStopped;
    if (canSeek) {
      await _seekTo(seconds);
    }
    if (_isPlaying && _positionTimer == null) {
      _startPositionPolling();
    }
  }

  /// 键盘快进 / 快退 5 秒
  Future<void> _seekBy(double delta) async {
    if (_currentTrack == null || !_isAvailable || _isStopped) {
      return;
    }
    final double maxPosition = _duration > 0 ? _duration : _position + delta;
    final double target = (_position + delta).clamp(0.0, maxPosition);
    await _seekTo(target);
  }

  /// 音量变化：UI 立即跟随，实际调用按 [_LibraryPageState._volumeThrottle] 合并，
  /// 避免拖动时每个像素都发一条 FFI 命令。
  void _setVolume(double volume) {
    final double next = volume.clamp(0.0, 1.0).toDouble();
    _update(() {
      if (next > 0) {
        _lastVolume = next;
      }
      _volume = next;
    });
    _scheduleSessionSave();
    if (!_isAvailable) {
      return;
    }
    _pendingVolume = next;
    _volumeTimer ??= Timer(_LibraryPageState._volumeThrottle, _flushVolume);
  }

  /// 把合并窗口内的最后一次音量发给引擎。
  void _flushVolume() {
    _volumeTimer = null;
    final double? next = _pendingVolume;
    _pendingVolume = null;
    if (next != null) {
      unawaited(_applyVolume(next));
    }
  }

  Future<void> _applyVolume(double volume) async {
    try {
      // 滑块是线性手感，引擎要的是线性振幅：走感知曲线，低音量段才调得动。
      await _playback.setVolume(volumeToAmplitude(volume));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('调节音量失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 静音 / 取消静音：立即生效，并丢弃尚未发出的中间值。
  void _toggleMute() {
    final double next = _volume > 0 ? 0 : (_lastVolume > 0 ? _lastVolume : 1);
    _volumeTimer?.cancel();
    _volumeTimer = null;
    _pendingVolume = null;
    _update(() {
      if (next > 0) {
        _lastVolume = next;
      }
      _volume = next;
    });
    _saveSessionNow();
    if (_isAvailable) {
      unawaited(_applyVolume(next));
    }
  }

  void _startPositionPolling() {
    _pollFailures = 0;
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(_LibraryPageState._pollInterval, (_) {
      unawaited(_tickPosition());
    });
  }

  void _stopPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _tickPosition() async {
    if (_ticking) {
      return;
    }
    _ticking = true;
    try {
      final double position = await _playback.position();
      final double duration = await _playback.duration();
      final rust.PlaybackState state = _playback.state;
      final bool wasPlaying = _isPlaying;
      _pollFailures = 0;
      if (!mounted || _seeking) {
        return;
      }
      // 只更新字段与播放条 notifier，不 setState：否则每 500ms 重建整个曲库。
      _position = position;
      if (duration > 0) {
        _duration = duration;
      }
      _isPlaying = state == rust.PlaybackState.playing;
      _publishProgress();
      if (state == rust.PlaybackState.stopped) {
        _stopPositionPolling();
        if (wasPlaying && !_seeking) {
          unawaited(_handleTrackEnded());
        }
      }
    } catch (_) {
      // 单次失败（引擎忙、响应中断）不该让进度条永久冻住：
      // 连续失败达到上限才停，期间继续按周期重试。
      _pollFailures += 1;
      if (_pollFailures >= _LibraryPageState._maxPollFailures) {
        _stopPositionPolling();
      }
    } finally {
      _ticking = false;
    }
  }

  void _showEngineNotice() {
    if (_engineNoticeShown) {
      return;
    }
    _engineNoticeShown = true;
    _showMessage('播放引擎不可用（缺少 BASS DLL 或初始化失败）：现在可以浏览曲目，暂时不能出声。');
  }

  void _showMessage(String message) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

part of '../library_page.dart';

/// 播放控制、队列与进度
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _PlaybackSection on _LibraryPageState {
  /* ---------------------------------------------------------------- 播放 */

  /// 播放命令排队执行，同一时刻只跑一个。
  ///
  /// 键盘、媒体键、托盘、播放条按钮、队列面板、自动播完这六个来源此前都是独立
  /// 发起的，交错起来的实测后果：连点两次下一首，两个 `advance` 各推进一次队列，
  /// 两个 `_startCurrent` 又在 `play()` 上交错，最后只播了后一首、中间那首被吞掉；
  /// 队列面板在 `await stop()` 期间改队列时，恢复出来的可能是一首已经删掉的歌。
  ///
  /// 串行后连点三次下一首会依次前进三首，符合直觉。失败只记日志：各入口内部
  /// 已经给了用户提示，这里再抛只会变成未处理异常并毒化整条链。
  Future<void> _serial(Future<void> Function() action) =>
      _playChain.run(action, label: '播放命令');

  /// 从 [tracks] 这份列表里播放 [track]，整份列表成为播放队列。
  Future<void> _playFrom(List<Track> tracks, Track track) =>
      _serial(() => _playFromNow(tracks, track));

  Future<void> _playFromNow(List<Track> tracks, Track track) async {
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
  ///
  /// [silent] 用于自然播完后的自动跳转：失败不弹提示，交给 [_next] 统一汇总，
  /// 否则整库损坏时会连续弹出多条 SnackBar。
  Future<bool> _startCurrent({double startAt = 0, bool silent = false}) async {
    unawaited(_flushPlayTime());
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
      // ReplayGain 只在开关打开时生效。已知增益（标签 / 缓存）随 play 一起下发；
      // 缺的起播后由 _applyAutoGain 后台补算再应用——现场分析要全曲解码，
      // 等它算完才 play 的话，界面早已切歌、声音还停在上一首
      final double gain = !_replayGain
          ? 0
          : track.replayGain != 0
          ? track.replayGain
          : (_autoGains[track.path] ?? 0);
      await _playback.play(track.path, replayGainDb: gain);
    } catch (error) {
      if (!mounted) {
        return false;
      }
      _update(() => _isPlaying = false);
      _publishProgress();
      // 独占下失败往往是设备被抢走、引擎已回落共享：把最新输出刷给设置页
      unawaited(_refreshOutputInfo());
      if (!silent) {
        _showMessage('播放失败：${ErrorRetry.describe(error)}');
      }
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
    _syncMediaSession();
    // 无标签增益且没算过：起播已经完成，后台补算不挡任何人
    if (_replayGain &&
        track.replayGain == 0 &&
        !_autoGains.containsKey(track.path)) {
      unawaited(_applyAutoGain(track.path));
    }
    return true;
  }

  /* --------------------------------------------------- 系统媒体控制 */

  /// 把「当前曲目 + 播放状态」同步给 Windows 系统媒体控制。
  ///
  /// 只在状态真的变化时调用（起播 / 暂停 / 停止），**不要放进 500ms 轮询**：
  /// 每次都会走一遍 WinRT 调用。
  void _syncMediaSession({bool stopped = false}) {
    // 频谱流的开关注释挂在同一批状态切换点上：放歌开始订阅、暂停 / 停止退订
    _syncSpectrum();
    final Track? track = _currentTrack;
    // 托盘菜单同步：无曲目时播放项禁用，播放中显示「暂停」
    unawaited(
      widget.trayController?.updatePlayback(
            hasTrack: track != null,
            playing: track != null && !stopped && _isPlaying,
          ) ??
          Future<void>.value(),
    );
    if (track == null) {
      unawaited(
        widget.trayController?.updateNowPlaying(null, null) ??
            Future<void>.value(),
      );
      unawaited(_media.clear());
      return;
    }
    unawaited(
      widget.trayController?.updateNowPlaying(track.title, track.artist) ??
          Future<void>.value(),
    );
    unawaited(
      _media.updateTrack(
        path: track.path,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverPath: track.coverPath,
      ),
    );
    if (stopped) {
      unawaited(_media.setState(MediaSessionState.stopped));
      return;
    }
    unawaited(
      _media.setState(
        _isPlaying ? MediaSessionState.playing : MediaSessionState.paused,
      ),
    );
  }

  /// 系统「播放」：暂停时继续，播完时从头开始；已经在播则忽略
  Future<void> _mediaPlay() async {
    if (_currentTrack == null) {
      return;
    }
    if (_playback.state == rust.PlaybackState.stopped) {
      await _startCurrent(startAt: _pendingResumePosition ?? 0);
      return;
    }
    if (!_isPlaying) {
      await _togglePlayback();
    }
  }

  /// 系统「暂停」
  Future<void> _mediaPause() async {
    if (_isPlaying) {
      await _togglePlayback();
    }
  }

  /// 系统「停止」：停音频但保留曲目（符合播放器的停止语义）
  Future<void> _mediaStop() async {
    if (_currentTrack == null) {
      return;
    }
    _stopPositionPolling();
    unawaited(_flushPlayTime());
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
    _update(() => _isPlaying = false);
    _publishProgress();
    _saveSessionNow();
    _syncMediaSession(stopped: true);
  }

  /// 打开「正在播放」页（大封面 + 同步歌词）
  Future<void> _openNowPlaying() {
    _publishProgress();
    // 播放页也能切输出设备：打开期间轮询一次设备列表（热插拔），关掉就停
    unawaited(_refreshDevices());
    _nowPlayingDeviceTimer?.cancel();
    _nowPlayingDeviceTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refreshDevices()),
    );
    return Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => NowPlayingPage(
              data: _nowPlaying,
              onTogglePlay: _togglePlayback,
              onPrevious: _previous,
              onNext: () => _next(),
              onSeek: _onSeekEnd,
              onVolumeChanged: _setVolume,
              onToggleMute: _toggleMute,
              onShowQueue: () => unawaited(_showQueue()),
              onCyclePlayMode: _cyclePlayMode,
              spectrum: widget.spectrum,
              devices: _devicesNotifier,
              selectedDevice: _outputDeviceNotifier,
              onSelectDevice: (int index) => unawaited(_setOutputDevice(index)),
              onOpenEqualizer: _isAvailable
                  ? () => unawaited(_openEqualizer())
                  : null,
              animateBackground: _flowBackground,
              shortcuts: _shortcuts,
            ),
          ),
        )
        .whenComplete(() {
          _nowPlayingDeviceTimer?.cancel();
          _nowPlayingDeviceTimer = null;
        });
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

  /// 采样一次进度，把「距上次采样的增量」计入当天。
  ///
  /// 只认 0 < delta < 3 秒：seek 跳变、切歌跨度都不是真正听过的时长。
  void _accumulatePlayTime(double position) {
    final Track? track = _currentTrack;
    final double delta = position - _lastPollPosition;
    _lastPollPosition = position;
    if (track == null || !_isPlaying || delta <= 0 || delta > 3) {
      return;
    }

    final DateTime now = DateTime.now();
    final int day = now.year * 10000 + now.month * 100 + now.day;
    if (_playSessionPath != track.path || _playSessionDay != day) {
      unawaited(_flushPlayTime());
      _playSessionPath = track.path;
      _playSessionDay = day;
      _playSessionSeconds = 0;
    }
    _playSessionSeconds += delta;
    if (_playSessionSeconds >= _LibraryPageState._playTimeFlushSeconds) {
      unawaited(_flushPlayTime());
    }
  }

  /// 把累计的整秒写库；不足 1 秒的零头留在内存里继续攒。
  Future<void> _flushPlayTime() async {
    final String? path = _playSessionPath;
    final int day = _playSessionDay;
    final int seconds = _playSessionSeconds.floor();
    if (path == null || seconds <= 0) {
      return;
    }
    _playSessionSeconds -= seconds;
    try {
      await _repository.recordPlayTime(path, day, seconds);
    } catch (error) {
      debugPrint('记录听歌时长失败：$error');
    }
  }

  Future<void> _togglePlayback() => _serial(_togglePlaybackNow);

  Future<void> _togglePlaybackNow() async {
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
      _syncMediaSession();
      if (_isPlaying) {
        _startPositionPolling();
      } else {
        _stopPositionPolling();
        _saveSessionNow();
        unawaited(_flushPlayTime());
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
  ///
  /// 自然播完且下一首打不开（文件损坏 / 被删除）时自动继续跳，最多
  /// [_LibraryPageState._maxAutoSkips] 首，避免整库损坏时无限空转。
  /// 手动点播失败仍停在该曲并提示。
  Future<void> _next({bool auto = false}) =>
      _serial(() => _nextNow(auto: auto));

  Future<void> _nextNow({bool auto = false}) async {
    if (_queue.isEmpty) {
      return;
    }
    int skipped = 0;
    while (true) {
      final int? index = _queue.advance(auto: auto);
      if (index == null) {
        if (!auto) {
          _showMessage('已经是最后一首');
          return;
        }
        _stopPositionPolling();
        unawaited(_flushPlayTime());
        if (!mounted) {
          return;
        }
        _update(() {
          _isPlaying = false;
          _position = _duration;
        });
        _publishProgress();
        _saveSessionNow();
        _syncMediaSession(stopped: true);
        if (skipped > 0) {
          _showMessage('已跳过 $skipped 首无法播放的曲目');
        }
        return;
      }

      final bool started = await _startCurrent(silent: auto);
      if (started || !auto) {
        if (skipped > 0) {
          _showMessage('已跳过 $skipped 首无法播放的曲目');
        }
        return;
      }
      // 引擎整体不可用：再跳也只是重复提示，直接停在当前曲目。
      if (!_isAvailable) {
        return;
      }
      skipped += 1;
      if (skipped >= _LibraryPageState._maxAutoSkips) {
        _stopPositionPolling();
        if (!mounted) {
          return;
        }
        _update(() => _isPlaying = false);
        _publishProgress();
        _saveSessionNow();
        _syncMediaSession(stopped: true);
        _showMessage(
          '连续 ${_LibraryPageState._maxAutoSkips} 首播放失败，已停止自动播放；'
          '请检查音频文件',
        );
        return;
      }
    }
  }

  /// 上一首：播放超过 3 秒先回到本曲开头，符合桌面播放器习惯。
  Future<void> _previous() => _serial(_previousNow);

  Future<void> _previousNow() async {
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

  /// 顺序 → 随机 → 列表循环 → 单曲循环：播放条 / 正在播放页共用一个按钮。
  void _cyclePlayMode() {
    _update(() => cyclePlayMode(_queue));
    _publishProgress();
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
  Future<void> _onQueueChanged() => _serial(_onQueueChangedNow);

  Future<void> _onQueueChangedNow() async {
    _publishProgress();
    if (!mounted) {
      return;
    }
    final Track? target = _queue.current;
    final Track? current = _currentTrack;

    if (target == null) {
      _stopPositionPolling();
      unawaited(_flushPlayTime());
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
      _syncMediaSession(stopped: true);
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

    // `stop()` 是异步的，这期间队列面板还能继续删 / 拖：重新取一次当前曲目。
    // 串行化只挡住了「其它播放入口」，挡不住面板自身的编辑，照旧值恢复
    // 就会把一首已经删掉的歌播出来。
    final Track? latest = _queue.current;
    if (latest == null) {
      _update(() {
        _currentTrack = null;
        _isPlaying = false;
        _position = 0;
        _duration = 0;
        _pendingResumePosition = null;
      });
      _publishProgress();
      _saveSessionNow();
      _syncMediaSession(stopped: true);
      return;
    }

    final double duration = latest.durationSecs;
    _update(() {
      _currentTrack = latest;
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
      case TrackContextAction.openWithMusicTag:
        unawaited(_openWithMusicTag(track));
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

  /// 用外部 MusicTag（音乐标签）编辑这首歌的标签。
  ///
  /// 自己实现标签编辑器成本高、也容易写坏文件，这里只做「交给专业工具」：
  /// MusicTag 是绿色软件、装在哪不确定，第一次让用户指定 `MusicTag.exe` 并记住，
  /// 之后右键直接打开。改完回来点提示里的「改完了，刷新」重扫该目录即可看到新标签。
  Future<void> _openWithMusicTag(Track track) async {
    MusicTagResult result = await _musicTag.open(<String>[track.path]);
    // await 回来页面可能已经退出：下面几条分支都会碰 context
    if (!mounted) {
      return;
    }
    if (result == MusicTagResult.unsupported) {
      _showMessage('当前平台暂不支持外部标签编辑器');
      return;
    }
    if (result == MusicTagResult.notConfigured && mounted) {
      final bool? choose = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('没有找到 MusicTag'),
          content: const Text(
            'MusicTag（音乐标签）是绿色软件，位置不固定，需要指定一次 MusicTag.exe。\n'
            '选好之后会记住，下次直接从右键菜单打开。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('选择 MusicTag.exe'),
            ),
          ],
        ),
      );
      if (choose == true && mounted && await _musicTag.chooseExecutable()) {
        if (!mounted) {
          return;
        }
        result = await _musicTag.open(<String>[track.path]);
      }
    }
    if (!mounted) {
      return;
    }
    if (result != MusicTagResult.launched) {
      _showMessage('没有打开：还没指定 MusicTag.exe');
      return;
    }
    _showMessage(
      '已用 MusicTag 打开：${track.title}',
      action: SnackBarAction(
        label: '改完了，刷新',
        onPressed: () => unawaited(_refreshTrackFolder(p.dirname(track.path))),
      ),
    );
  }

  /// 外部工具改过标签后重扫所在目录，刷新标题 / 专辑 / 封面
  Future<void> _refreshTrackFolder(String folder) async {
    try {
      await _repository.scanFolder(folder);
      await _loadTracks(silent: true);
      if (!mounted) {
        return;
      }
      _showMessage('已刷新曲库');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('刷新曲库失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 拖动进度时停掉轮询，否则下一次 tick 会把滑块拉回原位置。
  void _onSeekStart(double _) {
    _seeking = true;
    _stopPositionPolling();
  }

  void _onSeekChanged(double seconds) {
    // 拖动预览只推播放条：`_update` 会推进 `_stateVersion`，
    // 把当前分区（可能是一整页封面网格）整棵重建。
    _position = seconds;
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
      _position = seconds;
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
  ///
  /// 只改 notifier，不走 `_update`：音量不影响列表内容，推进 `_stateVersion`
  /// 会把当前分区整棵子树（艺术家页是全量封面）一起重建。
  void _setVolume(double volume) {
    final double next = volume.clamp(0.0, 1.0).toDouble();
    if (next > 0) {
      _lastVolume = next;
    }
    _volume = next;
    _publishProgress();
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
    if (next > 0) {
      _lastVolume = next;
    }
    _volume = next;
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
      final rust.PlayerProgress progress = await _playback.now();
      final double position = progress.positionSecs;
      final double duration = progress.durationSecs;
      final rust.PlaybackState state = progress.state;
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
      _accumulatePlayTime(position);
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

  /* --------------------------------------------------- 输出设备 / 淡变 */

  /// 刷新可用设备列表；设置页打开时低频轮询，用于发现热插拔
  Future<void> _refreshDevices() async {
    if (!_isAvailable) {
      return;
    }
    try {
      final List<rust.PlayerDevice> devices = await _playback.devices();
      if (!mounted) {
        return;
      }
      // 列表没变就不 setState：轮询每 3 秒一次，白重建设置页没意义
      final bool same =
          devices.length == _devices.length &&
          <int>[for (final rust.PlayerDevice device in devices) device.index]
                  .join(',') ==
              <int>[
                for (final rust.PlayerDevice device in _devices) device.index,
              ].join(',');
      if (same) {
        return;
      }
      _update(() => _devices = devices);
      _devicesNotifier.value = devices;
    } catch (_) {
      // 枚举失败（引擎忙 / DLL 缺失）保持旧列表，不影响其它操作
    }
  }

  /// 切换输出设备：引擎会保留当前曲目与进度重开会话
  Future<void> _setOutputDevice(int index) async {
    if (_outputDevice == index) {
      return;
    }
    _update(() {
      _outputDevice = index;
      _switchingOutput = true;
    });
    _outputDeviceNotifier.value = index;
    _saveSessionNow();
    try {
      await _playback.setDevice(index);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('切换输出设备失败：${ErrorRetry.describe(error)}');
      unawaited(_refreshOutputInfo());
    } finally {
      if (mounted) {
        _update(() => _switchingOutput = false);
      }
      unawaited(_refreshOutputInfo());
      unawaited(_refreshDevices());
    }
  }

  /// 标签里没有增益时现场分析整曲（ReplayGain 2.0），结果缓存到会话结束。
  ///
  /// 分析失败静默回落 0（不调整）：为了一个坏文件弹提示不值得，
  /// 播放本身马上还会给出真正的失败原因。
  Future<double> _autoGain(String path) async {
    final double? cached = _autoGains[path];
    if (cached != null) {
      return cached;
    }
    try {
      final double gain = await _playback.analyzeReplayGain(path);
      return _autoGains[path] = gain;
    } catch (_) {
      return 0;
    }
  }

  /// 起播后补算无标签曲目的增益并应用到当前输出。
  ///
  /// 分析结束时用户可能已经切走：结果与当前曲目对不上就只进缓存，下次
  /// 播放这首时随 play 直接带上，不把旧曲的增益套到新曲头上。
  Future<void> _applyAutoGain(String path) async {
    final double gain = await _autoGain(path);
    if (gain == 0 || !_replayGain || _currentTrack?.path != path) {
      return;
    }
    try {
      await _playback.setReplayGain(gain);
    } catch (_) {
      // 应用失败只影响这一首的响度，不值得打扰
    }
  }

  /// ReplayGain 开关：只影响下一首起播，不做实时调整（改增益会突然变响）
  void _setReplayGain(bool value) {
    if (_replayGain == value) {
      return;
    }
    _update(() => _replayGain = value);
    _saveSessionNow();
  }

  /// 换曲淡变时长（秒）；0 关闭
  Future<void> _setCrossfade(double seconds) async {
    if (_crossfadeSeconds == seconds) {
      return;
    }
    _update(() => _crossfadeSeconds = seconds);
    _saveSessionNow();
    try {
      await _playback.setCrossfade(seconds);
    } catch (error) {
      if (mounted) {
        _showMessage('设置淡入淡出失败：${ErrorRetry.describe(error)}');
      }
    }
  }

  void _showEngineNotice() {
    if (_engineNoticeShown) {
      return;
    }
    _engineNoticeShown = true;
    _showMessage('播放引擎不可用（缺少 BASS DLL 或初始化失败）：现在可以浏览曲目，暂时不能出声。');
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }
}

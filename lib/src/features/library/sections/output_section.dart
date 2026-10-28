part of '../library_page.dart';

/// 输出设备与独占切换
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _OutputSection on _LibraryPageState {
  /* ------------------------------------------------------------ 输出设备 */

  /// 启动时把保存的偏好告诉引擎（静默：失败只记录原因，不弹提示）
  Future<void> _applyOutputPreference(bool exclusive) async {
    if (exclusive && _isAvailable) {
      try {
        await _playback.setExclusive(true);
      } catch (error) {
        debugPrint('恢复独占输出失败：$error');
      }
    }
    await _refreshOutputInfo();
  }

  Future<void> _refreshOutputInfo() async {
    if (!_isAvailable) {
      if (!mounted) {
        return;
      }
      _update(() => _outputInfo = '引擎不可用');
      return;
    }
    try {
      final String info = await _playback.outputInfo();
      if (!mounted) {
        return;
      }
      _update(() => _outputInfo = info);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() => _outputInfo = '读取输出信息失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 切换独占：切换期间曲目会重新打开，位置与播放状态由引擎保留
  Future<void> _setExclusive(bool value) async {
    if (_switchingOutput || !_isAvailable) {
      return;
    }
    _update(() {
      _switchingOutput = true;
      _exclusive = value;
    });
    _saveSessionNow();
    try {
      await _playback.setExclusive(value);
      await _refreshOutputInfo();
      if (!mounted) {
        return;
      }
      // 请求独占但没生效（DLL 缺失 / 设备被占用）：说明原因，偏好仍然保留
      if (value && !_playback.isExclusive) {
        _showMessage('独占输出不可用，已回落到共享输出');
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() => _exclusive = !value);
      _saveSessionNow();
      _showMessage('切换输出失败：${ErrorRetry.describe(error)}');
    } finally {
      if (mounted) {
        _update(() => _switchingOutput = false);
      }
    }
  }

  /* ------------------------------------------------------------ 均衡器 */

  /// 启动时把上次选中的输出设备装回去（设备已拔掉时引擎会退回系统默认）
  Future<void> _applyOutputDevice() async {
    if (!_isAvailable) {
      return;
    }
    if (_outputDevice > 0) {
      try {
        await _playback.setDevice(_outputDevice);
      } catch (error) {
        debugPrint('恢复输出设备失败：$error');
      }
    }
    unawaited(_refreshDevices());
  }

  /// 启动时把换曲淡变时长装回去
  Future<void> _applyCrossfade() async {
    if (!_isAvailable) {
      return;
    }
    try {
      await _playback.setCrossfade(_crossfadeSeconds);
    } catch (error) {
      debugPrint('恢复淡入淡出设置失败：$error');
    }
  }

  Future<void> _applyEqualizer() async {
    if (!_isAvailable) {
      return;
    }
    try {
      await _playback.setEqualizer(enabled: _eqEnabled, gains: _eqGains);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('应用均衡器失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 开关 / 推子 / 选预设变化：先落盘再下发，拖动过程中由 UI 侧节流
  void _setEqualizer(bool enabled, List<double> gains, String? presetName) {
    _update(() {
      _eqEnabled = enabled;
      _eqGains = normalizeEqGains(gains);
      _eqPresetName = presetName;
    });
    _saveSessionNow();
    unawaited(_applyEqualizer());
  }

  /// 自存预设增删：不影响当前曲线，只落盘
  void _setEqCustomPresets(List<EqualizerPreset> presets) {
    _update(() => _eqCustomPresets = presets);
    _saveSessionNow();
  }

  /// 均衡器页：设置页和正在播放页共用同一个入口
  Future<void> _openEqualizer() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EqualizerPage(
          enabled: _eqEnabled,
          gains: _eqGains,
          presetName: _eqPresetName,
          customPresets: _eqCustomPresets,
          onChanged: _isAvailable ? _setEqualizer : null,
          onCustomPresetsChanged: _setEqCustomPresets,
        ),
      ),
    );
  }

  bool _readAvailability() {
    try {
      return _playback.isAvailable;
    } catch (_) {
      return false;
    }
  }

  /// 把当前进度写进 notifier，只刷新播放条。
  void _publishProgress() {
    _syncSpectrum();
    _progress.value = _PlaybackProgress(
      position: _position,
      duration: _duration,
      playing: _isPlaying,
    );
    _nowPlaying.value = NowPlayingData(
      track: _currentTrack,
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration,
      isAvailable: _isAvailable,
      volume: _volume,
      repeat: _queue.repeat,
      shuffle: _queue.shuffle,
      desktopLyrics: _desktopLyrics,
    );
    _pushDesktopLyric();
  }

  /* ------------------------------------------------------- 桌面歌词 */

  Future<void> _loadLyrics(String path) async {
    if (_lyricsPath == path) {
      return;
    }
    _lyricsPath = path;
    _lyrics = null;
    _desktopLine = '';
    try {
      final lyrics_api.TrackLyrics loaded = await lyrics_api.lyricsLoad(
        path: path,
      );
      if (!mounted || _lyricsPath != path) {
        return;
      }
      _lyrics = loaded;
      _pushDesktopLyric();
    } catch (error) {
      // 没有歌词文件是常态，不该打扰用户
      debugPrint('读取歌词失败：$error');
    }
  }

  /// 当前时间点对应的那行歌词；没歌词返回空串
  String _currentLyricLine() {
    final lyrics_api.TrackLyrics? lyrics = _lyrics;
    if (lyrics == null || lyrics.lines.isEmpty) {
      return '';
    }
    final int positionMs = (_position * 1000).round();
    String line = '';
    for (final lyrics_api.LyricLine item in lyrics.lines) {
      if (item.timeMs > positionMs) {
        break;
      }
      line = item.text;
    }
    return line;
  }

  /// 把当前行推给桌面歌词窗口；窗口没开就什么都不做
  void _pushDesktopLyric() {
    if (!_desktopLyrics) {
      return;
    }
    final String line = _currentLyricLine();
    if (line == _desktopLine) {
      return;
    }
    _desktopLine = line;
    unawaited(
      desktop_lyrics
          .desktopLyricsSetLine(line: line)
          .catchError((Object error) => debugPrint('更新桌面歌词失败：$error')),
    );
  }

  /// 开关桌面歌词：窗口常驻，只切显示 / 隐藏
  Future<void> _setDesktopLyrics(bool enabled) async {
    _update(() => _desktopLyrics = enabled);
    _saveSessionNow();
    _publishProgress();
    try {
      if (enabled) {
        await desktop_lyrics.desktopLyricsShow();
        _desktopLine = '';
        _pushDesktopLyric();
      } else {
        await desktop_lyrics.desktopLyricsHide();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('切换桌面歌词失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 启动时按上次状态恢复窗口；失败只记日志，不影响播放
  Future<void> _restoreDesktopLyrics() async {
    if (!_desktopLyrics) {
      return;
    }
    try {
      await desktop_lyrics.desktopLyricsShow();
      _desktopLine = '';
      _pushDesktopLyric();
    } catch (error) {
      debugPrint('恢复桌面歌词失败：$error');
    }
  }

  /// 艺术家 / 专辑聚合结果按 `_tracks` 的对象身份缓存，避免每次 rebuild
  /// （包括播放进度刷新）都全量重算。
  List<ArtistGroup> get _artistGroupsCache {
    _rebuildGroupsIfNeeded();
    return _artistGroups ?? const <ArtistGroup>[];
  }

  List<AlbumGroup> get _albumGroupsCache {
    _rebuildGroupsIfNeeded();
    return _albumGroups ?? const <AlbumGroup>[];
  }

  void _rebuildGroupsIfNeeded() {
    if (identical(_groupedTracks, _tracks)) {
      return;
    }
    _groupedTracks = _tracks;
    _artistGroups = groupTracksByArtist(_tracks);
    _albumGroups = groupTracksByAlbum(_tracks);
  }

  /// 引擎是否处于停止态（未播放、已播完、或引擎不可用）。
  ///
  /// 停止态下滑块要禁用：此时 seek 虽然能成功，但播放键会从头重播。
  bool get _isStopped {
    try {
      return _playback.state == rust.PlaybackState.stopped;
    } catch (_) {
      return true;
    }
  }
}

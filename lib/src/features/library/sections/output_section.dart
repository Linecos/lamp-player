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

  /// 均衡器：设置页打开独立页面，正在播放页打开同内容的弹窗
  Future<void> _openEqualizer() async {
    await showEqualizerDialog(
      context,
      enabled: _eqEnabled,
      gains: _eqGains,
      presetName: _eqPresetName,
      customPresets: _eqCustomPresets,
      onChanged: _isAvailable ? _setEqualizer : null,
      onCustomPresetsChanged: _setEqCustomPresets,
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
    // 记下「读到这一刻位置」的墙钟：桌面歌词靠它外推当前时刻，
    // 换行不必等到下一次轮询（见 [_scheduleDesktopLyricSwitch]）
    _lyricAnchorWall = DateTime.now();
    _lyricAnchorPosition = _position;
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
      desktopLyricLocked: _desktopLyricLocked,
    );
    _pushDesktopLyric();
    _scheduleDesktopLyricSwitch();
    _syncTrayDesktopLyrics();
  }

  /// 托盘菜单的勾选态：显示 / 锁定桌面歌词
  void _syncTrayDesktopLyrics() {
    unawaited(
      widget.trayController?.updateDesktopLyrics(
            visible: _desktopLyrics,
            locked: _desktopLyricLocked,
          ) ??
          Future<void>.value(),
    );
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
      _scheduleDesktopLyricSwitch();
    } catch (error) {
      // 没有歌词文件是常态，不该打扰用户
      debugPrint('读取歌词失败：$error');
    }
  }

  /// 桌面歌词眼下的播放位置（秒）。
  ///
  /// 引擎位置 500ms 才读一次，直接拿 `_position` 会慢半拍。播放中用「上次读到的
  /// 位置 + 这段时间的墙钟差」外推：误差只剩 BASS 时钟与系统时钟的漂移，
  /// 比等下一拍小一个量级；不在播放时 `_position` 就是准的。
  double _desktopLyricPosition() {
    final DateTime? anchor = _lyricAnchorWall;
    if (!_isPlaying || anchor == null) {
      return _position;
    }
    final double elapsed =
        DateTime.now().difference(anchor).inMicroseconds / 1000000.0;
    final double projected = _lyricAnchorPosition + elapsed;
    return _duration > 0 ? projected.clamp(0.0, _duration) : projected;
  }

  /// 当前时间点对应的那行歌词；没歌词返回空串
  String _currentLyricLine() {
    final lyrics_api.TrackLyrics? lyrics = _lyrics;
    if (lyrics == null || lyrics.lines.isEmpty) {
      return '';
    }
    final int positionMs = (_desktopLyricPosition() * 1000).round();
    return desktopLineAt(lyrics, positionMs) ?? '';
  }

  /// 定一个「下一次换行」的定时器。
  ///
  /// 原来换行只能等 500ms 的位置轮询来发现，最多慢半拍。这里按歌词行的时间戳
  /// 算出还有多久换行，到点再推一次：推送次数没变多（每行仍然只推一次），
  /// 也不增加轮询频率、不触发任何重建。暂停 / 换曲 / 拖动都会经
  /// [_publishProgress] 重排，旧定时器先撤掉。
  void _scheduleDesktopLyricSwitch() {
    void clear() {
      _desktopLyricTimer?.cancel();
      _desktopLyricTimer = null;
      _desktopLyricDueMs = null;
    }

    final lyrics_api.TrackLyrics? lyrics = _lyrics;
    if (!_desktopLyrics ||
        !_isPlaying ||
        lyrics == null ||
        lyrics.lines.isEmpty) {
      clear();
      return;
    }
    final int nowMs = (_desktopLyricPosition() * 1000).round();
    final int? nextMs = nextDesktopLineStart(lyrics, nowMs);
    if (nextMs == null) {
      // 已经是最后一行，等换曲 / 暂停时再重排
      clear();
      return;
    }
    // 还是同一个换行点，且定时器还活着：留着它，别每拍拆一次
    // （[_publishProgress] 现在 250ms 走一次，之前是 500ms）
    if (_desktopLyricTimer != null && _desktopLyricDueMs == nextMs) {
      return;
    }
    // 上限 30 秒：歌词文件里偶见超大间隔，别让一个定时器悬太久，
    // 否则暂停后要等很久才被下一拍撤掉
    final int delayMs = (nextMs - nowMs).clamp(0, 30000);
    _desktopLyricTimer?.cancel();
    _desktopLyricDueMs = nextMs;
    _desktopLyricTimer = Timer(Duration(milliseconds: delayMs), () {
      _desktopLyricTimer = null;
      _desktopLyricDueMs = null;
      if (!mounted || !_desktopLyrics || !_isPlaying) {
        return;
      }
      _pushDesktopLyric();
      _scheduleDesktopLyricSwitch();
    });
  }

  /// 把当前行推给桌面歌词窗口；窗口没开就什么都不做
  void _pushDesktopLyric() {
    if (!_desktopLyrics) {
      return;
    }
    String line = _currentLyricLine();
    if (line.isEmpty) {
      // 没歌词（或还没读到）时别留一条空白黑框：显示曲名撑住信息
      final Track? track = _currentTrack;
      line = track == null ? '♪' : '♪ ${track.title}';
    }
    if (line == _desktopLine) {
      _syncDesktopKaraoke();
      return;
    }
    _desktopLine = line;
    // 换行时窗口那边会把逐字进度归零，所以要等这次 set_line 落地之后再推进度：
    // 否则新行会暗着一直到下一次轮询（没有逐字的行会暗整整 500ms）
    _stopKaraoke();
    final String target = line;
    unawaited(
      desktop_lyrics
          .desktopLyricsSetLine(line: target)
          .then((_) {
            if (mounted && _desktopLine == target) {
              _syncDesktopKaraoke();
            }
          })
          .catchError((Object error) => debugPrint('更新桌面歌词失败：$error')),
    );
  }

  /* --------------------------------------------------- 桌面歌词逐字 */

  /// 同步逐字进度：换行、暂停、拖动都会走到这里。
  ///
  /// 只有「桌面歌词开着 + 播放中 + 这一行确实带逐字时间轴」才起 30fps 的推进器；
  /// 其余情况推一次整行亮（1）就停，和没有这个功能时完全一样。
  void _syncDesktopKaraoke() {
    if (!_desktopLyrics) {
      _stopKaraoke();
      return;
    }
    if (!_isPlaying) {
      // 暂停：保留当前进度。推 0 或 1 都会让整行跳一下
      _stopKaraoke();
      return;
    }
    final lyrics_api.TrackLyrics? lyrics = _lyrics;
    if (lyrics == null || lyrics.lines.isEmpty) {
      _stopKaraoke();
      _pushKaraokeRatio(1);
      return;
    }
    final int positionMs = (_desktopLyricPosition() * 1000).round();
    final int index = desktopLineIndexAt(lyrics, positionMs);
    final lyrics_api.LyricLine? line = index < 0 ? null : lyrics.lines[index];
    final List<lyrics_api.LyricWord> words =
        line?.words ?? const <lyrics_api.LyricWord>[];
    if (line == null || words.length < 2) {
      // 没有逐字时间轴（或还没到第一行）：整行亮着
      _karaokeLyrics = lyrics;
      _karaokeLineIndex = index;
      _karaokeTimes = null;
      _karaokeWeights = null;
      _stopKaraoke();
      _pushKaraokeRatio(1);
      return;
    }
    if (!identical(_karaokeLyrics, lyrics) || index != _karaokeLineIndex) {
      _karaokeLyrics = lyrics;
      _karaokeLineIndex = index;
      _karaokeTimes = <int>[
        for (final lyrics_api.LyricWord word in words) word.timeMs.toInt(),
      ];
      _karaokeWeights = _measureKaraokeWeights(line.text, words);
      _karaokeEndMs = line.endMs.toInt();
    }
    final List<int>? times = _karaokeTimes;
    final List<double>? weights = _karaokeWeights;
    if (times == null || weights == null) {
      return;
    }
    _pushKaraokeRatio(
      karaokeFillRatio(
        times: times,
        weights: weights,
        lineEndMs: _karaokeEndMs,
        positionMs: positionMs.toDouble(),
      ),
    );
    if (positionMs >= _karaokeEndMs) {
      // 整行唱完：停在 1，别再白跑 30fps
      _stopKaraoke();
      return;
    }
    _karaokeTimer ??= Timer.periodic(
      _LibraryPageState._karaokeInterval,
      (_) => _tickKaraoke(),
    );
  }

  /// 30fps 的逐字推进：只算一个比例推给窗口，不碰界面
  void _tickKaraoke() {
    final List<int>? times = _karaokeTimes;
    final List<double>? weights = _karaokeWeights;
    if (!_desktopLyrics || !_isPlaying || times == null || weights == null) {
      _stopKaraoke();
      return;
    }
    final int positionMs = (_desktopLyricPosition() * 1000).round();
    _pushKaraokeRatio(
      karaokeFillRatio(
        times: times,
        weights: weights,
        lineEndMs: _karaokeEndMs,
        positionMs: positionMs.toDouble(),
      ),
    );
    if (positionMs >= _karaokeEndMs) {
      _stopKaraoke();
    }
  }

  void _stopKaraoke() {
    _karaokeTimer?.cancel();
    _karaokeTimer = null;
  }

  /// 推一次逐字进度。
  ///
  /// 这是同步 FFI：Rust 那边只写内存 + `PostMessage`，开销可以忽略；外面包一层
  /// 兜底是为了「引擎已经关了 / 测试里没有原生库」时不要让 UI 侧抛异常。
  void _pushKaraokeRatio(double ratio) {
    try {
      desktop_lyrics.desktopLyricsSetProgress(ratio: ratio);
    } catch (error) {
      debugPrint('更新桌面歌词逐字进度失败：$error');
    }
  }

  /// 量出每个逐字片段占多宽。
  ///
  /// 只用来算「已唱部分占整行几成」，所以字体字号不必和桌面歌词完全一致——
  /// 中文都是等宽块，比例基本一致；西文有细微差别，但决定点亮时刻的是时间轴。
  List<double> _measureKaraokeWeights(
    String text,
    List<lyrics_api.LyricWord> words,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          height: 1.45,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final List<double> weights = <double>[];
    int cursor = 0;
    for (final lyrics_api.LyricWord word in words) {
      final int start = text.indexOf(word.text, cursor);
      if (start < 0) {
        weights.add(0);
        continue;
      }
      final int end = start + word.text.length;
      double width = 0;
      for (final TextBox box in painter.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      )) {
        width += box.right - box.left;
      }
      weights.add(width);
      cursor = end;
    }
    painter.dispose();
    return weights;
  }

  /// 开关桌面歌词：窗口常驻，只切显示 / 隐藏。
  ///
  /// 锁定状态原样保留：解锁入口在托盘菜单与正在播放页的锁形按钮上，
  /// 不能因为「重新打开」就把用户锁好的穿透状态悄悄改掉。
  Future<void> _setDesktopLyrics(bool enabled) async {
    _update(() => _desktopLyrics = enabled);
    _saveSessionNow();
    _publishProgress();
    try {
      if (enabled) {
        await _pushDesktopLyricSettings();
        _restoreDesktopLyricPosition();
        await desktop_lyrics.desktopLyricsShow();
        _desktopLine = '';
        _pushDesktopLyric();
        _scheduleDesktopLyricSwitch();
      } else {
        await desktop_lyrics.desktopLyricsHide();
        _desktopLyricTimer?.cancel();
        _desktopLyricTimer = null;
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('切换桌面歌词失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 锁定 / 解锁桌面歌词。
  ///
  /// 锁定后窗口鼠标穿透：桌面上点不到、拖不动、也出不来工具栏，所以正在播放页
  /// 的桌面歌词按钮旁边常驻一个锁形开关——那是唯一的解锁入口。
  Future<void> _setDesktopLyricLocked(bool locked) async {
    _update(() => _desktopLyricLocked = locked);
    _saveSessionNow();
    _publishProgress();
    try {
      await desktop_lyrics.desktopLyricsSetLocked(locked: locked);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('切换桌面歌词锁定失败：${ErrorRetry.describe(error)}');
      return;
    }
    if (locked && mounted) {
      _showMessage('桌面歌词已锁定：鼠标点击会穿透到下层窗口，解锁请在托盘菜单或正在播放页取消锁定');
    }
  }

  /// 把字号、锁定、播放状态先推给窗口，再显示：否则首帧会按默认字号排版，
  /// 用户会看到一次明显的跳动
  /// 把上次的窗口位置交给窗口线程（窗口还没建就先记着，下次显示直接用）
  void _restoreDesktopLyricPosition() {
    final (int, int)? position = _desktopLyricWindow;
    if (position == null) {
      return;
    }
    try {
      desktop_lyrics.desktopLyricsSetPosition(x: position.$1, y: position.$2);
    } catch (error) {
      debugPrint('恢复桌面歌词位置失败：$error');
    }
  }

  /// 窗口当前的位置；窗口没开就沿用上次记下的值
  (int, int)? _currentDesktopLyricPosition() {
    if (!_desktopLyrics) {
      return _desktopLyricWindow;
    }
    try {
      final desktop_lyrics.DesktopLyricPosition? current = desktop_lyrics
          .desktopLyricsPosition();
      if (current != null) {
        _desktopLyricWindow = (current.x, current.y);
      }
    } catch (error) {
      debugPrint('读取桌面歌词位置失败：$error');
    }
    return _desktopLyricWindow;
  }

  Future<void> _pushDesktopLyricSettings() async {
    await desktop_lyrics.desktopLyricsSetFontSize(size: _desktopLyricFontSize);
    await desktop_lyrics.desktopLyricsSetLocked(locked: _desktopLyricLocked);
    await desktop_lyrics.desktopLyricsSetPlaying(playing: _isPlaying);
  }

  /// 播放状态变化时同步给窗口：工具栏的播放 / 暂停字形跟着变
  void _syncDesktopLyricPlaying() {
    if (!_desktopLyrics) {
      return;
    }
    unawaited(
      desktop_lyrics
          .desktopLyricsSetPlaying(playing: _isPlaying)
          .catchError((Object error) => debugPrint('同步桌面歌词播放状态失败：$error')),
    );
  }

  /// 启动时按上次状态恢复窗口；失败只记日志，不影响播放。
  ///
  /// 恢复显示时**强制解锁**：锁定状态是鼠标穿透，主界面还没出来时（关到托盘
  /// 启动）只能靠托盘菜单解开。与「显式打开歌词 = 解锁」保持一致。
  Future<void> _restoreDesktopLyrics() async {
    _syncTrayDesktopLyrics();
    if (!_desktopLyrics) {
      return;
    }
    try {
      await _pushDesktopLyricSettings();
      _restoreDesktopLyricPosition();
      await desktop_lyrics.desktopLyricsShow();
      _desktopLine = '';
      _pushDesktopLyric();
      _scheduleDesktopLyricSwitch();
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

  /// 引擎是否处于停止态（还没起播 / 已播完 / 引擎不可用）。
  ///
  /// 注意：停止态**不再禁用**进度条。拖动会先记成续播点（`_deferSeek`），
  /// 按播放时从那里开始，所以「拖了白拖」的前提已经不成立了。
  bool get _isStopped {
    try {
      return _playback.state == rust.PlaybackState.stopped;
    } catch (_) {
      return true;
    }
  }
}

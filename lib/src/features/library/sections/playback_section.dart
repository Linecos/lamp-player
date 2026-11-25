part of '../library_page.dart';

/// 播放控制、队列与进度
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
/// 读标签慢到这个程度才铺占位；快的时候直接进界面，免得闪一下
const Duration _metadataLoadingDelay = Duration(milliseconds: 120);

/// 两次枚举出来的输出设备列表是否等价。
///
/// 三个字段都要比：只比 `index` 的话，蓝牙耳机改名、系统里换默认设备之后
/// 轮询判定「没变化」，设置页会一直显示旧名字 / 旧默认标记。
bool samePlayerDevices(
  List<rust.PlayerDevice> next,
  List<rust.PlayerDevice> old,
) {
  if (next.length != old.length) {
    return false;
  }
  for (int i = 0; i < next.length; i += 1) {
    final rust.PlayerDevice a = next[i];
    final rust.PlayerDevice b = old[i];
    if (a.index != b.index || a.name != b.name || a.isDefault != b.isDefault) {
      return false;
    }
  }
  return true;
}

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
    hangMark('播放：起播 ${p.basename(track.path)}');
    final double duration = track.durationSecs;
    // 换曲：`_currentTrack` 变了，分区要跟着换高亮，这一条必须推进版本
    _update(() {
      _currentTrack = track;
      _duration = duration;
      _position = duration > 0 ? startAt.clamp(0.0, duration) : startAt;
      _pendingResumePosition = null;
      _isPlaying = false;
    });
    _publishProgress();
    _scheduleSessionSave();
    _syncCoverSeed(track);
    if (!_isAvailable) {
      _showEngineNotice();
      return false;
    }
    try {
      // ReplayGain 只在开关打开时生效。已知增益（标签 / 上次分析后写进曲库的值 /
      // 会话缓存）随 play 一起下发；还没有增益就先按 0 播——现场分析要全曲
      // 解码 1~2 秒，等它算完再 play 界面早就切歌了，中途改音量又会先响一下。
      // 算出的值写回曲库，下次起播直接带上。
      final double gain = _gainFor(track);
      await _playback.play(track.path, replayGainDb: gain);
      // 桌面歌词要实时跟上，歌词跟着曲目一起换
      unawaited(_loadLyrics(track.path));
    } catch (error) {
      if (!mounted) {
        return false;
      }
      _updatePlayer(() => _isPlaying = false);
      _publishProgress();
      if (!silent) {
        _showMessage(_playFailureText(error, track.path));
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
        _updatePlayer(() => _position = 0);
        _showMessage('从上次位置继续失败，已从头播放：${ErrorRetry.describe(error)}');
      }
    }
    if (!mounted) {
      return false;
    }
    // 这里只翻播放态：曲目已经在上面的 `_update` 里换过了，再推进版本
    // 只会把分区（列表 / 网格）整份重建一遍，内容还完全相同
    _updatePlayer(() => _isPlaying = true);
    // 新的一轮起播：次数与时长都从零开始判（见 `_accumulatePlayTime`）
    _playedSinceStart = 0;
    _playCountedThisStart = false;
    _publishProgress();
    _startPositionPolling();
    // 起播就进「最近播放」（历史跟点击走）；次数要听够一半才加
    unawaited(_touchPlayHistory(track.path));
    _saveSessionNow();
    _syncMediaSession();
    // 换歌那一下是内存台阶的所在（新封面解码 + 整页第一次画）。等它画完
    // 补查一次，别等常规周期
    MemoryGuard.checkSoon();
    // 没有标签增益、也没测量过：后台补算，算完写回曲库，从下一次起播开始生效。
    // 不在播放中途改音量——分析要 1~2 秒，那 1~2 秒会明显偏响再突然变小。
    if (_replayGain &&
        track.replayGain == 0 &&
        track.loudnessLufs == 0 &&
        !_autoLoudness.containsKey(track.path)) {
      unawaited(_autoGain(track.path));
    }
    return true;
  }

  /// 换歌之后把「强调色跟随封面」跟上。
  ///
  /// 只在真的开启了跟随时才去取色：那条路要解码封面（归一化后 4.7ms，缓存命中
  /// 0.014ms），没开就一次都不做。
  void _syncCoverSeed(Track track) {
    final ThemeController? theme = ThemeScope.readOf(context);
    if (theme == null || !theme.followsCover) {
      return;
    }
    // 同一首歌重复起播（暂停后继续、seek 回开头）不必再取一次
    if (_coverSeedPath == track.path && theme.coverSeed != null) {
      return;
    }
    _coverSeedPath = track.path;
    unawaited(_loadCoverSeed(track.coverPath, track.path, theme));
  }

  Future<void> _loadCoverSeed(
    String? coverPath,
    String path,
    ThemeController theme,
  ) async {
    final Color? seed = await CoverPaletteCache.loadSeed(coverPath);
    if (!mounted || _coverSeedPath != path || seed == null) {
      return;
    }
    _requestCoverSeed(theme, seed);
  }

  /// 前沿节流：正常换歌立刻生效，连点「下一首」时只落地最后一次。
  ///
  /// 每次换主题都是一次整树重建（实测 debug 下 ~70ms 的尖峰），一首一首跟着换
  /// 在快速跳歌时会白烧一串。400ms 的窗口对正常听歌没有可感延迟——封面本身
  /// 也是这个量级才画出来。
  void _requestCoverSeed(ThemeController theme, Color seed) {
    if (_coverSeedTimer != null) {
      _pendingCoverSeed = seed;
      return;
    }
    // 还是同一个颜色：什么都不用做，连计时器都不用起
    if (theme.coverSeed == seed) {
      return;
    }
    theme.updateCoverSeed(seed);
    _coverSeedTimer = Timer(const Duration(milliseconds: 400), () {
      _coverSeedTimer = null;
      final Color? next = _pendingCoverSeed;
      _pendingCoverSeed = null;
      if (next != null && mounted) {
        _requestCoverSeed(theme, next);
      }
    });
  }

  /// 起播时下发给引擎的 ReplayGain 增益（dB）。
  ///
  /// 开关关掉就是 0。开着时按当前设置（参考响度 + 峰值类型）现算：
  /// 优先用现场测出的响度 / 峰值（曲库里的或本会话缓存的），
  /// 没有测量值就退回标签增益并按参考响度偏移；两者都没有就按 0 起播、
  /// 之后再补算——现场分析要全曲解码，等不起。
  ///
  /// 用测量值而不是存下来的 dB：改参考响度 / 换峰值类型立刻生效，
  /// 不用把整个曲库重算一遍。
  double _gainFor(Track track) {
    if (!_replayGain) {
      return 0;
    }
    final rust.LoudnessAnalysis? measured = _autoLoudness[track.path];
    final double loudness = measured?.loudnessLufs ?? track.loudnessLufs;
    if (loudness != 0) {
      final double peak = _replayGainTruePeak
          ? (measured?.truePeak ?? track.truePeak)
          : (measured?.samplePeak ?? track.samplePeak);
      return replayGainForLoudness(
        loudnessLufs: loudness,
        peak: peak,
        referenceLufs: _replayGainReference,
      );
    }
    if (track.replayGain != 0) {
      return replayGainForTag(
        track.replayGain,
        referenceLufs: _replayGainReference,
      );
    }
    return 0;
  }

  /* ------------------------------------------------------ 启动预加载 */

  /// 启动时把上次的曲目预先装进引擎并暂停。
  ///
  /// 好处是引擎不再是 `stopped`：进度条天然可拖、拖动走的是真 seek，不用
  /// 「续播点」在界面上补偿。代价是启动多打开一次文件、多占一路 channel。
  ///
  /// 触发点有两个——`_restoreLastTrack` 读完会话、`_applyStartupAudio` 把
  /// 输出设备准备好。谁后到谁真正干活，先到的那个直接返回。
  void _maybePreloadRestoredTrack() {
    if (_preloadAttempted || !_isAvailable || !_startupAudioApplied) {
      return;
    }
    if (_currentTrack == null) {
      return;
    }
    _preloadAttempted = true;
    // 走播放命令串行链：预加载跑在 play → pause → seek 中间时，用户按播放
    // 会抢在 pause 之前进来，`resume` 刚生效就被预加载按回去。排在链尾后，
    // 用户的命令一定在预加载结束之后才执行。
    unawaited(_serial(_preloadRestoredTrack));
  }

  Future<void> _preloadRestoredTrack() async {
    final Track? track = _currentTrack;
    if (track == null) {
      return;
    }
    final double startAt = _pendingResumePosition ?? 0;
    // 打开文件到能 seek 的耗时：这一步是整个方案的代价所在，
    // `--dart-define=LAMP_FRAME_LOG=true` 时打一行，方便对着实测量
    final Stopwatch? watch = frameLogEnabled ? (Stopwatch()..start()) : null;
    try {
      // 装进引擎的那一瞬是真的在推流，先把音量压到 0，暂停之后再还原
      await _playback.setVolume(0);
      await _playback.preload(
        track.path,
        replayGainDb: _gainFor(track),
        positionSecs: startAt,
      );
      await _playback.setVolume(volumeToAmplitude(_volume));
    } catch (error) {
      // 预加载失败不该影响使用：引擎已回到 stopped，按播放时仍走老路
      debugPrint('预加载上次曲目失败：$error');
      if (watch != null) {
        debugPrint('[preload] 失败，耗时 ${watch.elapsedMilliseconds} ms');
      }
      try {
        await _playback.setVolume(volumeToAmplitude(_volume));
      } catch (_) {
        // 音量还原失败只能等用户下一次调音量
      }
      return;
    }
    if (watch != null) {
      debugPrint('[preload] 上次曲目装进引擎 ${watch.elapsedMilliseconds} ms');
    }
    if (!mounted) {
      return;
    }
    // 位置已经在引擎里了：留着续播点只会让「退回 stopped」的路径再 seek 一次
    _pendingResumePosition = null;
    // 与真实起播保持一致：正在播放页要能直接看到这首歌的歌词
    unawaited(_loadLyrics(track.path));
  }

  /* --------------------------------------------------- 系统媒体控制 */

  /// 把播放模式同步给系统浮层。
  ///
  /// Windows 的循环 / 随机按钮靠 `AutoRepeatMode` 与 `ShuffleEnabled` 两个属性
  /// 决定「显不显示、亮不亮、点了算不算」：一直不报就是灰的。
  void _publishPlayMode() {
    unawaited(
      _media.setPlayMode(repeat: _queue.repeat, shuffle: _queue.shuffle),
    );
  }

  void _mediaRepeatChanged(LoopMode mode) {
    _update(() {
      _queue.setRepeat(mode);
      if (mode != LoopMode.off) {
        _queue.setShuffle(false);
      }
    });
    _publishPlayMode();
    _saveSessionNow();
  }

  /// 系统浮层打开了随机：同理，随机与循环只能二选一。
  void _mediaShuffleChanged(bool enabled) {
    _update(() {
      _queue.setShuffle(enabled);
      if (enabled) {
        _queue.setRepeat(LoopMode.off);
      }
    });
    _publishPlayMode();
    _saveSessionNow();
  }

  /// 把「当前曲目 + 播放状态」同步给 Windows 系统媒体控制。
  ///
  /// 只在状态真的变化时调用（起播 / 暂停 / 停止），**不要放进 500ms 轮询**：
  /// 每次都会走一遍 WinRT 调用。
  void _syncMediaSession({bool stopped = false}) {
    hangMark('播放：同步系统媒体信息');
    // 频谱流的开关注释挂在同一批状态切换点上：放歌开始订阅、暂停 / 停止退订
    _syncSpectrum();
    // 桌面歌词工具栏的播放 / 暂停字形
    _syncDesktopLyricPlaying();
    final Track? track = _currentTrack;
    // 任务栏缩略图工具栏：字形跟播放状态走，没曲目时整排收起
    unawaited(
      TaskbarThumbnail.setButtons(
        isPlaying: track != null && !stopped && _isPlaying,
        visible: track != null,
      ),
    );
    // 悬停预览换成方形封面（没封面就退回窗口截图）
    _syncTaskbarCover(track);
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

  /// 把当前曲目的封面推给任务栏悬停预览（方形封面）。
  ///
  /// 只在换曲时读文件：同一首的暂停 / 播放靠路径比对挡掉，不重复 IO。
  /// 用同步读是因为封面只有几百 KB，换曲那一下读完更省事 —— 异步读会给
  /// 文件开一个短暂句柄，切歌 / 删封面时容易撞上「另一个程序正在使用」。
  void _syncTaskbarCover(Track? track) {
    final String? path = track?.coverPath;
    if (path == _taskbarCoverPath) {
      return;
    }
    _taskbarCoverPath = path;
    if (path == null || !File(path).existsSync()) {
      unawaited(TaskbarThumbnail.clearCover());
      return;
    }
    try {
      unawaited(TaskbarThumbnail.setCover(File(path).readAsBytesSync()));
    } catch (error) {
      // 封面文件读不动：悬停退回窗口截图，不影响播放
      unawaited(TaskbarThumbnail.clearCover());
      debugPrint('任务栏封面读取失败：$error');
    }
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
    _updatePlayer(() => _isPlaying = false);
    _publishProgress();
    _saveSessionNow();
    _syncMediaSession(stopped: true);
  }

  /// 打开「正在播放」页（大封面 + 同步歌词）
  ///
  /// 同一时刻只允许一页：播放条、快捷键（O）、托盘回调都能触发它，
  /// 手快连点会叠出两三页全屏播放页（每页一份流光 + 歌词 + 大封面），
  /// 内存会成倍地跳。已经在栈上就直接忽略这次。
  Future<void> _openNowPlaying() {
    if (_nowPlayingOpen) {
      return Future<void>.value();
    }
    _nowPlayingOpen = true;
    hangMark('界面：打开正在播放页');
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
          NowPlayingPageRoute(
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
              onToggleDesktopLyrics: () =>
                  unawaited(_setDesktopLyrics(!_desktopLyrics)),
              onToggleDesktopLyricLock: () =>
                  unawaited(_setDesktopLyricLocked(!_desktopLyricLocked)),
              // 点歌手 / 专辑：退出播放页，进曲库对应的详情
              onOpenArtist: _openArtistFromNowPlaying,
              onOpenAlbum: _openAlbumFromNowPlaying,
              // 选择艺术家弹窗里要给每位候选画自己的头像
              artistCoverOf: _artistCoverOf,
              animateBackground: _flowBackground,
              // 歌词对齐 / 译文开关都走通知器：改完只重画歌词，不必重建整页
              lyricAlignment: _lyricAlignment,
              onCycleLyricAlignment: _cycleLyricAlignment,
              showTranslation: _showTranslation,
              onToggleTranslation: _toggleTranslation,
              // 沉浸模式跨页记着：播放页销毁后重进要还原
              immersive: _immersive,
              onImmersiveChanged: _setImmersive,
              lyricFontFamily: _lyricFontFamily,
              lyricFontSize: _lyricFontSize.toDouble(),
              lyricFontWeight: _lyricFontWeight,
              lyricBlur: _lyricBlur,
              lyricSpring: _lyricSpring,
              lyricEmbeddedFirst: embeddedFirstIn(_lyricSourceOrder),
              // 播放页整个盖住了外壳标题栏，拖动区得靠它自己
              windowControls: _windowControls,
              shortcuts: _shortcuts,
              sleepTimer: _sleepTimer,
            ),
          ),
        )
        .whenComplete(() {
          _nowPlayingOpen = false;
          _nowPlayingDeviceTimer?.cancel();
          _nowPlayingDeviceTimer = null;
          // 这一页是内存大头（流光 + 大封面 + 歌词），关掉之后立刻补查一次
          MemoryGuard.checkSoon(delay: const Duration(seconds: 1));
        });
  }

  /// 正在播放页点歌手：退出播放页，切到「艺术家」分区并进该艺术家的详情。
  void _openArtistFromNowPlaying(Track track, String artist) {
    _jumpToDetail(
      section: LibrarySection.artists,
      select: () => _selectedArtist = artist,
    );
  }

  /// 听歌统计点艺术家：切到「艺术家」分区并进这位的详情。
  ///
  /// 统计页给的已经是拆好的单个名字（合唱标签在那里就拆成两位了），
  /// 这里直接当聚合键用，不再过一遍拆分。
  ///
  /// 不用 pop：统计现在是设置分区里的子界面、没有独立路由，`maybePop` 会把
  /// 整个曲库页弹掉。收起子页由 `_selectSection` 换分区时顺手完成。
  void _openArtistFromStats(String artist) {
    _jumpToDetail(
      section: LibrarySection.artists,
      pop: false,
      select: () => _selectedArtist = artist,
    );
  }

  /// 正在播放页点专辑：同上，按「歌手 + 专辑名」的聚合键进专辑详情。
  void _openAlbumFromNowPlaying(Track track) {
    _jumpToDetail(
      section: LibrarySection.albums,
      select: () => _selectedAlbumKey = albumGroupKey(track),
    );
  }

  /// 从别处跳到某个分区的详情（艺术家 / 专辑）。
  ///
  /// 先退掉播放页——详情在曲库页里，留在播放页上什么都看不到。然后交给
  /// [_selectSection] 把「换分区」和「选中目标」放在同一帧完成：单独往后推
  /// 一帧的话，中间那一帧会先把目标分区的列表画出来，看着就像「先跳到列表、
  /// 才跳到详情」。
  void _jumpToDetail({
    required LibrarySection section,
    required VoidCallback select,
    bool pop = true,
  }) {
    if (pop) {
      Navigator.of(context).maybePop();
    }
    _clearSearch();
    _clearSelection();
    _selectSection(section, select: select);
  }

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    await _playFrom(tracks, tracks.first);
  }

  /// 历史记录失败不影响播放，只记录日志。
  Future<void> _touchPlayHistory(String path) async {
    try {
      await _repository.touchPlayHistory(path);
    } catch (error) {
      debugPrint('更新最近播放失败：$error');
    }
  }

  /// 历史记录失败不影响播放，只记录日志。
  Future<void> _recordPlay(String path) async {
    try {
      await _repository.recordPlay(path);
      // 次数变了：统计缓存标记为过期（下次打开仍先画旧内容，后台再刷）
      invalidateListeningStats(repository: widget.statsRepository);
    } catch (error) {
      debugPrint('记录播放历史失败：$error');
    }
  }

  /// 采样一次进度：判断要不要记一次播放、并把增量计入当天。
  ///
  /// 只认 0 < delta < 3 秒：seek 跳变、切歌跨度都不是真正听过的时长，
  /// 也不会因为一次跳变就凑够「听过一半」。
  void _accumulatePlayTime(double position) {
    final Track? track = _currentTrack;
    final double delta = position - _lastPollPosition;
    _lastPollPosition = position;
    if (track == null || !_isPlaying || delta <= 0 || delta > 3) {
      return;
    }
    _playedSinceStart += delta;
    _countPlayIfEnough(track);
    _accumulateSessionTime(track, delta);
  }

  /// 这一轮播放真正听过的秒数对应的门槛；时长未知（0）时不设门槛
  double _requiredBefore(Track track, double ratio) {
    final double duration = _duration > 0 ? _duration : track.durationSecs;
    return duration > 0 ? duration * ratio : 0;
  }

  /// 听过一半才算一次播放：按「本轮真正听过的秒数」判，不按播放位置。
  ///
  /// 位置到了 50% 也可能是拖过去的，那样一次跳变就白得一次计数；按听过的
  /// 秒数算，拖回、暂停、跳着听都骗不到。一次起播只计一次——暂停再继续、
  /// 拖回重听都不会重复加，只有真的重新起播（下一首 / 从头再播）才归零。
  void _countPlayIfEnough(Track track) {
    if (_playCountedThisStart) {
      return;
    }
    if (_playedSinceStart <
        _requiredBefore(track, _LibraryPageState._playCountRatio)) {
      return;
    }
    _playCountedThisStart = true;
    unawaited(_recordPlay(track.path));
  }

  /// 听过四分之一之后才开始累计听歌时长：点开就切走的那种不该算「听过」。
  void _accumulateSessionTime(Track track, double delta) {
    if (_playedSinceStart <
        _requiredBefore(track, _LibraryPageState._playTimeRatio)) {
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
      invalidateListeningStats(repository: widget.statsRepository);
    } catch (error) {
      debugPrint('记录听歌时长失败：$error');
    }
  }

  Future<void> _togglePlayback() => _serial(_togglePlaybackNow);

  Future<void> _togglePlaybackNow() async {
    hangMark('播放：切换播放/暂停');
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
      _updatePlayer(() => _isPlaying = !_isPlaying);
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
    hangMark(auto ? '播放：自动下一首' : '播放：下一首');
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
        _updatePlayer(() {
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
        _updatePlayer(() => _isPlaying = false);
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

  /// 上一首：直接切上一首；已经在队首（或没有上一首历史）时回到本曲开头。
  ///
  /// 早先照搬「播放超过 3 秒先回本曲开头」的桌面播放器习惯，实际用起来是
  /// 「点了没反应，得再点一次才切歌」，用户明确否掉了。
  Future<void> _previous() => _serial(_previousNow);

  Future<void> _previousNow() async {
    hangMark('播放：上一首');
    if (_currentTrack == null) {
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
    _publishPlayMode();
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
  ///
  /// 多选模式下、且右键落点就在已勾选的行上时，整批操作：工具条撤掉之后，
  /// 批量入口只剩这一处，逐首处理会让「勾了 20 首却只隐藏 1 首」变成陷阱。
  void _onTrackContext(
    List<Track> tracks,
    Track track,
    TrackContextAction action,
  ) {
    final bool batch =
        _selectionMode &&
        _selectedPaths.contains(track.path) &&
        _selectedPaths.length > 1;
    if (batch) {
      switch (action) {
        case TrackContextAction.play:
          unawaited(_playSelected());
        case TrackContextAction.playNext:
          _playNextSelected();
        case TrackContextAction.addToQueue:
          _enqueueSelected();
        case TrackContextAction.toggleFavorite:
          unawaited(_favoriteSelected());
        case TrackContextAction.addToPlaylist:
          unawaited(_addSelectedToPlaylist());
        case TrackContextAction.computeReplayGain:
          unawaited(_computeReplayGainFor(_selectedTracks));
        case TrackContextAction.removeFromLibrary:
          unawaited(_removeSelected());
        // 单文件操作：批量菜单里不出现，真被调用到就忽略
        case TrackContextAction.revealInExplorer:
        case TrackContextAction.copyPath:
        case TrackContextAction.editMetadata:
        case TrackContextAction.openWithMusicTag:
          break;
      }
      return;
    }

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
      case TrackContextAction.computeReplayGain:
        unawaited(_computeReplayGainFor(<Track>[track]));
      case TrackContextAction.removeFromLibrary:
        unawaited(_removeTrackFromLibrary(track));
      case TrackContextAction.revealInExplorer:
        unawaited(_revealInExplorer(track));
      case TrackContextAction.copyPath:
        unawaited(_copyPath(track));
      case TrackContextAction.editMetadata:
        unawaited(_editTrackMetadata(track));
      case TrackContextAction.openWithMusicTag:
        unawaited(_openWithMusicTag(track));
    }
  }

  /// 多选批量「下一首播放」：按列表顺序插到当前曲目后面。
  ///
  /// 倒着插是因为 `insertNext` 每次都紧贴当前曲目，正着插会得到倒序。
  void _playNextSelected() {
    final List<Track> tracks = _selectedTracks;
    if (tracks.isEmpty) {
      return;
    }
    if (_queue.isEmpty) {
      unawaited(_playFrom(tracks, tracks.first));
      return;
    }
    int added = 0;
    for (final Track track in tracks.reversed) {
      if (track.path != _queue.current?.path && _queue.insertNext(track)) {
        added += 1;
      }
    }
    _update(() {});
    if (added > 0) {
      _saveSessionNow();
    }
    _showMessage(added > 0 ? '已把 $added 首排到下一首之后' : '这些曲目都已经在队列里');
  }

  /// 右键单曲「隐藏歌曲」。
  ///
  /// 行留在库里、只打 `hidden` 标记：收藏 / 歌单 / 播放历史 / 听歌时长都挂在
  /// `tracks(path)` 外键上，删行会被级联清空；扫描也不会再把它加回来。
  /// 文件与播放队列都不动——歌还在磁盘上，正在播的那首没必要被打断。
  Future<void> _removeTrackFromLibrary(Track track) async {
    try {
      final int hidden = await _repository.hideTracks(<String>[track.path]);
      if (!mounted) {
        return;
      }
      _applyRemovedPaths(<String>{track.path});
      // 歌单曲目数会跟着变，网格里的数字要重读
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage(hidden > 0 ? '已隐藏：${track.title}' : '曲库里已经没有这首');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('隐藏失败：${ErrorRetry.describe(error)}');
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
  ///
  /// 提示**常驻**（`persistent`）：编辑在另一个窗口里进行，几秒钟就消失的提示等于
  /// 没有——用户回来时早就找不到「刷新」了。
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
      actionLabel: '改完了，刷新',
      onAction: () => unawaited(_refreshTrackFolder(p.dirname(track.path))),
      // MusicTag 是外部程序，改标签要花几分钟：这条提示不能自己消失
      persistent: true,
    );
  }

  /// 右键「修改元数据」：把右侧内容区整块换成编辑界面（不是弹窗）。
  ///
  /// 读的是**文件标签本身**（不是曲库里那一行）：年份、流派、专辑艺术家、
  /// 碟号曲库根本没有。读标签要走文件 IO——本地 SSD 上常常几十毫秒就回来了，
  /// 立刻铺一屏「正在读取标签…」反而是闪一下，所以占位延迟
  /// [_metadataLoadingDelay] 才出现；真慢的时候才看得到反馈。
  Future<void> _editTrackMetadata(Track track) async {
    final int request = ++_metadataRequest;
    _metadataOpenTimer?.cancel();
    // 淡入：从透明 + 略微下移的位置浮上来，和分区详情用同一条曲线
    _metadataClosing = false;
    _metadataFade.forward(from: 0);
    _metadataOpenTimer = Timer(_metadataLoadingDelay, () {
      if (!mounted || request != _metadataRequest) {
        return;
      }
      _update(() {
        _metadataTrack = track;
        _metadataTags = null;
        _metadataLyrics = '';
        _metadataSource = 'none';
        _metadataLoading = true;
      });
    });

    final TrackTags tags;
    final lyrics_api.RawLyrics raw;
    try {
      tags = await readTrackTags(path: track.path);
      raw = await lyrics_api.lyricsReadRaw(path: track.path);
    } catch (error) {
      if (!mounted || request != _metadataRequest) {
        return;
      }
      _closeMetadataEditor();
      _showMessage('读取标签失败：${_errorText(error)}');
      return;
    }
    // 读取期间用户可能已经返回 / 切了分区 / 点了另一首：别把界面抢回来
    if (!mounted || request != _metadataRequest) {
      return;
    }
    _metadataOpenTimer?.cancel();
    _update(() {
      _metadataTrack = track;
      _metadataTags = tags;
      _metadataLyrics = raw.text;
      _metadataSource = raw.source;
      _metadataLoading = false;
    });
  }

  /// 退出编辑界面（不保存）。分区切换、点导航也会调它。
  ///
  /// 顺带推进请求号：还没回来的那次读取看到号变了就自己作废，不会把界面
  /// 重新打开。
  void _closeMetadataEditor() {
    _metadataOpenTimer?.cancel();
    final int token = ++_metadataRequest;
    if (_metadataTrack == null && !_metadataLoading) {
      return;
    }
    // 先淡出再清状态：动画期间界面还在（下面的分区已经放出来），播完才换回
    // 列表。清状态放进回调里，是为了让「淡出」有东西可淡
    _metadataClosing = true;
    _update(() {});
    _metadataFade.reverse().whenComplete(() {
      // 期间又打开了另一首（或又关了一次）：这次回调作废，别把它盖掉
      if (!mounted || token != _metadataRequest) {
        return;
      }
      _metadataClosing = false;
      _update(() {
        _metadataTrack = null;
        _metadataTags = null;
        _metadataLyrics = '';
        _metadataSource = 'none';
        _metadataLoading = false;
      });
    });
  }

  /// 编辑界面里点封面：选一张本地图片。
  ///
  /// 只选不写——回来的路径先显示在界面上，点「保存」才真正嵌进音频文件，
  /// 中途取消不该改动任何文件。
  ///
  /// 只列能解码的格式：webp 不在 `image` crate 启用的解码器里，
  /// 选进来只会换来一句「这不是有效的图片文件」。
  Future<String?> _pickMetadataCover() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(
          label: '图片',
          extensions: <String>['jpg', 'jpeg', 'png', 'gif', 'bmp'],
        ),
      ],
    );
    return file?.path;
  }

  /// 编辑界面点「保存」：写标签 → 写封面 → 写歌词 → 同步曲库那一行。
  ///
  /// 出错直接抛给界面（它在底部显示原因），这里不吞——写不进去多半是文件
  /// 只读或格式不支持，用户需要知道。
  Future<void> _saveMetadata(Track track, MetadataDraft draft) async {
    final TrackTags written = await writeTrackTags(
      path: track.path,
      tags: draft.tags,
    );
    // 换封面：嵌进音频文件，同时落一份到封面缓存。顺序放在标签之后——
    // 它要重写整个文件，先写标签再写封面，两次保存互不覆盖
    String? coverPath = track.coverPath;
    final String? coverSource = draft.coverSource;
    if (coverSource != null) {
      final String cached = await writeTrackCover(
        path: track.path,
        source: coverSource,
      );
      if (cached.isNotEmpty) {
        coverPath = cached;
      }
    }
    // 空歌词不落盘：删用户已有的 `.lrc` 是破坏性操作，不在这里顺手做
    if (draft.lyrics.trim().isNotEmpty) {
      await lyrics_api.lyricsSaveRaw(
        path: track.path,
        text: draft.lyrics,
        target: draft.embedLyrics ? 'embedded' : 'sidecar',
      );
    }
    await _upsertEditedTrack(track, written, coverPath: coverPath);
    if (!mounted) {
      return;
    }
    _showMessage('已保存「${written.title}」');
  }

  /// 把改完的标签同步进曲库那一行（保留入库时间、封面、增益等文件外的信息）
  Future<void> _upsertEditedTrack(
    Track track,
    TrackTags written, {
    String? coverPath,
  }) async {
    await db.upsertTracks(
      tracks: <Track>[
        Track(
          path: track.path,
          title: written.title.isEmpty ? track.title : written.title,
          artist: written.artist.isEmpty ? null : written.artist,
          album: written.album.isEmpty ? null : written.album,
          durationSecs: track.durationSecs,
          // `03/12` 这种「第 3 首，共 12 首」只取前半截；清空就是 null
          trackNum: int.tryParse(written.trackNo.split('/').first.trim()),
          addedAt: track.addedAt,
          coverPath: coverPath ?? track.coverPath,
          replayGain: track.replayGain,
          // 音质字段与标签无关，原样带回去，别被这次重写的 0 覆盖掉
          fileSize: track.fileSize,
          audioBitrate: track.audioBitrate,
          sampleRate: track.sampleRate,
          bitDepth: track.bitDepth,
          // ReplayGain 的测量值也原样带回，别让这次重写把它清零
          loudnessLufs: track.loudnessLufs,
          samplePeak: track.samplePeak,
          truePeak: track.truePeak,
        ),
      ],
    );
    // 收藏 / 历史 / 歌单各自持有曲目副本，只重拉 `_tracks` 它们会停在旧标题上
    markLibraryChanged();
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
    // 拖动过程中 `_position` 会被预览值覆盖，先把「真正的位置」记下来
    _seekOrigin = _position;
    _stopPositionPolling();
  }

  void _onSeekChanged(double seconds) {
    // 拖动预览只推播放条：`_update` 会推进 `_stateVersion`，
    // 把当前分区（可能是一整页封面网格）整棵重建。
    _position = seconds;
    _publishProgress();
  }

  Future<void> _seekTo(double seconds) async {
    hangMark('播放：跳转 ${seconds.toStringAsFixed(1)}s');
    if (!_isAvailable) {
      return;
    }
    // 失败要退回「这一下之前」的位置：拖动时是按下前的（拖动中 `_position`
    // 已是预览值），键盘快进时就是当前位置。
    final double origin = _seekOrigin ?? _position;
    // seek 往返期间轮询会读到旧位置、把界面推回去。拖动一直靠 `_seeking`
    // 挡着，键盘快进这条路径以前没挡，按一下会看到进度闪回再跳过去。
    final bool alreadySeeking = _seeking;
    _seeking = true;
    try {
      await _playback.seek(seconds);
      if (!mounted) {
        return;
      }
      _position = seconds;
      _publishProgress();
      // 拖动位置也要落盘：暂停着拖几下就退出，重启该停在新位置而不是旧位置。
      // 走 400ms 合并窗口，键盘连按快进不会每下都写一次盘。
      _scheduleSessionSave();
    } catch (error) {
      if (!mounted) {
        return;
      }
      // 引擎没跳成：界面也得回来，否则显示的是一段根本没播的位置
      _position = origin.clamp(0.0, _duration > 0 ? _duration : origin);
      _publishProgress();
      _showMessage('跳转失败：${ErrorRetry.describe(error)}');
    } finally {
      // 拖动期间由 _onSeekEnd 负责复位，别在这里抢
      if (!alreadySeeking) {
        _seeking = false;
      }
    }
  }

  Future<void> _onSeekEnd(double seconds) async {
    _seeking = false;
    if (_currentTrack != null && _isAvailable) {
      if (_isStopped) {
        // 停止态（还没起播 / 播完）引擎里没有加载曲目，seek 无处可去；
        // 但用户拖这一下不该白费——记成续播点，按播放时从这里开始
        _deferSeek(seconds);
      } else {
        await _seekTo(seconds);
      }
    }
    _seekOrigin = null;
    if (_isPlaying && _positionTimer == null) {
      _startPositionPolling();
    }
  }

  /// 停止态下把拖到的位置记成续播点。
  ///
  /// 起播走的是 `_startCurrent(startAt: _pendingResumePosition ?? 0)`，所以只要
  /// 这里写进去，播放键按下时就会从这个位置开始，而不是从头。
  /// 1 秒以内当作「从头」，免得手一抖落个 0.4 秒的续播点。
  void _deferSeek(double seconds) {
    final double target = seconds.clamp(
      0.0,
      _duration > 0 ? _duration : seconds,
    );
    _pendingResumePosition = target > 1 ? target : null;
    _position = target;
    _publishProgress();
    // 立刻落盘：会话里存的 `lastPositionSecs` 就是 `_position`，不写的话这个
    // 续播点只活在内存里，关掉再开又回到上次保存的位置。走 400ms 合并窗口，
    // 键盘连按不会每下都写一次盘；真在这 400ms 内退出，dispose 里还有一次
    // 立即保存兜底。
    _scheduleSessionSave();
  }

  /// 键盘快进 / 快退 5 秒
  Future<void> _seekBy(double delta) async {
    if (_currentTrack == null || !_isAvailable) {
      return;
    }
    final double maxPosition = _duration > 0 ? _duration : _position + delta;
    final double target = (_position + delta).clamp(0.0, maxPosition);
    if (_isStopped) {
      // 还没起播：同样只是在攒续播点（见 [_deferSeek]）
      _deferSeek(target);
      return;
    }
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
    // 播放页的图标 / 滑杆读的是 NowPlayingData.volume，那份快照只有
    // _publishProgress 才推；少了这一句引擎其实已经静音，界面却纹丝不动
    _publishProgress();
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
    } catch (error) {
      // 单次失败（引擎忙、响应中断）不该让进度条永久冻住：
      // 连续失败达到上限才停，期间继续按周期重试。
      // 只在放弃时打一行：250ms 一次的失败会把日志刷满。
      _pollFailures += 1;
      if (_pollFailures >= _LibraryPageState._maxPollFailures) {
        debugPrint('读取播放进度连续失败，已停表：$error');
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
      // 列表没变就不 setState：轮询每 3 秒一次，白重建设置页没意义。
      // 三个字段都要比：只比 index 的话，蓝牙耳机改名、系统换默认设备都不会刷新
      final bool same = samePlayerDevices(devices, _devices);
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
    } finally {
      if (mounted) {
        _update(() => _switchingOutput = false);
      }
      unawaited(_refreshDevices());
    }
  }

  /// 标签里没有增益、也没测量过时现场分析整曲（ReplayGain 2.0）。
  ///
  /// 结果由引擎写回曲库（下次起播直接带上），这里另存一份会话缓存，
  /// 让本次运行里再次播放同一首时不用重算——也是「改参考响度不用重算」
  /// 的依据：缓存的是响度 / 峰值，增益每次都按当前设置现算。
  /// 同一路径同时只跑一次：后台补算和「起播后补算」可能撞在一起。
  /// 分析失败静默回落 null（按 0 不调整）：为了一个坏文件弹提示不值得，
  /// 播放本身马上还会给出真正的失败原因。
  Future<rust.LoudnessAnalysis?> _autoGain(String path) {
    final rust.LoudnessAnalysis? cached = _autoLoudness[path];
    if (cached != null) {
      return Future<rust.LoudnessAnalysis?>.value(cached);
    }
    return _autoLoudnessPending[path] ??= _analyzeGain(path).whenComplete(() {
      // 用块体：`whenComplete` 会把回调返回的 Future 一起等，
      // 写成 `=> _autoLoudnessPending.remove(path)` 就等于等自己，永远不完成
      _autoLoudnessPending.remove(path);
    });
  }

  Future<rust.LoudnessAnalysis?> _analyzeGain(String path) async {
    try {
      final rust.LoudnessAnalysis measured = await _playback.analyzeReplayGain(
        path,
      );
      return _autoLoudness[path] = measured;
    } catch (_) {
      return null;
    }
  }

  /// 预热第一轮先算的「马上要听」窗口：当前曲目之后几首
  static const int _warmNearCount = 5;

  /// 慢补两首之间的空档。分析一首要把整段音频解一遍（1~2 秒满负荷），
  /// 连着跑就是一个核被占满、磁盘一直在读；播放中还要解码出帧，空档再拉长。
  static const Duration _warmGapIdle = Duration(seconds: 3);
  static const Duration _warmGapPlaying = Duration(seconds: 8);

  /// 增益还不知道：标签里没有、也没测量过
  bool _gainUnknown(Track track) =>
      track.replayGain == 0 &&
      track.loudnessLufs == 0 &&
      !_autoLoudness.containsKey(track.path);

  /// 预热第一轮要算的曲目：当前曲目 + 队列紧接着的几首。
  ///
  /// 这一小批决定「下一首起播有没有归一」，必须一条不落地先算完。
  /// 随机模式下下一首是现抽的，队列顺序推不出来，所以单独问一次 [peekNext]。
  List<Track> _warmNearTracks() {
    final List<Track> near = <Track>[];
    void add(Track? track) {
      if (track == null || !_gainUnknown(track)) {
        return;
      }
      if (near.any((Track other) => other.path == track.path)) {
        return;
      }
      near.add(track);
    }

    add(_currentTrack);
    add(_queue.current);
    final List<Track> queue = _queue.tracks;
    final int? next = _queue.peekNext();
    if (next != null && next >= 0 && next < queue.length) {
      add(queue[next]);
    }
    final int start = _queue.index;
    for (
      int i = 1;
      start >= 0 && i <= _warmNearCount && start + i < queue.length;
      i += 1
    ) {
      add(queue[start + i]);
    }
    return near;
  }

  /// 慢补的空档：可被 [dispose] 取消（页面销毁后循环停在这里不再往下走）
  Future<void> _warmGainPause() {
    final Completer<void> done = Completer<void>();
    _warmGainTimer?.cancel();
    _warmGainTimer = Timer(
      _isPlaying ? _warmGapPlaying : _warmGapIdle,
      done.complete,
    );
    return done.future;
  }

  /// 启动后在后台把还没有增益的曲目算一遍，结果由引擎写进曲库。
  ///
  /// 增益未知时起播不做归一（见 [_startCurrent]），所以要让「已知」尽快覆盖
  /// 整个曲库：算过就落库，之后每次起播都直接带上，只跑这一次。
  ///
  /// 分两轮：先算马上要听的（当前 + 队列随后几首），它们决定下一次切歌的
  /// 听感；剩下的低频慢补。一次把全库算完等于冷启动几分钟满负荷——风扇
  /// 一直转、磁盘一直在读，而这部分工作摊平了没有任何损失。
  Future<void> _warmAutoGains() async {
    if (!widget.prefetchReplayGain || !_replayGain || !_isAvailable) {
      return;
    }
    for (final Track track in _warmNearTracks()) {
      if (_warmGainsCancelled || !_replayGain) {
        return;
      }
      await _autoGain(track.path);
    }
    // 快照：分析期间曲库可能被重扫换掉
    for (final Track track in List<Track>.of(_tracks)) {
      if (_warmGainsCancelled || !_replayGain) {
        return;
      }
      if (!_gainUnknown(track)) {
        continue;
      }
      await _warmGainPause();
      if (_warmGainsCancelled || !_replayGain) {
        return;
      }
      await _autoGain(track.path);
    }
  }

  /// ReplayGain 开关：只影响下一首起播，不做实时调整（改增益会突然变响）
  void _setReplayGain(bool value) {
    if (_replayGain == value) {
      return;
    }
    _update(() => _replayGain = value);
    _saveSessionNow();
    // 刚打开时曲库里还没有增益：立刻开始补算，否则每首都要「先响一遍」
    if (value) {
      unawaited(_warmAutoGains());
    }
  }

  /// 参考响度（LUFS）：只影响下一首起播，不实时改音量。
  ///
  /// 曲库存的是测量值，换参考响度不需要重算，下一首起播直接按新目标算。
  void _setReplayGainReference(double value) {
    if (_replayGainReference == value) {
      return;
    }
    _update(() => _replayGainReference = value);
    _saveSessionNow();
  }

  /// 峰值类型（采样 / 真实峰值）：同样只影响下一首起播。
  void _setReplayGainTruePeak(bool value) {
    if (_replayGainTruePeak == value) {
      return;
    }
    _update(() => _replayGainTruePeak = value);
    _saveSessionNow();
  }

  /// 换曲淡变时长（秒）；0 关闭
  /// 开关淡变：打开恢复到上次时长，关闭置 0
  Future<void> _setCrossfadeEnabled(bool enabled) =>
      _setCrossfade(enabled ? _lastCrossfadeSeconds : 0);

  Future<void> _setCrossfade(double seconds) async {
    // 非零时长记下来，关掉开关再打开时回到上次的值
    if (seconds > 0) {
      _lastCrossfadeSeconds = seconds;
    }
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

  /// 音量过渡开关（暂停 / 停止淡出，起播与定位后淡入）
  Future<void> _setVolumeFade(bool enabled) async {
    if (_volumeFade == enabled) {
      return;
    }
    _update(() => _volumeFade = enabled);
    _saveSessionNow();
    try {
      await _playback.setVolumeFade(enabled);
    } catch (error) {
      if (mounted) {
        _showMessage('设置音量过渡失败：${ErrorRetry.describe(error)}');
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

  /// 播放失败的提示文案：文件本身不在了就直说，别再让人去读 BASS 错误码
  /// （`无法打开文件` 是「被删掉 / 改名 / 移走」的常见表现）
  String _playFailureText(Object error, String path) {
    if (!File(path).existsSync()) {
      return '播放失败：找不到这首文件了，可能已被删除或移走';
    }
    return '播放失败：${ErrorRetry.describe(error)}';
  }

  void _showMessage(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    bool persistent = false,
  }) {
    AppToast.show(
      context,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      persistent: persistent,
    );
  }
}

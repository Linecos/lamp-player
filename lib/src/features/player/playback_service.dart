import '../../rust/api/player.dart' as rust;

/// 播放能力的抽象。
///
/// 页面只依赖这个接口：真实实现走 Rust / BASS，`test/` 下注入假实现，
/// 因此 widget 测试不需要原生库（见 CONTRIBUTING 的测试分层）。
abstract interface class PlaybackService {
  /// BASS 是否可用；同步读取，可在 build 周期之外随时调用。
  bool get isAvailable;

  /// 当前播放状态（同步读取）。
  rust.PlaybackState get state;

  /// 播放 [path]；[replayGainDb] 为曲目标签里的 ReplayGain 增益（0 = 不归一）
  Future<void> play(String path, {double replayGainDb = 0});

  /// 把 [path] 装进引擎、定位到 [positionSecs]，然后**停在暂停态**。
  ///
  /// 与 [play] 的区别只有「装完不开始走」：启动时用它把上次的曲目先备好，
  /// 引擎状态就是 `paused` 而不是 `stopped`。这样进度条天然可拖、拖动是真
  /// 的 seek，不必再靠「续播点」在界面上补偿。
  ///
  /// 实现内部会短暂起播再立刻暂停，调用方若担心漏音，可以先把音量压到 0。
  /// 定位失败时实现需要把预加载整个撤掉（回到 stopped）再抛错，调用方据此
  /// 退回「按播放时才加载」的老路径。
  Future<void> preload(
    String path, {
    double replayGainDb = 0,
    double positionSecs = 0,
  });

  /// 分析 [path] 的整曲响度，返回 ReplayGain 建议增益（dB）。
  ///
  /// 标签里没有增益时现场补算（ReplayGain 2.0，全曲解码约需 1~2 秒）；
  /// 结果会顺带写回曲库，下次起播直接带上，不必再算。
  Future<double> analyzeReplayGain(String path);

  /// 应用 ReplayGain 增益（dB），立即作用到当前输出。
  ///
  /// 目前没有调用方：自动补算只写回曲库，从下一首起播开始生效，不在播放
  /// 中途改音量（那正是「起播先响 1~2 秒、随后突然变小」的来源）。
  /// 接口保留给需要即时应用的场景。
  Future<void> setReplayGain(double gainDb);

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  /// 位置、时长与状态一次取全（轮询用）。
  ///
  /// 分开取会多出跨线程往返，而且两次之间可能换曲，进度条会跳一下。
  Future<rust.PlayerProgress> now();

  /// 跳转到 [positionSecs] 秒；超出曲目时长会被后端截断。
  Future<void> seek(double positionSecs);

  /// 设置音量，取值 `0.0..=1.0`。
  Future<void> setVolume(double volume);

  /// 当前是否真的在用 WASAPI 独占输出（同步读取）。
  bool get isExclusive;

  /// 切换独占 / 共享输出；切换会重开当前曲目，位置与播放状态保留。
  Future<void> setExclusive(bool exclusive);

  /// 当前输出的可读描述（模式 / 采样率 / 声道 / 缓冲）。
  Future<String> outputInfo();

  /// 可用的输出设备（共享模式）
  Future<List<rust.PlayerDevice>> devices();

  /// 切换输出设备（`-1` = 系统默认），保留当前曲目与进度。
  Future<void> setDevice(int index);

  /// 当前选中的设备索引（同步读取）。
  int get currentDevice;

  /// 换曲交叉淡变时长（秒）；0 关闭
  Future<void> setCrossfade(double seconds);

  /// 音量过渡开关：暂停 / 停止淡出，起播与定位后淡入
  Future<void> setVolumeFade(bool enabled);

  /// 设置 10 段均衡器；`gains` 为 31Hz→16kHz 各段增益（dB）
  Future<void> setEqualizer({
    required bool enabled,
    required List<double> gains,
  });
}

/// 走 `flutter_rust_bridge` 的真实实现。
///
/// `player.rs` 已接入 BASS；DLL 缺失或初始化失败时 `isAvailable` 返回 false，
/// 其余调用会抛错，界面据此降级为「只能浏览曲目」。
class RustPlaybackService implements PlaybackService {
  const RustPlaybackService();

  @override
  bool get isAvailable {
    try {
      return rust.playerIsAvailable();
    } catch (_) {
      return false;
    }
  }

  @override
  rust.PlaybackState get state {
    try {
      return rust.playerState();
    } catch (_) {
      return rust.PlaybackState.stopped;
    }
  }

  @override
  Future<void> play(String path, {double replayGainDb = 0}) =>
      rust.playerPlay(path: path, replayGainDb: replayGainDb);

  @override
  Future<void> preload(
    String path, {
    double replayGainDb = 0,
    double positionSecs = 0,
  }) async {
    await rust.playerPlay(path: path, replayGainDb: replayGainDb);
    await rust.playerPause();
    if (positionSecs > 0) {
      try {
        await rust.playerSeek(positionSecs: positionSecs);
      } catch (_) {
        // 装进去了却定不到位置：留着只会让用户按播放时从 0 开始。
        // 停掉、退回 stopped，让上层走「按播放时重新加载 + seek」那条老路。
        await rust.playerStop();
        rethrow;
      }
    }
  }

  @override
  Future<double> analyzeReplayGain(String path) =>
      rust.playerAnalyzeReplayGain(path: path);

  @override
  Future<void> setReplayGain(double gainDb) =>
      rust.playerSetReplayGain(gainDb: gainDb);

  @override
  Future<void> pause() => rust.playerPause();

  @override
  Future<void> resume() => rust.playerResume();

  @override
  Future<void> stop() => rust.playerStop();

  @override
  Future<rust.PlayerProgress> now() => rust.playerNow();

  @override
  Future<void> seek(double positionSecs) =>
      rust.playerSeek(positionSecs: positionSecs);

  @override
  Future<void> setVolume(double volume) => rust.playerSetVolume(volume: volume);

  @override
  bool get isExclusive {
    try {
      return rust.playerIsExclusive();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setExclusive(bool exclusive) =>
      rust.playerSetExclusive(exclusive: exclusive);

  @override
  Future<String> outputInfo() => rust.playerOutputInfo();

  @override
  Future<List<rust.PlayerDevice>> devices() => rust.playerDevices();

  @override
  Future<void> setDevice(int index) => rust.playerSetDevice(index: index);

  @override
  int get currentDevice {
    try {
      return rust.playerCurrentDevice();
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<void> setCrossfade(double seconds) =>
      rust.playerSetCrossfade(seconds: seconds);

  @override
  Future<void> setVolumeFade(bool enabled) =>
      rust.playerSetVolumeFade(enabled: enabled);

  @override
  Future<void> setEqualizer({
    required bool enabled,
    required List<double> gains,
  }) => rust.playerSetEqualizer(enabled: enabled, gains: gains);
}

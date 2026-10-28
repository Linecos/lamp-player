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

  /// 分析 [path] 的整曲响度，返回 ReplayGain 建议增益（dB）。
  ///
  /// 标签里没有增益时现场补算（ReplayGain 2.0，全曲解码约需零点几秒）。
  Future<double> analyzeReplayGain(String path);

  /// 应用起播后补算出的 ReplayGain 增益（dB），立即作用到当前输出。
  ///
  /// 与 [play] 配套：起播不等分析（会卡住切歌），分析完成后再用这条补上。
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
  Future<void> setEqualizer({
    required bool enabled,
    required List<double> gains,
  }) => rust.playerSetEqualizer(enabled: enabled, gains: gains);
}

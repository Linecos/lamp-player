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

  Future<void> play(String path);

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<double> position();

  Future<double> duration();

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
  Future<void> play(String path) => rust.playerPlay(path: path);

  @override
  Future<void> pause() => rust.playerPause();

  @override
  Future<void> resume() => rust.playerResume();

  @override
  Future<void> stop() => rust.playerStop();

  @override
  Future<double> position() => rust.playerPosition();

  @override
  Future<double> duration() => rust.playerDuration();

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
}

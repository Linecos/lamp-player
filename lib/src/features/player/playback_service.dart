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
}

/// 走 `flutter_rust_bridge` 的真实实现。
///
/// `player.rs` 目前仍是存根，`isAvailable` 会返回 false、其余调用会抛错；
/// 界面据此降级为「只能浏览曲目」，等 M2 合并后无需改 UI。
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
}

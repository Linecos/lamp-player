import 'package:shared_preferences/shared_preferences.dart';

import '../features/player/playback_queue.dart';

/// 一次会话需要记住的东西：音量、上次播放、界面位置。
///
/// 只存轻量状态，不存曲库数据；读写失败一律回退默认值，
/// 记忆失败最多让下次启动“忘事”，不能影响播放本身。
class SessionSnapshot {
  const SessionSnapshot({
    this.volume = 1,
    this.lastVolume = 1,
    this.lastTrackPath,
    this.lastPositionSecs = 0,
    this.repeat = LoopMode.off,
    this.shuffle = false,
    this.section,
    this.railExpanded = true,
  });

  final double volume;

  /// 静音前的音量；取消静音时用它恢复，而不是直接跳到 100%
  final double lastVolume;

  final String? lastTrackPath;
  final double lastPositionSecs;
  final LoopMode repeat;
  final bool shuffle;

  /// `LibrarySection.name`；页面恢复时按名字查回枚举
  final String? section;

  final bool railExpanded;
}

abstract interface class SessionStore {
  Future<SessionSnapshot> load();

  Future<void> save(SessionSnapshot snapshot);
}

/// 基于 `shared_preferences` 的实现。
class PrefsSessionStore implements SessionStore {
  const PrefsSessionStore();

  static const String volumeKey = 'player_volume';
  static const String lastVolumeKey = 'player_last_volume';
  static const String lastTrackKey = 'player_last_track';
  static const String lastPositionKey = 'player_last_position';
  static const String repeatKey = 'player_repeat';
  static const String shuffleKey = 'player_shuffle';
  static const String sectionKey = 'ui_section';
  static const String railExpandedKey = 'ui_rail_expanded';

  @override
  Future<SessionSnapshot> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return SessionSnapshot(
        volume: (prefs.getDouble(volumeKey) ?? 1).clamp(0.0, 1.0),
        lastVolume: (prefs.getDouble(lastVolumeKey) ?? 1).clamp(0.0, 1.0),
        lastTrackPath: prefs.getString(lastTrackKey),
        lastPositionSecs: (prefs.getDouble(lastPositionKey) ?? 0).clamp(
          0.0,
          double.infinity,
        ),
        repeat: _parseRepeat(prefs.getString(repeatKey)),
        shuffle: prefs.getBool(shuffleKey) ?? false,
        section: prefs.getString(sectionKey),
        railExpanded: prefs.getBool(railExpandedKey) ?? true,
      );
    } catch (_) {
      return const SessionSnapshot();
    }
  }

  @override
  Future<void> save(SessionSnapshot snapshot) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(volumeKey, snapshot.volume);
      await prefs.setDouble(lastVolumeKey, snapshot.lastVolume);
      final String? path = snapshot.lastTrackPath;
      if (path == null || path.isEmpty) {
        await prefs.remove(lastTrackKey);
      } else {
        await prefs.setString(lastTrackKey, path);
      }
      await prefs.setDouble(lastPositionKey, snapshot.lastPositionSecs);
      await prefs.setString(repeatKey, snapshot.repeat.name);
      await prefs.setBool(shuffleKey, snapshot.shuffle);
      final String? section = snapshot.section;
      if (section == null || section.isEmpty) {
        await prefs.remove(sectionKey);
      } else {
        await prefs.setString(sectionKey, section);
      }
      await prefs.setBool(railExpandedKey, snapshot.railExpanded);
    } catch (_) {
      // 保存失败不影响当前会话
    }
  }

  static LoopMode _parseRepeat(String? name) {
    for (final LoopMode mode in LoopMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return LoopMode.off;
  }
}

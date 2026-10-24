import 'package:shared_preferences/shared_preferences.dart';

import '../features/library/library_sort.dart';
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
    this.sort = LibrarySort.library,
    this.coverBackfillAttempted = false,
    this.exclusiveOutput = false,
    this.eqEnabled = false,
    this.eqGains = const <double>[],
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

  /// 曲库列表的排序方式；重启后沿用上次选择
  final LibrarySort sort;

  /// 是否已经尝试过「升级后自动补扫封面」。
  ///
  /// 曲库结构升级后老曲目没有封面，启动时会自动重扫已添加目录一次；
  /// 无论成败都记下，避免「文件本身没有内嵌封面」的曲库每次启动都全量扫描。
  final bool coverBackfillAttempted;

  /// 是否请求 WASAPI 独占输出；设备不支持时引擎会回落到共享并说明原因
  final bool exclusiveOutput;

  /// 均衡器开关
  final bool eqEnabled;

  /// 均衡器各段增益（dB，31Hz→16kHz）；空表示还没设置过
  final List<double> eqGains;
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
  static const String exclusiveKey = 'player_exclusive_output';
  static const String eqEnabledKey = 'player_eq_enabled';
  static const String eqGainsKey = 'player_eq_gains';
  static const String sortKey = 'ui_sort';
  static const String coverBackfillAttemptedKey = 'covers_backfill_attempted';

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
        exclusiveOutput: prefs.getBool(exclusiveKey) ?? false,
        eqEnabled: prefs.getBool(eqEnabledKey) ?? false,
        eqGains: (prefs.getStringList(eqGainsKey) ?? const <String>[])
            .map((String value) => double.tryParse(value) ?? 0)
            .toList(growable: false),
        sort: _parseSort(prefs.getString(sortKey)),
        coverBackfillAttempted:
            prefs.getBool(coverBackfillAttemptedKey) ?? false,
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
      await prefs.setBool(exclusiveKey, snapshot.exclusiveOutput);
      await prefs.setBool(eqEnabledKey, snapshot.eqEnabled);
      await prefs.setStringList(
        eqGainsKey,
        snapshot.eqGains
            .map((double gain) => gain.toStringAsFixed(1))
            .toList(growable: false),
      );
      await prefs.setString(sortKey, snapshot.sort.name);
      await prefs.setBool(
        coverBackfillAttemptedKey,
        snapshot.coverBackfillAttempted,
      );
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

  static LibrarySort _parseSort(String? name) {
    for (final LibrarySort sort in LibrarySort.values) {
      if (sort.name == name) {
        return sort;
      }
    }
    return LibrarySort.library;
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../common/audio/volume_curve.dart';
import '../features/library/library_sort.dart';
import '../features/player/equalizer.dart';
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
    this.eqPresetName,
    this.eqCustomPresets = const <EqualizerPreset>[],
    this.outputDevice = -1,
    this.replayGain = false,
    this.crossfadeSeconds = 0,
    this.flowBackground = true,
    this.shortcutsJson = '',
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

  /// 当前套用的预设名；null 表示手动调的自定义曲线
  final String? eqPresetName;

  /// 用户自存的预设（内置 5 套不在此列）
  final List<EqualizerPreset> eqCustomPresets;

  /// 共享输出设备索引；`-1` 表示系统默认
  final int outputDevice;

  /// 是否按标签里的 ReplayGain 统一响度
  final bool replayGain;

  /// 换曲交叉淡变时长（秒）；0 表示关闭
  final double crossfadeSeconds;

  /// 正在播放页是否启用封面取色流光背景
  final bool flowBackground;

  /// 自定义键位的 JSON（`[encodeShortcut]` 的数组）；空串表示全用默认键位。
  ///
  /// 存原始字符串而不是 `List<ShortcutBinding>`：解析失败时调用方可以整体
  /// 回落默认值，不必让会话层认识快捷键模型。
  final String shortcutsJson;
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
  static const String eqPresetNameKey = 'player_eq_preset';
  static const String eqCustomPresetsKey = 'player_eq_custom_presets';
  static const String outputDeviceKey = 'player_output_device';
  static const String replayGainKey = 'player_replay_gain';
  static const String crossfadeKey = 'player_crossfade_seconds';
  static const String sortKey = 'ui_sort';
  static const String flowBackgroundKey = 'ui_flow_background';
  static const String coverBackfillAttemptedKey = 'covers_backfill_attempted';
  static const String shortcutsKey = 'player_shortcuts';
  static const String volumeCurveVersionKey = 'volume_curve_version';

  /// 当前音量曲线版本。
  ///
  /// 1（缺省）= 滑块值直接当振幅用；2 = 三次曲线（[volumeToAmplitude]）。
  /// 曲线一换，同一个滑块值听起来会安静很多（0.5 从 -6 dB 掉到 -18 dB），
  /// 所以老存档要按等响度搬过来。
  static const int volumeCurveVersion = 2;

  @override
  Future<SessionSnapshot> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      double volume = (prefs.getDouble(volumeKey) ?? 1).clamp(0.0, 1.0);
      double lastVolume = (prefs.getDouble(lastVolumeKey) ?? 1).clamp(0.0, 1.0);
      if ((prefs.getInt(volumeCurveVersionKey) ?? 1) < volumeCurveVersion) {
        // 旧存档的滑块值其实是振幅：反解出等响度的新滑块值（立方根）。
        // 迁移后立刻落版本号，避免每次启动都再搬一次
        volume = amplitudeToVolume(volume);
        lastVolume = amplitudeToVolume(lastVolume);
        await prefs.setInt(volumeCurveVersionKey, volumeCurveVersion);
        await prefs.setDouble(volumeKey, volume);
        await prefs.setDouble(lastVolumeKey, lastVolume);
      }
      return SessionSnapshot(
        volume: volume,
        lastVolume: lastVolume,
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
        eqPresetName: prefs.getString(eqPresetNameKey),
        eqCustomPresets:
            (prefs.getStringList(eqCustomPresetsKey) ?? const <String>[])
                .map((String raw) => EqualizerPreset.fromJson(_tryDecode(raw)))
                .whereType<EqualizerPreset>()
                .toList(growable: false),
        outputDevice: prefs.getInt(outputDeviceKey) ?? -1,
        replayGain: prefs.getBool(replayGainKey) ?? false,
        crossfadeSeconds: (prefs.getDouble(crossfadeKey) ?? 0).clamp(0.0, 12.0),
        sort: _parseSort(prefs.getString(sortKey)),
        coverBackfillAttempted:
            prefs.getBool(coverBackfillAttemptedKey) ?? false,
        flowBackground: prefs.getBool(flowBackgroundKey) ?? true,
        shortcutsJson: prefs.getString(shortcutsKey) ?? '',
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
      // 记下曲线版本：以后换算法时才知道要不要迁移这一份存档
      await prefs.setInt(volumeCurveVersionKey, volumeCurveVersion);
      final String? path = snapshot.lastTrackPath;
      if (path == null || path.isEmpty) {
        await prefs.remove(lastTrackKey);
      } else {
        await prefs.setString(lastTrackKey, path);
      }
      await prefs.setDouble(lastPositionKey, snapshot.lastPositionSecs);
      await prefs.setBool(flowBackgroundKey, snapshot.flowBackground);
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
      final String? presetName = snapshot.eqPresetName;
      if (presetName == null || presetName.isEmpty) {
        await prefs.remove(eqPresetNameKey);
      } else {
        await prefs.setString(eqPresetNameKey, presetName);
      }
      await prefs.setStringList(
        eqCustomPresetsKey,
        snapshot.eqCustomPresets
            .map((EqualizerPreset preset) => jsonEncode(preset.toJson()))
            .toList(growable: false),
      );
      await prefs.setInt(outputDeviceKey, snapshot.outputDevice);
      await prefs.setBool(replayGainKey, snapshot.replayGain);
      await prefs.setDouble(crossfadeKey, snapshot.crossfadeSeconds);
      await prefs.setString(sortKey, snapshot.sort.name);
      await prefs.setBool(
        coverBackfillAttemptedKey,
        snapshot.coverBackfillAttempted,
      );
      if (snapshot.shortcutsJson.isEmpty) {
        await prefs.remove(shortcutsKey);
      } else {
        await prefs.setString(shortcutsKey, snapshot.shortcutsJson);
      }
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

  /// 单条预设是一个 JSON 字符串；解析失败就丢掉这一条，不影响其余预设
  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}

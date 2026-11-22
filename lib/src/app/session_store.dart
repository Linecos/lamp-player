import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../common/audio/replay_gain.dart';
import '../common/audio/volume_curve.dart';
import '../common/text/lyric_font.dart';
import '../features/library/library_sort.dart';
import '../features/player/equalizer.dart';
import '../features/player/lyric_alignment.dart';
import '../features/player/lyric_source.dart';
import '../features/player/playback_queue.dart';
import 'update_check.dart';

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
    this.writeLastTrack = true,
    this.repeat = LoopMode.off,
    this.shuffle = false,
    this.queuePaths,
    this.queueIndex = -1,
    this.section,
    this.railExpanded = true,
    this.sort = LibrarySort.defaultSort,
    this.sortAscending = true,
    this.detailSort = LibrarySort.title,
    this.detailAscending = true,
    this.manualSort,
    this.manualAscending = true,
    this.favoriteOrder = const <String>[],
    this.coverBackfillAttempted = false,
    this.exclusiveOutput = false,
    this.eqEnabled = false,
    this.eqGains = const <double>[],
    this.eqPresetName,
    this.eqCustomPresets = const <EqualizerPreset>[],
    this.outputDevice = -1,
    this.replayGain = false,
    this.replayGainReference = replayGainDefaultReference,
    this.replayGainTruePeak = false,
    this.crossfadeSeconds = 0,
    this.volumeFade = true,
    this.flowBackground = true,
    this.circularCovers = false,
    this.shortcutsJson = '',
    this.desktopLyrics = false,
    this.desktopLyricFontSize = PrefsSessionStore.desktopLyricFontSizeDefault,
    this.lyricFontFamily = '',
    this.desktopLyricLocked = false,
    this.desktopLyricX,
    this.desktopLyricY,
    this.lyricAlignment = LyricAlignment.center,
    this.showTranslation = true,
    this.lyricBlur = true,
    this.lyricSpring = true,
    this.lyricSourceOrder = const <String>['sidecar', 'embedded'],
    this.immersive = false,
    this.autoUpdateCheck = false,
    this.updateCheckPeriod = UpdateCheckPeriod.daily,
    this.lastUpdateCheckAt,
  });

  final double volume;

  /// 静音前的音量；取消静音时用它恢复，而不是直接跳到 100%
  final double lastVolume;

  final String? lastTrackPath;
  final double lastPositionSecs;

  /// 这次保存要不要写「上次曲目 / 进度」。
  ///
  /// 启动时曲库还没读完，`_currentTrack` 还是 null；这时候保存（退出、点排序）
  /// 会把上一次的曲目与进度冲成空。这类保存只写设置，不碰这两项。
  final bool writeLastTrack;
  final LoopMode repeat;
  final bool shuffle;

  /// 播放队列的曲目路径（按队列顺序）；`null` 表示这次保存不碰存档里的队列。
  ///
  /// 队列结构没变时传 `null`：几千首的路径串每次切歌都重写一遍没意义，
  /// 而 [queueIndex] 每次都写，足以记住放到第几首。
  final List<String>? queuePaths;

  /// 队列当前下标；空队列为 -1。`null` 表示这次保存不碰存档里的下标。
  final int? queueIndex;

  /// `LibrarySection.name`；页面恢复时按名字查回枚举
  final String? section;

  final bool railExpanded;

  /// 曲库列表的排序方式；重启后沿用上次选择
  final LibrarySort sort;

  /// 排序方向：true = 升序
  final bool sortAscending;

  /// 专辑 / 艺术家详情的排序方式：默认标题 A→Z
  final LibrarySort detailSort;

  /// 上面那种排序的方向：true = 升序
  final bool detailAscending;

  /// 歌单详情 / 收藏的排序方式；`null` = 自定义（手动拖出来的顺序）
  final LibrarySort? manualSort;

  /// 上面那种排序的方向：true = 升序
  final bool manualAscending;

  /// 收藏的自定义顺序（路径列表）；空 = 还没拖过，按收藏先后
  final List<String> favoriteOrder;

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

  /// ReplayGain 的参考响度（LUFS）：-23 / -18 / -14，默认 -18
  final double replayGainReference;

  /// ReplayGain 的峰值类型：true = 真峰值，false = 采样峰值（默认）
  final bool replayGainTruePeak;

  /// 换曲交叉淡变时长（秒）；0 表示关闭
  final double crossfadeSeconds;

  /// 音量过渡：暂停 / 停止淡出，起播与定位后淡入（默认开）
  final bool volumeFade;

  /// 桌面歌词窗口是否打开
  final bool desktopLyrics;

  /// 桌面歌词字号（96 DPI 逻辑像素）；Rust 侧同样夹在 16–56
  final int desktopLyricFontSize;

  /// 歌词字体族名（系统字体）；空串 = 跟随界面字体
  ///
  /// 两处歌词共用：主界面歌词页作为 `TextStyle.fontFamily`，桌面歌词推给
  /// Rust 的 GDI+ 侧。只认系统已安装的字体，取不到时那边会自动降级。
  final String lyricFontFamily;

  /// 桌面歌词是否锁定（锁定 = 鼠标穿透）
  final bool desktopLyricLocked;

  /// 桌面歌词窗口上次的屏幕坐标；从没显示过时是 null
  final int? desktopLyricX;
  final int? desktopLyricY;

  /// 正在播放页歌词的水平对齐方式
  final LyricAlignment lyricAlignment;

  /// 正在播放页是否显示译文 / 罗马音
  final bool showTranslation;

  /// 歌词远处的行是否糊开（默认开）。
  ///
  /// 关掉后只留透明度层次：不再逐行跑一遍离屏模糊，观感更「干脆」，
  /// 低配机器也能省下每帧的光栅。
  final bool lyricBlur;

  /// 换行时整列是否弹簧地跟到新行（默认开）。关掉直接切到新行。
  final bool lyricSpring;

  /// 歌词来源的优先级，存来源 id（见 `LyricSource`）；排在前面先读。
  ///
  /// 只存 id 而不是枚举：会话层不必认识播放器的来源模型，顺序的合法化
  /// （补缺、丢垃圾）由 [lyricSourceOrderFromIds] 在读取时统一做。
  final List<String> lyricSourceOrder;

  /// 正在播放页是否停在沉浸模式（只留封面 / 歌名 / 歌词与三个控制键）。
  ///
  /// 这个状态属于「页面退出重进、重启之后还该记得」的观感偏好，跟译文开关
  /// 一个待遇；不落盘的话每次重进播放页都会退回带完整控件的普通布局。
  final bool immersive;

  /// 正在播放页是否启用封面取色流光背景
  final bool flowBackground;

  /// 封面是否显示成圆形（默认关）
  final bool circularCovers;

  /// 自定义键位的 JSON（`[encodeShortcut]` 的数组）；空串表示全用默认键位。
  ///
  /// 存原始字符串而不是 `List<ShortcutBinding>`：解析失败时调用方可以整体
  /// 回落默认值，不必让会话层认识快捷键模型。
  final String shortcutsJson;

  /// 是否在启动时自动检查新版本（默认关：不主动联网）
  final bool autoUpdateCheck;

  /// 自动检查的间隔；「每次启动」也存这里
  final UpdateCheckPeriod updateCheckPeriod;

  /// 上次成功检查更新的时间；null 表示从没查过
  final DateTime? lastUpdateCheckAt;
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
  static const String queuePathsKey = 'player_queue_paths';
  static const String queueIndexKey = 'player_queue_index';
  static const String sectionKey = 'ui_section';
  static const String railExpandedKey = 'ui_rail_expanded';
  static const String exclusiveKey = 'player_exclusive_output';
  static const String eqEnabledKey = 'player_eq_enabled';
  static const String eqGainsKey = 'player_eq_gains';
  static const String eqPresetNameKey = 'player_eq_preset';
  static const String eqCustomPresetsKey = 'player_eq_custom_presets';
  static const String outputDeviceKey = 'player_output_device';
  static const String replayGainKey = 'player_replay_gain';
  static const String replayGainReferenceKey = 'player_replay_gain_reference';

  /// ReplayGain 峰值类型：true = 真峰值
  static const String replayGainTruePeakKey = 'player_replay_gain_true_peak';
  static const String crossfadeKey = 'player_crossfade_seconds';

  /// 音量过渡：暂停 / 停止淡出，起播与定位后淡入
  static const String volumeFadeKey = 'player_volume_fade';
  static const String desktopLyricsKey = 'ui_desktop_lyrics';
  static const String desktopLyricFontSizeKey = 'ui_desktop_lyric_font';
  static const String lyricFontFamilyKey = 'ui_lyric_font';
  static const String desktopLyricLockedKey = 'ui_desktop_lyric_locked';
  static const String desktopLyricXKey = 'ui_desktop_lyric_x';
  static const String desktopLyricYKey = 'ui_desktop_lyric_y';
  static const String lyricAlignmentKey = 'ui_lyric_alignment';
  static const String showTranslationKey = 'ui_lyric_translation';

  /// 歌词远处行模糊 / 换行时的弹簧跟随
  static const String lyricBlurKey = 'ui_lyric_blur';
  static const String lyricSpringKey = 'ui_lyric_spring';

  /// 歌词来源优先级（来源 id 列表，排前面的先读）
  static const String lyricSourceOrderKey = 'ui_lyric_source_order';
  static const String immersiveKey = 'ui_now_playing_immersive';

  /// 桌面歌词字号的默认值与范围（与 `rust/src/desktop_lyrics.rs` 保持一致）
  static const int desktopLyricFontSizeDefault = 27;
  static const int desktopLyricFontSizeMin = 16;
  static const int desktopLyricFontSizeMax = 56;
  static const int desktopLyricFontSizeStep = 3;
  static const String sortKey = 'ui_sort';
  static const String sortAscendingKey = 'ui_sort_ascending';
  static const String detailSortKey = 'ui_detail_sort';
  static const String detailAscendingKey = 'ui_detail_ascending';
  static const String manualSortKey = 'ui_manual_sort';
  static const String manualAscendingKey = 'ui_manual_ascending';
  static const String favoriteOrderKey = 'ui_favorite_order';
  static const String flowBackgroundKey = 'ui_flow_background';
  static const String circularCoversKey = 'ui_circular_covers';
  static const String coverBackfillAttemptedKey = 'covers_backfill_attempted';
  static const String shortcutsKey = 'player_shortcuts';
  static const String volumeCurveVersionKey = 'volume_curve_version';

  /// 更新检查：开关、频率、上次成功检查的时间（epoch 毫秒）
  static const String autoUpdateCheckKey = 'update_auto_check';
  static const String updateCheckPeriodKey = 'update_check_period';
  static const String lastUpdateCheckKey = 'update_last_check_at';

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
        queuePaths: prefs.getStringList(queuePathsKey),
        queueIndex: prefs.getInt(queueIndexKey) ?? -1,
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
        replayGainReference: parseReplayGainReference(
          prefs.getDouble(replayGainReferenceKey),
        ),
        replayGainTruePeak: prefs.getBool(replayGainTruePeakKey) ?? false,
        crossfadeSeconds: (prefs.getDouble(crossfadeKey) ?? 0).clamp(0.0, 12.0),
        volumeFade: prefs.getBool(volumeFadeKey) ?? true,
        desktopLyrics: prefs.getBool(desktopLyricsKey) ?? false,
        desktopLyricFontSize:
            (prefs.getInt(desktopLyricFontSizeKey) ??
                    desktopLyricFontSizeDefault)
                .clamp(desktopLyricFontSizeMin, desktopLyricFontSizeMax),
        lyricFontFamily: normalizeLyricFontFamily(
          prefs.getString(lyricFontFamilyKey) ?? '',
        ),
        desktopLyricLocked: prefs.getBool(desktopLyricLockedKey) ?? false,
        desktopLyricX: prefs.getInt(desktopLyricXKey),
        desktopLyricY: prefs.getInt(desktopLyricYKey),
        lyricAlignment: LyricAlignment.parse(
          prefs.getString(lyricAlignmentKey),
        ),
        showTranslation: prefs.getBool(showTranslationKey) ?? true,
        lyricBlur: prefs.getBool(lyricBlurKey) ?? true,
        lyricSpring: prefs.getBool(lyricSpringKey) ?? true,
        lyricSourceOrder: lyricSourceOrderIds(
          lyricSourceOrderFromIds(prefs.getStringList(lyricSourceOrderKey)),
        ),
        immersive: prefs.getBool(immersiveKey) ?? false,
        sort: _parseSort(prefs.getString(sortKey)),
        sortAscending: prefs.getBool(sortAscendingKey) ?? true,
        detailSort: _parseSort(prefs.getString(detailSortKey)),
        detailAscending: prefs.getBool(detailAscendingKey) ?? true,
        manualSort: _parseListSort(prefs.getString(manualSortKey)),
        manualAscending: prefs.getBool(manualAscendingKey) ?? true,
        favoriteOrder: _parseStringList(prefs.getString(favoriteOrderKey)),
        coverBackfillAttempted:
            prefs.getBool(coverBackfillAttemptedKey) ?? false,
        flowBackground: prefs.getBool(flowBackgroundKey) ?? true,
        circularCovers: prefs.getBool(circularCoversKey) ?? false,
        shortcutsJson: prefs.getString(shortcutsKey) ?? '',
        autoUpdateCheck: prefs.getBool(autoUpdateCheckKey) ?? false,
        updateCheckPeriod: UpdateCheckPeriod.parse(
          prefs.getString(updateCheckPeriodKey),
        ),
        lastUpdateCheckAt: _parseTimestamp(prefs.getInt(lastUpdateCheckKey)),
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
      if (snapshot.writeLastTrack) {
        final String? path = snapshot.lastTrackPath;
        if (path == null || path.isEmpty) {
          await prefs.remove(lastTrackKey);
        } else {
          await prefs.setString(lastTrackKey, path);
        }
        await prefs.setDouble(lastPositionKey, snapshot.lastPositionSecs);
      }
      await prefs.setBool(flowBackgroundKey, snapshot.flowBackground);
      await prefs.setBool(circularCoversKey, snapshot.circularCovers);
      await prefs.setString(repeatKey, snapshot.repeat.name);
      await prefs.setBool(shuffleKey, snapshot.shuffle);
      // 队列路径只在结构变化时才带过来，见 [SessionSnapshot.queuePaths]
      final List<String>? queuePaths = snapshot.queuePaths;
      if (queuePaths != null) {
        await prefs.setStringList(queuePathsKey, queuePaths);
      }
      final int? queueIndex = snapshot.queueIndex;
      if (queueIndex != null) {
        await prefs.setInt(queueIndexKey, queueIndex);
      }
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
      await prefs.setDouble(
        replayGainReferenceKey,
        snapshot.replayGainReference,
      );
      await prefs.setBool(replayGainTruePeakKey, snapshot.replayGainTruePeak);
      await prefs.setDouble(crossfadeKey, snapshot.crossfadeSeconds);
      await prefs.setBool(volumeFadeKey, snapshot.volumeFade);
      await prefs.setBool(desktopLyricsKey, snapshot.desktopLyrics);
      await prefs.setInt(
        desktopLyricFontSizeKey,
        snapshot.desktopLyricFontSize.clamp(
          desktopLyricFontSizeMin,
          desktopLyricFontSizeMax,
        ),
      );
      await prefs.setString(lyricFontFamilyKey, snapshot.lyricFontFamily);
      await prefs.setBool(desktopLyricLockedKey, snapshot.desktopLyricLocked);
      final int? x = snapshot.desktopLyricX;
      final int? y = snapshot.desktopLyricY;
      if (x == null || y == null) {
        await prefs.remove(desktopLyricXKey);
        await prefs.remove(desktopLyricYKey);
      } else {
        await prefs.setInt(desktopLyricXKey, x);
        await prefs.setInt(desktopLyricYKey, y);
      }
      await prefs.setString(lyricAlignmentKey, snapshot.lyricAlignment.name);
      await prefs.setBool(showTranslationKey, snapshot.showTranslation);
      await prefs.setBool(lyricBlurKey, snapshot.lyricBlur);
      await prefs.setBool(lyricSpringKey, snapshot.lyricSpring);
      await prefs.setStringList(lyricSourceOrderKey, snapshot.lyricSourceOrder);
      await prefs.setBool(immersiveKey, snapshot.immersive);
      await prefs.setString(sortKey, snapshot.sort.name);
      await prefs.setBool(sortAscendingKey, snapshot.sortAscending);
      await prefs.setString(detailSortKey, snapshot.detailSort.name);
      await prefs.setBool(detailAscendingKey, snapshot.detailAscending);
      await prefs.setString(manualSortKey, snapshot.manualSort?.name ?? '');
      await prefs.setBool(manualAscendingKey, snapshot.manualAscending);
      await prefs.setString(
        favoriteOrderKey,
        jsonEncode(snapshot.favoriteOrder),
      );
      await prefs.setBool(
        coverBackfillAttemptedKey,
        snapshot.coverBackfillAttempted,
      );
      if (snapshot.shortcutsJson.isEmpty) {
        await prefs.remove(shortcutsKey);
      } else {
        await prefs.setString(shortcutsKey, snapshot.shortcutsJson);
      }
      await prefs.setBool(autoUpdateCheckKey, snapshot.autoUpdateCheck);
      await prefs.setString(
        updateCheckPeriodKey,
        snapshot.updateCheckPeriod.name,
      );
      final DateTime? lastUpdateCheckAt = snapshot.lastUpdateCheckAt;
      if (lastUpdateCheckAt == null) {
        await prefs.remove(lastUpdateCheckKey);
      } else {
        await prefs.setInt(
          lastUpdateCheckKey,
          lastUpdateCheckAt.millisecondsSinceEpoch,
        );
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

  /// 收藏自定义顺序：JSON 数组；解析失败当作没设置过
  static List<String> _parseStringList(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String>[];
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } on FormatException {
      // 坏数据：当作没设置过
    }
    return const <String>[];
  }

  /// 歌单 / 收藏的排序：空串与未知值都当作「自定义」（null）
  static LibrarySort? _parseListSort(String? name) {
    for (final LibrarySort sort in LibrarySort.values) {
      if (sort.name == name) {
        return sort;
      }
    }
    return null;
  }

  static LibrarySort _parseSort(String? name) {
    for (final LibrarySort sort in LibrarySort.values) {
      if (sort.name == name) {
        return sort;
      }
    }
    return LibrarySort.defaultSort;
  }

  /// 单条预设是一个 JSON 字符串；解析失败就丢掉这一条，不影响其余预设
  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// epoch 毫秒 → 时间；越界或坏值当作从没查过（[DateTime.fromMillisecondsSinceEpoch]
  /// 对极端值会抛，存档被改坏时不该让整个会话恢复失败）
  static DateTime? _parseTimestamp(int? millis) {
    if (millis == null || millis <= 0) {
      return null;
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } on ArgumentError {
      return null;
    }
  }
}

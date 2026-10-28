import 'dart:async';
import 'dart:io' show File, Platform, Process;
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:path/path.dart' as p;

import '../../app/session_store.dart';
import '../../app/title_bar.dart';
import '../../app/window_controls.dart';
import '../../app/tray_controller.dart';
import '../../common/common.dart';
import '../../common/text/pinyin_key.dart';
import '../../rust/api/collections.dart' as collections;
import '../../rust/api/model.dart';
import '../../rust/api/player.dart' as rust;
import '../../rust/api/scan.dart' as scan;
import '../player/playback_mode.dart';
import '../player/playback_queue.dart';
import '../player/playback_service.dart';
import '../player/player_bar.dart';
import '../../app/app_lifecycle.dart';
import '../player/equalizer.dart';
import '../player/now_playing_page.dart';
import '../player/queue_dialog.dart';
import '../player/shortcuts.dart';
import '../settings/shortcuts_page.dart';
import '../player/smtc_bridge.dart';
import '../player/spectrum_controller.dart';
import '../settings/equalizer_page.dart';
import '../settings/music_folder_store.dart';
import '../settings/settings_view.dart';
import 'drop_import.dart';
import 'library_repository.dart';
import 'library_sort.dart';
import 'music_tag.dart';
import 'playlist_io.dart';
import 'widgets/collection_grids.dart';
import 'widgets/library_rail.dart';
import 'widgets/playlist_dialogs.dart';
import 'widgets/playlist_grid.dart';
import 'widgets/track_list_view.dart';

part 'sections/output_section.dart';
part 'sections/data_section.dart';
part 'sections/directory_section.dart';
part 'sections/playback_section.dart';
part 'sections/search_section.dart';
part 'sections/selection_section.dart';
part 'sections/settings_section.dart';
part 'sections/history_section.dart';
part 'sections/favorites_section.dart';
part 'sections/playlists_section.dart';
part 'sections/music_section.dart';
part 'sections/artists_section.dart';
part 'sections/albums_section.dart';
part 'sections/filter_section.dart';

/// 目录选择器，测试可注入假实现。
typedef DirectoryPicker = Future<String?> Function();

/// 主界面：侧边导航 + 顶部搜索 + 曲库 / 艺术家 / 专辑 + 底部播放条。
///
/// 状态都收敛在本页（`StatefulWidget` + `setState`），不引入第三方状态管理；
/// 数据与播放通过构造参数注入，`test/` 下可以完全脱离 Rust 运行。
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.repository,
    this.playbackService,
    this.directoryPicker,
    this.musicFolderStore,
    this.sessionStore,
    this.appLifecycle,
    this.windowControls,
    this.trayController,
    this.lyricsLoader,
    this.spectrum,
    this.musicTagLauncher,
    this.shortcuts = kDefaultShortcuts,
  });

  /// 曲库数据源；不传则走 Rust。
  final LibraryRepository? repository;

  /// 播放能力；不传则走 Rust / BASS。
  final PlaybackService? playbackService;

  /// 选择音乐目录；不传则打开系统目录选择框。
  final DirectoryPicker? directoryPicker;

  /// 已添加目录的持久化；不传则用 shared_preferences。
  final MusicFolderStore? musicFolderStore;

  /// 外部标签编辑器 MusicTag；不传则自动查找 / 让用户选 MusicTag.exe
  final MusicTagLauncher? musicTagLauncher;

  /// 播放 / 界面快捷键表；默认 [kDefaultShortcuts]。
  ///
  /// 这是给「自定义键位」留的入口：实现 `ShortcutStore` 读出用户配置后，
  /// 在这里传进来即可——曲库页与正在播放页都从这里取绑定，不用改页面代码。
  final List<ShortcutBinding> shortcuts;

  /// 音量 / 上次播放 / 分区等会话状态；不传则用 shared_preferences。
  final SessionStore? sessionStore;

  /// 应用级行为（关闭到托盘）；不传时设置页里的开关禁用
  final AppLifecycle? appLifecycle;

  /// 窗口控制；不传时走真实的 window_manager
  final WindowControls? windowControls;

  /// 托盘：把播放控制绑上去，关窗后在托盘菜单里也能暂停 / 切歌
  final TrayController? trayController;

  /// 播放条左侧的歌词来源；不传则播放条不显示歌词（测试默认走这条）
  final TrackLyricsLoader? lyricsLoader;

  /// 频谱数据源；不传则不画频谱，也不会去订阅引擎流（测试默认走这条）
  final ValueListenable<List<double>>? spectrum;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  static const Duration _searchDebounce = Duration(milliseconds: 300);
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// 听歌时长攒够这么多秒再写库：每拍写一次会把 SQLite 打满。
  static const double _playTimeFlushSeconds = 15;

  /// 悬浮播放岛给内容预留的高度：岛高 88 + 上方 8 间距。
  /// 内容区底部留这么多，滚到底时最后一行正好停在岛上方。
  static const double _playerBarReservedHeight = 96;

  /// 音量滑块的合并窗口：拖动时最多每 80ms 发一次 FFI。
  static const Duration _volumeThrottle = Duration(milliseconds: 80);

  /// 位置轮询连续失败多少次后停止（单次瞬时异常不应冻结进度条）。
  static const int _maxPollFailures = 3;

  /// 自然播完后连续多少首播放失败就停止自动跳转（避免整库损坏时空转）。
  static const int _maxAutoSkips = 5;

  late final LibraryRepository _repository =
      widget.repository ?? const RustLibraryRepository();
  late final PlaybackService _playback =
      widget.playbackService ?? const RustPlaybackService();
  late final WindowControls _windowControls =
      widget.windowControls ?? const WindowManagerControls();
  late final MusicFolderStore _folderStore =
      widget.musicFolderStore ?? const PrefsMusicFolderStore();
  late final SessionStore _sessionStore =
      widget.sessionStore ?? const PrefsSessionStore();
  late final MusicTagLauncher _musicTag =
      widget.musicTagLauncher ?? MusicTagLauncher();

  /// 系统媒体控制（媒体键 / 任务栏缩略图 / 音量浮层）
  late final SmtcBridge _media = SmtcBridge(
    onPlay: _mediaPlay,
    onPause: _mediaPause,
    onNext: _next,
    onPrevious: _previous,
    onStop: _mediaStop,
  );

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 播放队列：曲目顺序、循环 / 随机、上一首历史都在里面
  final PlaybackQueue _queue = PlaybackQueue();

  Timer? _debounce;
  Timer? _positionTimer;
  Timer? _volumeTimer;
  Timer? _saveTimer;
  Timer? _sessionTimer;
  double? _pendingVolume;
  int _pollFailures = 0;
  int _searchToken = 0;
  bool _ticking = false;
  bool _handlingEnd = false;

  /// 启动时恢复的位置：第一次按播放才真正 seek 到该处
  double? _pendingResumePosition;

  LibrarySection _section = LibrarySection.music;

  /// 只驱动侧栏高亮的通知器：点导航时先只改它，整页不重建
  final ValueNotifier<LibrarySection> _sectionNotifier =
      ValueNotifier<LibrarySection>(LibrarySection.music);

  /// 只驱动侧栏展开 / 收起的通知器：折叠时整页不重建，
  /// 内容区宽度交给 Row 的重新布局，不必走一遍 build
  final ValueNotifier<bool> _railNotifier = ValueNotifier<bool>(true);

  /// 内容区实际显示的分区。
  ///
  /// 切分区时先只改 [_section]（侧栏高亮立即响应点击），下一帧再更新这个字段
  /// 并换内容：新分区首次构建较重（列表 / 网格 / 图片解码），同步做会把点击的
  /// 水波纹动画压住，用户看到的就是「点了卡一下」。
  late LibrarySection _displayedSection = _section;

  /// 分区快照：访问过的分区留在这里，切回来直接复用，不必重建整棵子树。
  final Map<LibrarySection, Widget> _sections = <LibrarySection, Widget>{};
  final Map<LibrarySection, int> _sectionVersions = <LibrarySection, int>{};

  /// 任何影响分区内容的状态变化都会 +1（统一走 [_update]）
  int _stateVersion = 0;

  /// 刚切换过来的分区：数据虽已变化，但这一帧先显示旧快照，
  /// 等淡入结束再补，避免重建正卡在动画中间
  LibrarySection? _justSwitched;
  Timer? _sectionRefreshTimer;

  /// 切换分区时的淡入：只对新内容做不透明度合成，成本接近零
  late final AnimationController _sectionFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 130),
    value: 1,
  );
  bool _railExpanded = true;
  LibrarySort _sort = LibrarySort.library;

  List<Track> _tracks = const <Track>[];
  List<Track>? _results;
  String _query = '';
  bool _loading = true;
  bool _searching = false;

  /// 命中数超过单次上限（500）时为 true，避免把「只显示前 500 首」说成正好 500 首
  bool _searchTruncated = false;
  bool _scanning = false;
  bool _backfillingCovers = false;
  bool _coverBackfillAttempted = false;
  String? _lastScanFolder;
  List<String> _folders = const <String>[];
  scan.ScanReport? _scanReport;
  Object? _scanError;
  Object? _error;
  Object? _searchError;

  String? _selectedArtist;
  String? _selectedAlbumKey;

  Set<String> _favoritePaths = <String>{};
  bool _favoritesLoading = false;
  Object? _favoritesError;
  List<Track> _favoriteTracks = const <Track>[];

  List<Track> _historyTracks = const <Track>[];
  bool _historyLoading = false;
  Object? _historyError;

  /* -------------------------------------------------------------- 多选 */

  /// 多选模式：进入后行首出现复选框，点击行只改选择、不播放
  bool _selectionMode = false;
  Set<String> _selectedPaths = <String>{};

  /// Shift 范围选择的起点
  String? _selectionAnchorPath;

  /* ------------------------------------------------------ 缺失文件清理 */

  bool _pruningMissing = false;
  int? _prunedMissingCount;
  Object? _pruneMissingError;

  List<Playlist> _playlists = const <Playlist>[];
  bool _playlistsLoading = false;
  Object? _playlistsError;
  int? _selectedPlaylistId;
  List<Track> _playlistTracks = const <Track>[];

  /// 正在把拖拽结果写回数据库：期间先摘掉把手，避免二次拖动打架
  bool _playlistReordering = false;

  /// 频谱流当前是否已订阅：只在放歌时开，暂停就关
  bool _spectrumActive = false;
  bool _playlistTracksLoading = false;
  Object? _playlistTracksError;

  Track? _currentTrack;
  bool _isPlaying = false;
  bool _isAvailable = false;
  bool _seeking = false;
  double _position = 0;
  double _duration = 0;

  /// 听歌时长累计：当前曲目 + 本地日期 + 尚未写库的秒数（含小数）。
  String? _playSessionPath;
  int _playSessionDay = 0;
  double _playSessionSeconds = 0;

  /// 上一次轮询到的位置，用来算「这一拍真正听了多久」。
  double _lastPollPosition = 0;

  /// 音量（滑块语义 0..1）。
  ///
  /// 用 notifier 而不是普通字段：拖动滑块时只重建播放条的音量控件，
  /// 不推进 `_stateVersion`——否则当前分区（可能是一整页封面网格）会被重建。
  final ValueNotifier<double> _volumeNotifier = ValueNotifier<double>(1);
  double get _volume => _volumeNotifier.value;
  set _volume(double value) => _volumeNotifier.value = value;

  double _lastVolume = 1;
  bool _engineNoticeShown = false;

  /// 是否请求 WASAPI 独占输出（偏好；设备不支持时引擎会回落共享）
  bool _exclusive = false;

  /// 拼音键缓存（path → 全拼|首字母）。
  ///
  /// 由后台分帧预热（一次 200 条）：万级曲库同步构建会把 UI 卡住几百毫秒。
  /// 曲库整体换新（扫描 / 重扫）时必须清空——标签可能已经变了。
  final Map<String, String> _pinyinKeys = <String, String>{};

  /// 已预热到第几条；小于 `_tracks.length` 说明缓存还没建完
  int _pinyinWarmedCount = 0;
  bool _pinyinWarming = false;

  /// 专辑 / 艺术家 / 歌单名称的拼音键，供分区内过滤使用
  final Map<String, String> _namePinyinKeys = <String, String>{};

  /// 共享输出设备索引（`-1` = 系统默认）与可用设备列表
  int _outputDevice = -1;
  List<rust.PlayerDevice> _devices = const <rust.PlayerDevice>[];

  /// 设备列表与当前选择的通知器：正在播放页是独立路由，
  /// 父页 setState 到不了它，只能靠通知器把变化推过去
  final ValueNotifier<List<rust.PlayerDevice>> _devicesNotifier =
      ValueNotifier<List<rust.PlayerDevice>>(const <rust.PlayerDevice>[]);
  final ValueNotifier<int> _outputDeviceNotifier = ValueNotifier<int>(-1);

  /// 设置页打开时的设备轮询：热插拔系统不会主动通知
  Timer? _deviceTimer;

  /// 正在播放页打开时的设备轮询：与设置页各用一支，互不取消
  Timer? _nowPlayingDeviceTimer;

  /// 是否按标签里的 ReplayGain 统一响度
  bool _replayGain = false;

  /// 当前生效的键位表；会话里有自定义配置时覆盖 [LibraryPage.shortcuts]
  late List<ShortcutBinding> _shortcuts = widget.shortcuts;

  /// 标签缺增益时现场分析的结果缓存（路径 → dB），本次会话内复用
  final Map<String, double> _autoGains = <String, double>{};

  /// 换曲交叉淡变时长（秒）；0 关闭
  double _crossfadeSeconds = 0;

  /// 正在播放页是否启用封面取色流光；关闭后只保留静态取色背景
  bool _flowBackground = true;

  /// 均衡器开关与 10 段增益（dB，31Hz→16kHz）
  bool _eqEnabled = false;
  List<double> _eqGains = normalizeEqGains(const <double>[]);

  /// 当前套用的预设名；null 表示手动调过
  String? _eqPresetName;

  /// 用户自存的预设（内置 5 套不在此列）
  List<EqualizerPreset> _eqCustomPresets = const <EqualizerPreset>[];
  bool _switchingOutput = false;

  /// 当前输出的实际描述，来自引擎（含回落原因）
  String _outputInfo = '';

  /// 播放进度单独放进 notifier：轮询只刷新播放条，不重建整个曲库页面。
  final ValueNotifier<_PlaybackProgress> _progress =
      ValueNotifier<_PlaybackProgress>(const _PlaybackProgress());

  /// 正在播放页的数据源：曲目、播放状态、进度
  final ValueNotifier<NowPlayingData> _nowPlaying =
      ValueNotifier<NowPlayingData>(const NowPlayingData());

  /// 是否有文件正拖在窗口上（显示导入提示）
  bool _dragging = false;

  /// 艺术家 / 专辑聚合缓存；`_tracks` 换新对象时才重算
  List<Track>? _groupedTracks;
  List<ArtistGroup>? _artistGroups;
  List<AlbumGroup>? _albumGroups;

  /// 拆到 `sections/` 的代码不能直接调 `@protected` 的 `setState`，统一走这里。
  /// 顺带推进状态版本：分区快照据此判断自己是否过期。
  void _update(VoidCallback fn) {
    setState(() {
      fn();
      _stateVersion += 1;
    });
  }

  /// 首帧画完再探测音频引擎，避免引擎线程异常时卡住启动。
  ///
  /// `Future.delayed(Duration.zero)` 不够：零延时 timer 排在 vsync 之前，
  /// 实际仍会卡住首帧。`endOfFrame` 保证第一帧已经提交渲染后再探测。
  Future<void> _probeAvailability() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }
    final bool available = _readAvailability();
    if (available != _isAvailable) {
      _update(() => _isAvailable = available);
    }
    // 探测晚于 _bootstrap：可用时把跳过的启动音频初始化补上
    if (available && !_startupAudioApplied) {
      _applyStartupAudio(_exclusive);
    }
  }

  /// 启动时的音频初始化：音量、输出偏好、均衡器。只做一次。
  bool _startupAudioApplied = false;

  void _applyStartupAudio(bool exclusive) {
    _startupAudioApplied = true;
    unawaited(_applyVolume(_volume));
    // 先按偏好切输出，再刷新描述：启动时还没有曲目，切换几乎没有代价
    unawaited(_applyOutputPreference(exclusive));
    unawaited(_applyEqualizer());
    unawaited(_applyOutputDevice());
    unawaited(_applyCrossfade());
  }

  /// Windows 路径大小写与分隔符不敏感：回车恢复上次曲目、
  /// 会话里存的是 `/` 还是 `\` 都不该导致「静默不恢复」
  static String _pathKey(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  static bool _samePath(String a, String b) => _pathKey(a) == _pathKey(b);

  /// 退出前落盘用的稳定引用（方法 tear-off 每次都是新对象，无法注销）
  /// 退出前把没写库的听歌时长补上：托盘退出时 `dispose` 不一定来得及跑。
  Future<void> _exitHook() async {
    await _saveSession();
    await _flushPlayTime();
  }

  @override
  void initState() {
    super.initState();
    // 引擎探测要 spawn 引擎线程并等就绪，音频子系统异常时会阻塞好几秒；
    // 放在首帧之后做，界面先按可用渲染，探测结果再回填
    unawaited(_probeAvailability());
    // 托盘播放控制：关窗隐藏后仍能暂停 / 切歌
    widget.trayController?.bindPlayback(
      onTogglePlay: () => unawaited(_togglePlayback()),
      onNext: () => unawaited(_next()),
      onPrevious: () => unawaited(_previous()),
    );
    unawaited(_bootstrap());
    // 系统媒体控制：失败只影响系统浮层，不影响播放
    unawaited(_media.start());
    widget.appLifecycle
      ?..addListener(_onLifecycleChanged)
      ..setBeforeExit(_exitHook);
  }

  /// 关闭到托盘的开关变化：让设置页跟着刷新
  void _onLifecycleChanged() {
    if (mounted) {
      _update(() {});
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _positionTimer?.cancel();
    _volumeTimer?.cancel();
    _saveTimer?.cancel();
    _sessionTimer?.cancel();
    _sectionRefreshTimer?.cancel();
    _deviceTimer?.cancel();
    _nowPlayingDeviceTimer?.cancel();
    _sectionFade.dispose();
    _sectionNotifier.dispose();
    _railNotifier.dispose();
    _devicesNotifier.dispose();
    _outputDeviceNotifier.dispose();
    if (_spectrumActive) {
      _spectrumActive = false;
      SpectrumController.instance.detach();
    }
    unawaited(_saveSession());
    unawaited(_flushPlayTime());
    widget.trayController?.unbindPlayback();
    widget.appLifecycle
      ?..removeListener(_onLifecycleChanged)
      ..clearBeforeExit(_exitHook);
    unawaited(_media.dispose());
    _searchFocus.dispose();
    _searchController.dispose();
    _progress.dispose();
    _nowPlaying.dispose();
    _volumeNotifier.dispose();
    super.dispose();
  }

  /// 启动顺序：并行读会话与曲库，再恢复上次播放。
  ///
  /// 曲库读完才能把上次播放的路径对回 `Track`，所以恢复曲目放在两者之后。
  /// 读会话失败只会失去“记住上次”的能力，不影响曲库展示。
  Future<void> _bootstrap() async {
    final Future<SessionSnapshot> sessionLoader = _sessionStore.load();
    final Future<void> tracksLoader = _loadTracks();
    final SessionSnapshot snapshot = await sessionLoader;
    await tracksLoader;
    if (!mounted) {
      return;
    }
    final LibrarySection section = _sectionFromName(snapshot.section);
    setState(() {
      _volume = snapshot.volume;
      // 静音退出时 volume 为 0，取消静音要回到静音前的音量而不是 100%
      _lastVolume = snapshot.lastVolume > 0
          ? snapshot.lastVolume
          : (snapshot.volume > 0 ? snapshot.volume : 1);
      _queue
        ..setRepeat(snapshot.repeat)
        ..setShuffle(snapshot.shuffle);
      // 恢复分区时三者一起就位，否则内容区还停在音乐页
      _section = section;
      _displayedSection = section;
      _sectionNotifier.value = section;
      _railExpanded = snapshot.railExpanded;
      _railNotifier.value = _railExpanded;
      _sort = snapshot.sort;
      _tracks = sortTracks(_tracks, snapshot.sort);
      _coverBackfillAttempted = snapshot.coverBackfillAttempted;
      _exclusive = snapshot.exclusiveOutput;
      _eqEnabled = snapshot.eqEnabled;
      _eqGains = normalizeEqGains(snapshot.eqGains);
      _eqPresetName = snapshot.eqPresetName;
      _eqCustomPresets = snapshot.eqCustomPresets;
      _outputDevice = snapshot.outputDevice;
      _outputDeviceNotifier.value = snapshot.outputDevice;
      _replayGain = snapshot.replayGain;
      if (snapshot.shortcutsJson.isNotEmpty) {
        _shortcuts = decodeShortcuts(snapshot.shortcutsJson);
      }
      _crossfadeSeconds = snapshot.crossfadeSeconds;
      _flowBackground = snapshot.flowBackground;
    });

    if (!mounted) {
      return;
    }
    _restoreLastTrack(snapshot);

    unawaited(_refreshFavoritePaths());
    unawaited(_loadFoldersAndMaybeBackfill());
    if (_isAvailable) {
      _applyStartupAudio(snapshot.exclusiveOutput);
    } else {
      unawaited(_refreshOutputInfo());
    }
    switch (section) {
      case LibrarySection.playlists:
        unawaited(_loadPlaylists());
      case LibrarySection.favorites:
        unawaited(_loadFavorites());
      case LibrarySection.history:
        unawaited(_loadHistory());
      default:
        break;
    }
    _sessionTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _isPlaying ? unawaited(_saveSession()) : null,
    );
  }

  void _restoreLastTrack(SessionSnapshot snapshot) {
    final String? path = snapshot.lastTrackPath;
    if (path == null || path.isEmpty) {
      return;
    }
    final int index = _tracks.indexWhere(
      (Track track) => _samePath(track.path, path),
    );
    if (index < 0) {
      return;
    }
    final Track track = _tracks[index];
    final double duration = track.durationSecs;
    final bool finished =
        duration > 0 && snapshot.lastPositionSecs >= duration - 2;
    final double position = finished
        ? 0
        : snapshot.lastPositionSecs.clamp(0.0, max(duration, 0));
    _queue.reset(_tracks, index: index);
    setState(() {
      _currentTrack = track;
      _duration = duration;
      _position = position;
      _pendingResumePosition = position > 1 ? position : null;
      _isPlaying = false;
    });
    _publishProgress();
  }

  LibrarySection _sectionFromName(String? name) {
    for (final LibrarySection section in LibrarySection.values) {
      if (section.name == name) {
        return section;
      }
    }
    return LibrarySection.music;
  }

  /// 立即写入会话状态（切歌 / 暂停 / 退出等关键时刻）。
  void _saveSessionNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    unawaited(_saveSession());
  }

  /// 合并短时间内的多次变化（例如拖动音量），避免每 80ms 写一次盘。
  void _scheduleSessionSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      _saveTimer = null;
      unawaited(_saveSession());
    });
  }

  /// 保存串行链：写盘是异步的，而 [_scheduleSessionSave]、[_saveSessionNow]、
  /// 10 秒定时器和 dispose 四个来源都会触发。不串行的话 11 个 key 的写入会交错，
  /// 可能落出「曲目是新的、位置是旧的」这种撕裂快照，重启就恢复到错的位置。
  Future<void> _saveChain = Future<void>.value();

  /// 播放命令串行链：键盘、媒体键、托盘、队列面板、自动播完都会发命令，
  /// 两个入口交错时会出现「队列被 advance 两次只播了一首」或旧曲目被重新播出。
  final _SerialChain _playChain = _SerialChain();

  /// 收藏写库串行链：快速双击会把「加收藏」和「取消收藏」两个无序 FFI 写
  /// 一起发出去，先发的后到就会让数据库终态与界面相反。
  final _SerialChain _favoriteChain = _SerialChain();

  Future<void> _saveSession() {
    final SessionSnapshot snapshot = SessionSnapshot(
      volume: _volume,
      lastVolume: _lastVolume,
      lastTrackPath: _currentTrack?.path,
      lastPositionSecs: _currentTrack == null ? 0 : _position,
      repeat: _queue.repeat,
      shuffle: _queue.shuffle,
      section: _section.name,
      railExpanded: _railExpanded,
      sort: _sort,
      coverBackfillAttempted: _coverBackfillAttempted,
      exclusiveOutput: _exclusive,
      eqEnabled: _eqEnabled,
      eqGains: _eqGains,
      eqPresetName: _eqPresetName,
      eqCustomPresets: _eqCustomPresets,
      outputDevice: _outputDevice,
      replayGain: _replayGain,
      shortcutsJson: encodeShortcuts(_shortcuts),
      crossfadeSeconds: _crossfadeSeconds,
      flowBackground: _flowBackground,
    );
    // 快照在调用时定稿，排队只影响写入时机，不会读到时才取字段。
    //
    // 单次写盘失败不能毒化整条链：链一旦变成 error future，后续 `.then` 全部跳过，
    // 之后每次会话变化都被静默丢弃，异常还会逃逸成未处理错误。所以在这里吞掉，
    // 只记日志——退出前那次保存失败也不该阻断退出。
    _saveChain = _saveChain.then((_) async {
      try {
        await _sessionStore.save(snapshot);
      } catch (error) {
        debugPrint('保存会话失败：$error');
      }
    });
    return _saveChain;
  }

  /* ---------------------------------------------------------------- 界面 */

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 放在页面根部：文本框聚焦时由 EditableText 自己消费空格与方向键，
    // 其余情况下才落到播放控制上。
    // 绑定表来自 shortcuts.dart：曲库页与正在播放页共用一份，改键只改那里。
    // 页面只负责把「动作」映射到自己能做的事上；不提供的动作不会绑定。
    final Map<ShortcutAction, VoidCallback> handlers =
        <ShortcutAction, VoidCallback>{
          ShortcutAction.togglePlay: _handleSpace,
          ShortcutAction.seekForward: () =>
              _unlessTyping(() => unawaited(_seekBy(5))),
          ShortcutAction.seekBackward: () =>
              _unlessTyping(() => unawaited(_seekBy(-5))),
          ShortcutAction.next: () => _unlessTyping(() => unawaited(_next())),
          ShortcutAction.previous: () =>
              _unlessTyping(() => unawaited(_previous())),
          ShortcutAction.volumeUp: () =>
              _unlessTyping(() => _setVolume(_volume + 0.05)),
          ShortcutAction.volumeDown: () =>
              _unlessTyping(() => _setVolume(_volume - 0.05)),
          ShortcutAction.toggleMute: _toggleMute,
          ShortcutAction.focusSearch: _focusSearch,
          ShortcutAction.mediaTogglePlay: () => unawaited(_togglePlayback()),
          ShortcutAction.mediaNext: () => unawaited(_next()),
          ShortcutAction.mediaPrevious: () => unawaited(_previous()),
        };
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        ...shortcutBindings(handlers, bindings: _shortcuts),
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
            _handleEscape,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: scheme.surfaceContainerLow,
          body: DropTarget(
            onDragEntered: (DropEventDetails _) => _setDragging(true),
            onDragExited: (DropEventDetails _) => _setDragging(false),
            onDragDone: (DropDoneDetails details) {
              _setDragging(false);
              unawaited(_handleDrop(details.files));
            },
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    // 高亮与展开状态各用独立通知驱动：点侧栏 / 折叠侧栏时
                    // 都不必重建整页，动画不会被「顶栏 + 播放岛 + 内容区」
                    // 的重建压住
                    ValueListenableBuilder<LibrarySection>(
                      valueListenable: _sectionNotifier,
                      builder:
                          (
                            BuildContext context,
                            LibrarySection section,
                            Widget? child,
                          ) => ValueListenableBuilder<bool>(
                            valueListenable: _railNotifier,
                            builder:
                                (
                                  BuildContext context,
                                  bool expanded,
                                  Widget? child,
                                ) => LibraryRail(
                                  expanded: expanded,
                                  section: section,
                                  onSelect: _selectSection,
                                  onToggle: _toggleRail,
                                  onWindowDragStart: () =>
                                      unawaited(_startWindowDrag()),
                                  onWindowDoubleTap: () =>
                                      unawaited(_toggleWindowMaximize()),
                                ),
                          ),
                    ),
                    Expanded(
                      // 标题条浮在页面之上：内容整体下移，侧栏则继续画到窗口顶部。
                      // RepaintBoundary 把内容区独立成一层：侧栏宽度动画时
                      // 侧栏自己的重绘不会连带整块内容区一起重画
                      child: RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.zero,
                          // 播放岛悬浮在内容之上：列表可以滚到岛下面（悬浮观感），
                          // 但底部留出岛的高度，滚到底时最后一行不会被压住
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              Column(
                                children: <Widget>[
                                  _buildTitleRow(context),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        12,
                                        16,
                                        _playerBarReservedHeight,
                                      ),
                                      child: FadeTransition(
                                        // 只做淡入：交叉淡变会让两份全屏列表
                                        // 同时布局 + 逐帧重绘，切换必掉帧；
                                        // 旧内容立即移除、新内容淡入，观感更利落
                                        opacity: _sectionFade,
                                        child: _buildSectionsHost(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              // 播放岛浮在内容之上：只有岛本身的形状会遮挡列表
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child:
                                    ValueListenableBuilder<_PlaybackProgress>(
                                      valueListenable: _progress,
                                      builder:
                                          (
                                            BuildContext context,
                                            _PlaybackProgress progress,
                                            Widget? child,
                                          ) => ValueListenableBuilder<double>(
                                            // 音量单独一层：拖滑块只重建播放条，
                                            // 不推进状态版本、不连累当前分区
                                            valueListenable: _volumeNotifier,
                                            builder:
                                                (
                                                  BuildContext context,
                                                  double volume,
                                                  Widget? child,
                                                ) => _buildPlayerBar(
                                                  progress,
                                                  volume,
                                                ),
                                          ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_dragging) const _DropOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setFlowBackground(bool value) {
    _update(() => _flowBackground = value);
    _saveSessionNow();
  }

  void _toggleRail() {
    _railExpanded = !_railExpanded;
    // 走通知器而不是 setState：整页（顶栏 / 播放岛 / 分区宿主）不必重建，
    // 侧栏宽度动画每一帧的成本就只剩它自己
    _railNotifier.value = _railExpanded;
    _saveSessionNow();
  }

  /// 放歌时订阅频谱流，暂停 / 停止就退订：BASS 取 FFT 也是跨线程命令，
  /// 静音时没必要每 33ms 打扰一次引擎。
  ///
  /// 由 [_syncMediaSession] 在起播 / 暂停 / 停止时调用（见 playback_section）。
  void _syncSpectrum() {
    if (widget.spectrum == null || _isPlaying == _spectrumActive) {
      return;
    }
    _spectrumActive = _isPlaying;
    if (_isPlaying) {
      SpectrumController.instance.attach();
    } else {
      SpectrumController.instance.detach();
    }
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  void _handleEscape() {
    if (_selectionMode) {
      _exitSelection();
      return;
    }
    if (_query.isNotEmpty) {
      _clearSearch();
    } else {
      _searchFocus.unfocus();
    }
  }

  /// 焦点在搜索框时，空格 / 方向键留给文本编辑，不触发播放控制。
  VoidCallback _unlessTyping(VoidCallback action) {
    return () {
      if (_searchFocus.hasFocus) {
        return;
      }
      action();
    };
  }

  void _handleSpace() {
    if (_searchFocus.hasFocus) {
      return;
    }
    unawaited(_togglePlayback());
  }

  Future<void> _startWindowDrag() async {
    try {
      await _windowControls.startDragging();
    } catch (_) {
      // 测试或平台不支持时忽略
    }
  }

  Future<void> _toggleWindowMaximize() async {
    try {
      await _windowControls.toggleMaximize();
    } catch (_) {
      // 同上
    }
  }

  /// 页面顶栏：搜索、多选入口与窗口拖动区。
  ///
  /// 右侧 [LampTitleBar.controlsWidth] 留给悬浮在最上层的窗口按钮，
  /// 空白处交给拖动区，交互控件盖在拖动区之上。
  Widget _buildTitleRow(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: LampTitleBar.height,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GestureDetector(
            key: const ValueKey<String>('library-window-drag'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => unawaited(_startWindowDrag()),
            onDoubleTap: () => unawaited(_toggleWindowMaximize()),
            child: ColoredBox(color: scheme.surfaceContainerLow),
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: LampTitleBar.controlsWidth + 24,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: _buildSearchField(context),
                  ),
                ),
                if (_selectionMode ||
                    _selectionVisibleTracks.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 12),
                  _buildSelectionToggle(context),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    );

    return TextField(
      controller: _searchController,
      focusNode: _searchFocus,
      onChanged: _onSearchChanged,
      textAlignVertical: TextAlignVertical.center,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: _searchHint,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 38,
          minHeight: 36,
        ),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                onPressed: _clearSearch,
                tooltip: '清除搜索',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                iconSize: 18,
                icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
              ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
      ),
    );
  }

  void _selectSection(LibrarySection section) {
    if (section == _section) {
      // 已在该分区时，再点一次导航相当于「回到列表」：
      // 不应把用户困在歌单 / 艺术家 / 专辑详情里。
      if (_selectedPlaylistId != null ||
          _selectedArtist != null ||
          _selectedAlbumKey != null) {
        _update(() {
          _selectedArtist = null;
          _selectedAlbumKey = null;
          _selectedPlaylistId = null;
        });
      }
      _clearSelection();
      return;
    }
    // 第一帧只换侧栏高亮：新分区首次构建较重，同步构建会把点击的水波纹卡住。
    // 高亮走独立通知器，所以这一帧整页不重建。
    _section = section;
    _sectionNotifier.value = section;
    _saveSessionNow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 期间用户又点了别的分区：让最后一次点击自己走完切换
      if (!mounted || _section != section) {
        return;
      }
      // 搜索只作用于当前分区，换界面后旧关键词没有意义
      final bool clearedQuery = _query.isNotEmpty;
      if (clearedQuery) {
        _debounce?.cancel();
        _searchToken++;
        _searchController.clear();
        _query = '';
        _results = null;
        _searching = false;
        _searchTruncated = false;
        _searchError = null;
      }
      setState(() {
        _displayedSection = section;
        _selectedArtist = null;
        _selectedAlbumKey = null;
        _selectedPlaylistId = null;
        // 已在上面清过搜索词时，让所有分区快照过期，否则切回来会用到带过滤的旧快照
        if (clearedQuery) {
          _stateVersion += 1;
        }
        // 已有快照的分区这一帧先显示旧内容，淡入结束后再补新数据
        _justSwitched = section;
      });
      _clearSelection();

      // 数据加载会同步进入 FFI（数据库查询 / 输出设备查询），
      // 放在点击那一帧会把水波纹压住，所以挪到这里
      if (section == LibrarySection.playlists) {
        unawaited(_loadPlaylists());
      }
      if (section == LibrarySection.favorites) {
        unawaited(_loadFavorites());
      }
      if (section == LibrarySection.history) {
        unawaited(_loadHistory());
      }
      if (section == LibrarySection.settings) {
        // 空闲释放 / 回落共享都可能改变实际输出，进设置页时重新读一次
        unawaited(_refreshOutputInfo());
        unawaited(_refreshDevices());
        // 热插拔系统不会通知：设置页开着时低频轮询设备列表
        _deviceTimer?.cancel();
        _deviceTimer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => unawaited(_refreshDevices()),
        );
      } else {
        _deviceTimer?.cancel();
        _deviceTimer = null;
      }

      _sectionFade.forward(from: 0);

      _sectionRefreshTimer?.cancel();
      _sectionRefreshTimer = Timer(const Duration(milliseconds: 170), () {
        // 淡入期间显示的是旧快照，这里补一次真数据。数据其实没变时
        // （切来切回、或该分区数据未刷新）不必重建——那一次 setState 会
        // 把整个分区再建一遍，是切换后 ~170ms 又卡一下的来源。
        final bool stale = _sectionVersions[section] != _stateVersion;
        _justSwitched = null;
        if (stale && mounted && _displayedSection == section) {
          setState(() {});
        }
      });
    });
  }

  /// 底部播放岛。
  ///
  /// [volume] 走独立 notifier：拖动音量只重建这一个子树，不碰分区内容。
  Widget _buildPlayerBar(_PlaybackProgress progress, double volume) {
    return PlayerBar(
      spectrum: widget.spectrum,
      track: _currentTrack,
      isPlaying: progress.playing,
      isAvailable: _isAvailable,
      canSeek: !_isStopped,
      position: progress.position,
      duration: progress.duration,
      volume: volume,
      onPlayPause: () => unawaited(_togglePlayback()),
      onPrevious: () => unawaited(_previous()),
      onNext: () => unawaited(_next()),
      onSeekStart: _onSeekStart,
      onSeekChanged: _onSeekChanged,
      onSeekEnd: (double seconds) => unawaited(_onSeekEnd(seconds)),
      onVolumeChanged: _setVolume,
      onToggleMute: _toggleMute,
      onShowQueue: () => unawaited(_showQueue()),
      repeat: _queue.repeat,
      shuffle: _queue.shuffle,
      onCyclePlayMode: _cyclePlayMode,
      onOpenNowPlaying: () => unawaited(_openNowPlaying()),
      lyricsLoader: widget.lyricsLoader,
    );
  }

  /// 分区宿主：所有访问过的分区都留在树里（`Offstage` 隐藏，不参与布局与绘制），
  /// 切回来直接复用快照。旧分区不会被销毁，滚动位置与图片缓存也就跟着保住了。
  ///
  /// 只遍历「访问过的分区 + 当前分区」：从没进过的分区不必建，否则启动时
  /// 会用空曲库把艺术家 / 专辑 / 设置先建一份空快照缓存起来，首次进入先闪
  /// 一帧「0 位艺术家」再补真实内容。
  Widget _buildSectionsHost(BuildContext context) {
    final Set<LibrarySection> visited = <LibrarySection>{
      ..._sections.keys,
      _displayedSection,
    };
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final LibrarySection section in visited)
          Offstage(
            // 集合会随访问变化，必须给 key：否则按位置复用 Element，
            // 分区集合一变就错位拿到别的子树
            key: ValueKey<LibrarySection>(section),
            offstage: section != _displayedSection,
            child: TickerMode(
              enabled: section == _displayedSection,
              child: RepaintBoundary(child: _cachedSection(context, section)),
            ),
          ),
      ],
    );
  }

  /// 取（必要时构建）某个分区的快照。
  ///
  /// - 快照与当前状态版本一致：原样返回，Element 直接跳过子树重建
  /// - 刚切换过来且已有快照：先返回旧快照（切换帧零重建），淡入结束后再补
  /// - 隐藏分区：不重建，等切回来
  Widget _cachedSection(BuildContext context, LibrarySection section) {
    final Widget? cached = _sections[section];
    if (cached != null && _sectionVersions[section] == _stateVersion) {
      return cached;
    }
    if (cached != null && section == _justSwitched) {
      return cached;
    }
    if (cached != null && section != _displayedSection) {
      return cached;
    }
    final Widget built = _buildSectionFor(context, section);
    _sections[section] = built;
    _sectionVersions[section] = _stateVersion;
    return built;
  }

  Widget _buildSectionFor(BuildContext context, LibrarySection section) {
    return switch (section) {
      LibrarySection.music => _buildMusicSection(context),
      LibrarySection.playlists => _buildPlaylistsSection(context),
      LibrarySection.history => _buildHistorySection(context),
      LibrarySection.favorites => _buildFavoritesSection(context),
      LibrarySection.artists => _buildArtistsSection(context),
      LibrarySection.albums => _buildAlbumsSection(context),
      LibrarySection.settings => _buildSettingsSection(context),
    };
  }
}

/// 标题右侧的排序下拉，外观是描边胶囊。
class _SortButton extends StatelessWidget {
  const _SortButton({required this.mode, required this.onSelected});

  final LibrarySort mode;
  final ValueChanged<LibrarySort> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return PopupMenuButton<LibrarySort>(
      tooltip: '排序方式',
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<LibrarySort>>[
        for (final LibrarySort item in LibrarySort.values)
          PopupMenuItem<LibrarySort>(
            value: item,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 24,
                  child: item == mode
                      ? Icon(Icons.check, size: 18, color: scheme.primary)
                      : null,
                ),
                const SizedBox(width: 8),
                Text(item.label),
              ],
            ),
          ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '排序：${mode.label}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 20, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _DetailBar extends StatelessWidget {
  const _DetailBar({required this.label, required this.onBack});

  final String label;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        IconButton(
          onPressed: onBack,
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 播放条需要的进度快照；配合 [ValueNotifier] 只刷新播放条。
@immutable
class _PlaybackProgress {
  const _PlaybackProgress({
    this.position = 0,
    this.duration = 0,
    this.playing = false,
  });

  final double position;
  final double duration;
  final bool playing;
}

/// 拖拽文件到窗口时的高亮提示；不拦截鼠标事件。
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return IgnorePointer(
      child: ColoredBox(
        color: scheme.scrim.withValues(alpha: 0.32),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: scheme.primary, width: 2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.library_music_outlined,
                  size: 48,
                  color: scheme.primary,
                ),
                const SizedBox(height: 12),
                Text('松开即可导入音乐', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '文件夹会整个扫描，单个音频文件按所在目录导入',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 串行执行链：同一时刻只跑一个任务，前一个失败不影响后一个。
///
/// 会话写盘、播放命令、收藏写库都需要「按顺序来」：交错会写出撕裂快照、
/// 让队列被多推一次，或者让数据库终态与界面相反。失败只记日志——各调用点
/// 自己负责给用户提示，这里再抛就成了未处理异常并毒化整条链。
class _SerialChain {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() action, {required String label}) {
    final Completer<void> done = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await action();
      } catch (error, stack) {
        debugPrint('$label失败：$error\n$stack');
      }
      if (!done.isCompleted) {
        done.complete();
      }
    });
    return done.future;
  }
}

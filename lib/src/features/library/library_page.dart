import 'dart:async';
import 'dart:io' show Platform, Process;
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;

import '../../app/session_store.dart';
import '../../app/title_bar.dart';
import '../../common/common.dart';
import '../../rust/api/model.dart';
import '../../rust/api/player.dart' as rust;
import '../../rust/api/scan.dart' as scan;
import '../player/playback_queue.dart';
import '../player/playback_service.dart';
import '../player/player_bar.dart';
import '../player/queue_dialog.dart';
import '../settings/music_folder_store.dart';
import '../settings/settings_view.dart';
import 'drop_import.dart';
import 'library_repository.dart';
import 'library_sort.dart';
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
part 'sections/settings_section.dart';
part 'sections/history_section.dart';
part 'sections/favorites_section.dart';
part 'sections/playlists_section.dart';
part 'sections/music_section.dart';
part 'sections/artists_section.dart';
part 'sections/albums_section.dart';

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
  });

  /// 曲库数据源；不传则走 Rust。
  final LibraryRepository? repository;

  /// 播放能力；不传则走 Rust / BASS。
  final PlaybackService? playbackService;

  /// 选择音乐目录；不传则打开系统目录选择框。
  final DirectoryPicker? directoryPicker;

  /// 已添加目录的持久化；不传则用 shared_preferences。
  final MusicFolderStore? musicFolderStore;

  /// 音量 / 上次播放 / 分区等会话状态；不传则用 shared_preferences。
  final SessionStore? sessionStore;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const Duration _searchDebounce = Duration(milliseconds: 300);
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// 音量滑块的合并窗口：拖动时最多每 80ms 发一次 FFI。
  static const Duration _volumeThrottle = Duration(milliseconds: 80);

  /// 位置轮询连续失败多少次后停止（单次瞬时异常不应冻结进度条）。
  static const int _maxPollFailures = 3;

  late final LibraryRepository _repository =
      widget.repository ?? const RustLibraryRepository();
  late final PlaybackService _playback =
      widget.playbackService ?? const RustPlaybackService();
  late final MusicFolderStore _folderStore =
      widget.musicFolderStore ?? const PrefsMusicFolderStore();
  late final SessionStore _sessionStore =
      widget.sessionStore ?? const PrefsSessionStore();

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

  /// 侧边栏触发一次视图切换就 +1，只用来驱动分区过渡动画；
  /// 数据刷新不会改它，避免列表更新时整页重放动画。
  int _viewVersion = 0;
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

  List<Playlist> _playlists = const <Playlist>[];
  bool _playlistsLoading = false;
  Object? _playlistsError;
  int? _selectedPlaylistId;
  List<Track> _playlistTracks = const <Track>[];
  bool _playlistTracksLoading = false;
  Object? _playlistTracksError;

  Track? _currentTrack;
  bool _isPlaying = false;
  bool _isAvailable = false;
  bool _seeking = false;
  double _position = 0;
  double _duration = 0;
  double _volume = 1;
  double _lastVolume = 1;
  bool _engineNoticeShown = false;

  /// 是否请求 WASAPI 独占输出（偏好；设备不支持时引擎会回落共享）
  bool _exclusive = false;
  bool _switchingOutput = false;

  /// 当前输出的实际描述，来自引擎（含回落原因）
  String _outputInfo = '';

  /// 播放进度单独放进 notifier：轮询只刷新播放条，不重建整个曲库页面。
  final ValueNotifier<_PlaybackProgress> _progress =
      ValueNotifier<_PlaybackProgress>(const _PlaybackProgress());

  /// 是否有文件正拖在窗口上（显示导入提示）
  bool _dragging = false;

  /// 艺术家 / 专辑聚合缓存；`_tracks` 换新对象时才重算
  List<Track>? _groupedTracks;
  List<ArtistGroup>? _artistGroups;
  List<AlbumGroup>? _albumGroups;

  /// 拆到 `sections/` 的代码不能直接调 `@protected` 的 `setState`，统一走这里
  void _update(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    _isAvailable = _readAvailability();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _positionTimer?.cancel();
    _volumeTimer?.cancel();
    _saveTimer?.cancel();
    _sessionTimer?.cancel();
    unawaited(_saveSession());
    _searchFocus.dispose();
    _searchController.dispose();
    _progress.dispose();
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
      _section = section;
      _railExpanded = snapshot.railExpanded;
      _sort = snapshot.sort;
      _tracks = sortTracks(_tracks, snapshot.sort);
      _coverBackfillAttempted = snapshot.coverBackfillAttempted;
      _exclusive = snapshot.exclusiveOutput;
    });

    if (!mounted) {
      return;
    }
    _restoreLastTrack(snapshot);

    unawaited(_refreshFavoritePaths());
    unawaited(_loadFoldersAndMaybeBackfill());
    if (_isAvailable) {
      unawaited(_applyVolume(_volume));
      // 先按偏好切输出，再刷新描述：启动时还没有曲目，切换几乎没有代价
      unawaited(_applyOutputPreference(snapshot.exclusiveOutput));
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
    final int index = _tracks.indexWhere((Track track) => track.path == path);
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

  Future<void> _saveSession() {
    return _sessionStore.save(
      SessionSnapshot(
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
      ),
    );
  }

  /* ---------------------------------------------------------------- 界面 */

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 放在页面根部：文本框聚焦时由 EditableText 自己消费空格与方向键，
    // 其余情况下才落到播放控制上。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
            _handleSpace,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          includeRepeats: false,
        ): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
            _handleEscape,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          includeRepeats: false,
        ): () =>
            _unlessTyping(() => unawaited(_seekBy(5))),
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          includeRepeats: false,
        ): () =>
            _unlessTyping(() => unawaited(_seekBy(-5))),
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
          includeRepeats: false,
        ): () =>
            _unlessTyping(() => unawaited(_next())),
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
          includeRepeats: false,
        ): () =>
            _unlessTyping(() => unawaited(_previous())),
        const SingleActivator(
          LogicalKeyboardKey.arrowUp,
          control: true,
          includeRepeats: false,
        ): () =>
            _unlessTyping(() => _setVolume(_volume + 0.05)),
        const SingleActivator(
          LogicalKeyboardKey.arrowDown,
          control: true,
          includeRepeats: false,
        ): () =>
            _unlessTyping(() => _setVolume(_volume - 0.05)),
        const SingleActivator(
          LogicalKeyboardKey.keyM,
          control: true,
          includeRepeats: false,
        ): _toggleMute,
        const SingleActivator(
          LogicalKeyboardKey.mediaPlayPause,
          includeRepeats: false,
        ): () =>
            unawaited(_togglePlayback()),
        const SingleActivator(
          LogicalKeyboardKey.mediaTrackNext,
          includeRepeats: false,
        ): () =>
            unawaited(_next()),
        const SingleActivator(
          LogicalKeyboardKey.mediaTrackPrevious,
          includeRepeats: false,
        ): () =>
            unawaited(_previous()),
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
                    LibraryRail(
                      expanded: _railExpanded,
                      section: _section,
                      onSelect: _selectSection,
                      onToggle: _toggleRail,
                    ),
                    Expanded(
                      // 标题条浮在页面之上：内容整体下移，侧栏则继续画到窗口顶部。
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: LampTitleBar.height,
                        ),
                        child: Column(
                          children: <Widget>[
                            _buildTopBar(context),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  0,
                                ),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  layoutBuilder:
                                      (
                                        Widget? currentChild,
                                        List<Widget> previousChildren,
                                      ) {
                                        return Stack(
                                          fit: StackFit.expand,
                                          children: <Widget>[
                                            // 旧分区正在淡出时不响应点击，避免误触。
                                            for (final Widget child
                                                in previousChildren)
                                              IgnorePointer(child: child),
                                            ?currentChild,
                                          ],
                                        );
                                      },
                                  transitionBuilder:
                                      (
                                        Widget child,
                                        Animation<double> animation,
                                      ) {
                                        return FadeTransition(
                                          opacity: animation,
                                          child: SlideTransition(
                                            position: Tween<Offset>(
                                              begin: const Offset(0, 0.01),
                                              end: Offset.zero,
                                            ).animate(animation),
                                            child: child,
                                          ),
                                        );
                                      },
                                  child: KeyedSubtree(
                                    key: ValueKey<int>(_viewVersion),
                                    child: _buildSection(context),
                                  ),
                                ),
                              ),
                            ),
                            ValueListenableBuilder<_PlaybackProgress>(
                              valueListenable: _progress,
                              builder:
                                  (
                                    BuildContext context,
                                    _PlaybackProgress progress,
                                    Widget? child,
                                  ) {
                                    return PlayerBar(
                                      track: _currentTrack,
                                      isPlaying: progress.playing,
                                      isAvailable: _isAvailable,
                                      canSeek: !_isStopped,
                                      position: progress.position,
                                      duration: progress.duration,
                                      volume: _volume,
                                      onPlayPause: () =>
                                          unawaited(_togglePlayback()),
                                      onPrevious: () => unawaited(_previous()),
                                      onNext: () => unawaited(_next()),
                                      onSeekStart: _onSeekStart,
                                      onSeekChanged: _onSeekChanged,
                                      onSeekEnd: (double seconds) =>
                                          unawaited(_onSeekEnd(seconds)),
                                      onVolumeChanged: _setVolume,
                                      onToggleMute: _toggleMute,
                                      onShowQueue: () =>
                                          unawaited(_showQueue()),
                                      repeat: _queue.repeat,
                                      shuffle: _queue.shuffle,
                                      onToggleRepeat: _cycleRepeat,
                                      onToggleShuffle: _toggleShuffle,
                                    );
                                  },
                            ),
                          ],
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

  void _toggleRail() {
    setState(() => _railExpanded = !_railExpanded);
    _saveSessionNow();
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  void _handleEscape() {
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

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: _buildSearchField(context),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    );

    return TextField(
      controller: _searchController,
      focusNode: _searchFocus,
      onChanged: _onSearchChanged,
      textAlignVertical: TextAlignVertical.center,
      style: theme.textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: '搜索',
        hintStyle: theme.textTheme.bodyLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        prefixIcon: Icon(Icons.search, color: scheme.onSurfaceVariant),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                onPressed: _clearSearch,
                tooltip: '清除搜索',
                icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
              ),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
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
        setState(() {
          _selectedArtist = null;
          _selectedAlbumKey = null;
          _selectedPlaylistId = null;
          _viewVersion += 1;
        });
      }
      return;
    }
    setState(() {
      _section = section;
      _selectedArtist = null;
      _selectedAlbumKey = null;
      _selectedPlaylistId = null;
      _viewVersion += 1;
    });
    _saveSessionNow();
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
    }
  }

  Widget _buildSection(BuildContext context) {
    return switch (_section) {
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

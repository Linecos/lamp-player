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

  /// 播放进度单独放进 notifier：轮询只刷新播放条，不重建整个曲库页面。
  final ValueNotifier<_PlaybackProgress> _progress =
      ValueNotifier<_PlaybackProgress>(const _PlaybackProgress());

  /// 是否有文件正拖在窗口上（显示导入提示）
  bool _dragging = false;

  /// 艺术家 / 专辑聚合缓存；`_tracks` 换新对象时才重算
  List<Track>? _groupedTracks;
  List<ArtistGroup>? _artistGroups;
  List<AlbumGroup>? _albumGroups;

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
    });

    if (!mounted) {
      return;
    }
    _restoreLastTrack(snapshot);

    unawaited(_refreshFavoritePaths());
    unawaited(_loadFoldersAndMaybeBackfill());
    if (_isAvailable) {
      unawaited(_applyVolume(_volume));
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
      ),
    );
  }

  bool _readAvailability() {
    try {
      return _playback.isAvailable;
    } catch (_) {
      return false;
    }
  }

  /// 把当前进度写进 notifier，只刷新播放条。
  void _publishProgress() {
    _progress.value = _PlaybackProgress(
      position: _position,
      duration: _duration,
      playing: _isPlaying,
    );
  }

  /// 艺术家 / 专辑聚合结果按 `_tracks` 的对象身份缓存，避免每次 rebuild
  /// （包括播放进度刷新）都全量重算。
  List<ArtistGroup> get _artistGroupsCache {
    _rebuildGroupsIfNeeded();
    return _artistGroups ?? const <ArtistGroup>[];
  }

  List<AlbumGroup> get _albumGroupsCache {
    _rebuildGroupsIfNeeded();
    return _albumGroups ?? const <AlbumGroup>[];
  }

  void _rebuildGroupsIfNeeded() {
    if (identical(_groupedTracks, _tracks)) {
      return;
    }
    _groupedTracks = _tracks;
    _artistGroups = groupTracksByArtist(_tracks);
    _albumGroups = groupTracksByAlbum(_tracks);
  }

  /// 引擎是否处于停止态（未播放、已播完、或引擎不可用）。
  ///
  /// 停止态下滑块要禁用：此时 seek 虽然能成功，但播放键会从头重播。
  bool get _isStopped {
    try {
      return _playback.state == rust.PlaybackState.stopped;
    } catch (_) {
      return true;
    }
  }

  /* ---------------------------------------------------------------- 数据 */

  Future<void> _loadTracks() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Track> tracks = await _repository.loadTracks();
      if (!mounted) {
        return;
      }
      setState(() {
        _tracks = sortTracks(tracks, _sort);
        _loading = false;
        // 扫描会刷新封面等字段：队列和当前曲目换成新对象，避免播放条还拿旧数据
        if (!_queue.isEmpty) {
          _queue.refreshTracks(_tracks);
        }
        final Track? current = _currentTrack;
        if (current != null) {
          final int index = _tracks.indexWhere(
            (Track track) => track.path == current.path,
          );
          if (index >= 0) {
            _currentTrack = _tracks[index];
          }
        }
      });
      if (_query.isNotEmpty) {
        unawaited(_runSearch(_query));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /* ------------------------------------------------------------ 音乐目录 */

  Future<void> _loadFolders() async {
    final List<String> folders = await _folderStore.load();
    if (!mounted) {
      return;
    }
    setState(() => _folders = normalizeFolders(folders));
  }

  Future<void> _loadFoldersAndMaybeBackfill() async {
    await _loadFolders();
    await _backfillCoversIfNeeded();
  }

  /// 曲库升到 v3 后老曲目没有封面：首次启动补扫一次已添加目录。
  ///
  /// 成败都记为「已尝试」，否则没有内嵌封面的曲库会每次启动都全量扫一遍。
  Future<void> _backfillCoversIfNeeded() async {
    if (!mounted || _coverBackfillAttempted || _scanning) {
      return;
    }
    if (_tracks.isEmpty || _folders.isEmpty) {
      return;
    }
    // 只有「全部没有封面」才视为升级后的老曲库；混合状态通常说明用户
    // 已经手动扫过一部分目录，不再自动全量重扫。
    if (!_tracks.every((Track track) => track.coverPath == null)) {
      setState(() => _coverBackfillAttempted = true);
      unawaited(_saveSession());
      return;
    }

    setState(() => _backfillingCovers = true);
    for (final String folder in List<String>.of(_folders)) {
      if (!mounted) {
        return;
      }
      await _scanDirectory(folder, notify: false);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _backfillingCovers = false;
      _coverBackfillAttempted = true;
    });
    unawaited(_saveSession());
  }

  /// 记下新目录（忽略大小写去重）；已存在时不重复写入。
  ///
  /// 持久化是"尽力而为"：不等待写完就开始扫描，避免磁盘/插件慢时拖住扫描。
  void _rememberFolder(String folder) {
    final List<String> next = normalizeFolders(<String>[..._folders, folder]);
    if (next.length == _folders.length) {
      return;
    }
    setState(() => _folders = next);
    unawaited(_folderStore.save(next));
  }

  /// 从列表移除目录：只删记录，不删除已入库的曲目。
  void _removeFolder(String folder) {
    final String key = folder.toLowerCase();
    final List<String> next = _folders
        .where((String item) => item.toLowerCase() != key)
        .toList();
    setState(() {
      _folders = next;
      if (_lastScanFolder?.toLowerCase() == key) {
        _lastScanFolder = null;
        _scanReport = null;
        _scanError = null;
      }
    });
    unawaited(_folderStore.save(next));
  }

  Future<void> _rescanFolder(String folder) async {
    if (_scanning) {
      return;
    }
    await _scanDirectory(folder);
  }

  Future<String?> _pickDirectory() {
    return getDirectoryPath(confirmButtonText: '选择音乐目录');
  }

  Future<void> _addMusicFolder() async {
    if (_scanning) {
      return;
    }

    final DirectoryPicker picker = widget.directoryPicker ?? _pickDirectory;
    String? folder;
    try {
      folder = await picker();
    } catch (error) {
      if (mounted) {
        _showMessage('选择目录失败：${ErrorRetry.describe(error)}');
      }
      return;
    }
    if (folder == null || folder.trim().isEmpty || !mounted) {
      return;
    }

    _rememberFolder(folder.trim());
    await _scanDirectory(folder.trim());
  }

  void _setDragging(bool value) {
    if (_dragging == value) {
      return;
    }
    setState(() => _dragging = value);
  }

  /// 拖入文件夹或音频文件：取它们所在的目录，复用已有的扫描与记忆流程。
  Future<void> _handleDrop(List<DropItem> files) async {
    if (!mounted) {
      return;
    }
    if (_scanning) {
      _showMessage('正在扫描，请稍后再拖入');
      return;
    }
    final List<String> folders = foldersFromDropPaths(
      files.map((DropItem file) => file.path),
    );
    if (folders.isEmpty) {
      _showMessage('没有识别到可导入的文件夹');
      return;
    }
    if (_section == LibrarySection.settings) {
      _selectSection(LibrarySection.music);
    }

    int imported = 0;
    for (final String folder in folders) {
      _rememberFolder(folder);
      final bool ok = await _scanDirectory(folder, notify: false);
      if (!mounted) {
        return;
      }
      if (!ok) {
        final Object? error = _scanError;
        _showMessage(
          '导入失败：${error == null ? '未知错误' : ErrorRetry.describe(error)}',
        );
        return;
      }
      imported += 1;
    }
    if (!mounted) {
      return;
    }
    final scan.ScanReport? report = _scanReport;
    _showMessage(
      report == null
          ? '已导入 $imported 个目录'
          : '导入完成：$imported 个目录，更新 ${report.upserted} 首，'
                '失败 ${report.failed} 首',
    );
  }

  /// 扫描指定目录；设置页展示结果，空曲库时用 SnackBar 提示。
  ///
  /// 自动补扫时传 `notify: false`，避免多个目录各弹一次提示。
  Future<bool> _scanDirectory(String folder, {bool notify = true}) async {
    if (_scanning) {
      return false;
    }

    setState(() {
      _scanning = true;
      _lastScanFolder = folder;
      _scanReport = null;
      _scanError = null;
    });
    try {
      final scan.ScanReport report = await _repository.scanFolder(folder);
      await _loadTracks();
      if (!mounted) {
        return false;
      }
      setState(() {
        _scanning = false;
        _scanReport = report;
      });
      if (!_backfillingCovers) {
        _coverBackfillAttempted = true;
        unawaited(_saveSession());
      }
      if (notify && _section != LibrarySection.settings) {
        _showMessage(
          '扫描完成：更新 ${report.upserted} 首，失败 ${report.failed} 首，'
          '清理 ${report.pruned} 首',
        );
      }
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _scanning = false;
        _scanError = error;
      });
      if (!_backfillingCovers) {
        _coverBackfillAttempted = true;
        unawaited(_saveSession());
      }
      if (notify && _section != LibrarySection.settings) {
        _showMessage('扫描失败：${ErrorRetry.describe(error)}');
      }
      return false;
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final String query = value.trim();
    setState(() {
      _query = query;
      _searchError = null;
      if (query.isEmpty) {
        _results = null;
        _searching = false;
        _searchToken++;
      }
    });
    if (query.isEmpty) {
      return;
    }
    _debounce = Timer(_searchDebounce, () {
      unawaited(_runSearch(query));
    });
  }

  Future<void> _runSearch(String query) async {
    final int token = ++_searchToken;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final List<Track> results = await _repository.searchTracks(
        query,
        limit: 500,
      );
      if (!mounted || token != _searchToken) {
        return;
      }
      setState(() {
        _results = sortTracks(results, _sort);
        _searching = false;
      });
    } catch (error) {
      if (!mounted || token != _searchToken) {
        return;
      }
      setState(() {
        _results = null;
        _searching = false;
        _searchError = error;
      });
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchToken++;
    _searchController.clear();
    setState(() {
      _query = '';
      _results = null;
      _searching = false;
      _searchError = null;
    });
  }

  void _changeSort(LibrarySort sort) {
    if (sort == _sort) {
      return;
    }
    setState(() {
      _sort = sort;
      _tracks = sortTracks(_tracks, sort);
      final List<Track>? results = _results;
      if (results != null) {
        _results = sortTracks(results, sort);
      }
    });
    _saveSessionNow();
  }

  /* ---------------------------------------------------------------- 播放 */

  /// 从 [tracks] 这份列表里播放 [track]，整份列表成为播放队列。
  Future<void> _playFrom(List<Track> tracks, Track track) async {
    if (tracks.isEmpty) {
      return;
    }
    int index = tracks.indexWhere((Track item) => item.path == track.path);
    if (index < 0) {
      index = 0;
      tracks = <Track>[track];
    }
    _queue.reset(tracks, index: index);
    await _startCurrent();
  }

  /// 播放队列当前曲目；[startAt] 用于恢复上次播放位置。
  Future<bool> _startCurrent({double startAt = 0}) async {
    final Track? track = _queue.current;
    if (track == null) {
      return false;
    }
    final double duration = track.durationSecs;
    setState(() {
      _currentTrack = track;
      _duration = duration;
      _position = duration > 0 ? startAt.clamp(0.0, duration) : startAt;
      _pendingResumePosition = null;
      _isPlaying = false;
    });
    _publishProgress();
    _scheduleSessionSave();
    if (!_isAvailable) {
      _showEngineNotice();
      return false;
    }
    try {
      await _playback.play(track.path);
      if (startAt > 0) {
        await _playback.seek(startAt);
      }
      if (!mounted) {
        return false;
      }
      setState(() => _isPlaying = true);
      _publishProgress();
      _startPositionPolling();
      unawaited(_recordPlay(track.path));
      _saveSessionNow();
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() => _isPlaying = false);
      _publishProgress();
      _showMessage('播放失败：${ErrorRetry.describe(error)}');
      return false;
    }
  }

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    await _playFrom(tracks, tracks.first);
  }

  /// 历史记录失败不影响播放，只记录日志。
  Future<void> _recordPlay(String path) async {
    try {
      await _repository.recordPlay(path);
    } catch (error) {
      debugPrint('记录播放历史失败：$error');
    }
  }

  Future<void> _togglePlayback() async {
    if (!_isAvailable) {
      _showEngineNotice();
      return;
    }
    if (_currentTrack == null) {
      return;
    }
    try {
      // 自然播完后 stream 停在末尾，resume 不会回到开头；按重新播放处理。
      // 先看真实状态，避免本地 _isPlaying 还没被轮询刷新的窗口里误走 pause。
      if (_playback.state == rust.PlaybackState.stopped) {
        final double startAt = _pendingResumePosition ?? 0;
        await _startCurrent(startAt: startAt);
        return;
      }
      if (_isPlaying) {
        await _playback.pause();
      } else {
        await _playback.resume();
      }
      if (!mounted) {
        return;
      }
      setState(() => _isPlaying = !_isPlaying);
      _publishProgress();
      if (_isPlaying) {
        _startPositionPolling();
      } else {
        _stopPositionPolling();
        _saveSessionNow();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('操作失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 下一首；[auto] 表示自然播完（单曲循环时重播本曲）。
  ///
  /// `advance` 返回 null 有两层含义，必须分开处理：自然播完时音频已经停了，
  /// 只需把界面切到“结束”；手动点下一首而队列到头时音频还在放，此时若照搬
  /// “结束”分支，就会出现进度条冻在末尾、图标变播放，但歌还在响。
  Future<void> _next({bool auto = false}) async {
    if (_queue.isEmpty) {
      return;
    }
    final int? index = _queue.advance(auto: auto);
    if (index == null) {
      if (!auto) {
        _showMessage('已经是最后一首');
        return;
      }
      _stopPositionPolling();
      if (!mounted) {
        return;
      }
      setState(() {
        _isPlaying = false;
        _position = _duration;
      });
      _publishProgress();
      _saveSessionNow();
      return;
    }
    await _startCurrent();
  }

  /// 上一首：播放超过 3 秒先回到本曲开头，符合桌面播放器习惯。
  Future<void> _previous() async {
    if (_currentTrack == null) {
      return;
    }
    if (!_isStopped && _position > 3) {
      await _seekTo(0);
      return;
    }
    final int? index = _queue.retreat();
    if (index == null) {
      await _seekTo(0);
      return;
    }
    await _startCurrent();
  }

  /// 轮询发现引擎已停止：只有“本来在播”才自动切歌，
  /// 避免暂停 / 初始化阶段误触发。
  Future<void> _handleTrackEnded() async {
    if (_handlingEnd) {
      return;
    }
    _handlingEnd = true;
    try {
      await _next(auto: true);
    } finally {
      _handlingEnd = false;
    }
  }

  void _cycleRepeat() {
    setState(() => _queue.setRepeat(_queue.repeat.next));
    _saveSessionNow();
  }

  void _toggleShuffle() {
    setState(() => _queue.setShuffle(!_queue.shuffle));
    _saveSessionNow();
  }

  Future<void> _showQueue() {
    return showPlaybackQueueDialog(
      context,
      queue: _queue,
      onChanged: _onQueueChanged,
    );
  }

  /// 队列被面板修改后同步播放状态。
  ///
  /// 删除当前曲目时切到顶上来的那首；队列清空时停下并清掉播放条。
  /// 原本暂停就保持暂停，不因为删了一首突然出声。
  Future<void> _onQueueChanged() async {
    if (!mounted) {
      return;
    }
    final Track? target = _queue.current;
    final Track? current = _currentTrack;

    if (target == null) {
      _stopPositionPolling();
      if (_isAvailable && current != null) {
        try {
          await _playback.stop();
        } catch (error) {
          debugPrint('停止播放失败：$error');
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _currentTrack = null;
        _isPlaying = false;
        _position = 0;
        _duration = 0;
        _pendingResumePosition = null;
      });
      _publishProgress();
      _saveSessionNow();
      return;
    }

    if (current?.path == target.path) {
      setState(() {});
      _saveSessionNow();
      return;
    }

    final bool wasPlaying = _isPlaying;
    if (current != null) {
      _stopPositionPolling();
      if (_isAvailable) {
        try {
          await _playback.stop();
        } catch (error) {
          debugPrint('停止播放失败：$error');
        }
      }
      if (!mounted) {
        return;
      }
    }

    final double duration = target.durationSecs;
    setState(() {
      _currentTrack = target;
      _duration = duration;
      _position = 0;
      _pendingResumePosition = null;
      _isPlaying = false;
    });
    _publishProgress();
    _saveSessionNow();
    if (wasPlaying) {
      await _startCurrent();
    }
  }

  /// 曲目右键菜单的统一入口。
  void _onTrackContext(
    List<Track> tracks,
    Track track,
    TrackContextAction action,
  ) {
    switch (action) {
      case TrackContextAction.play:
        unawaited(_playFrom(tracks, track));
      case TrackContextAction.playNext:
        _playNext(track);
      case TrackContextAction.addToQueue:
        _enqueue(track);
      case TrackContextAction.toggleFavorite:
        unawaited(_toggleFavorite(track));
      case TrackContextAction.addToPlaylist:
        unawaited(_addToPlaylist(track));
      case TrackContextAction.revealInExplorer:
        unawaited(_revealInExplorer(track));
      case TrackContextAction.copyPath:
        unawaited(_copyPath(track));
    }
  }

  void _playNext(Track track) {
    if (_queue.isEmpty) {
      unawaited(_playFrom(<Track>[track], track));
      return;
    }
    if (_queue.current?.path == track.path) {
      _showMessage('正在播放这首');
      return;
    }
    final bool added = _queue.insertNext(track);
    setState(() {});
    _saveSessionNow();
    _showMessage(added ? '已设为下一首：${track.title}' : '队列里已经有这首');
  }

  void _enqueue(Track track) {
    if (_queue.isEmpty) {
      unawaited(_playFrom(<Track>[track], track));
      return;
    }
    if (_queue.current?.path == track.path) {
      _showMessage('正在播放这首');
      return;
    }
    final bool added = _queue.append(track);
    setState(() {});
    _saveSessionNow();
    _showMessage(added ? '已加入队列：${track.title}' : '队列里已经有这首');
  }

  Future<void> _revealInExplorer(Track track) async {
    if (!Platform.isWindows) {
      _showMessage('当前平台暂不支持打开文件位置');
      return;
    }
    try {
      await Process.run('explorer.exe', <String>['/select,', track.path]);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('打开文件位置失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _copyPath(Track track) async {
    await Clipboard.setData(ClipboardData(text: track.path));
    if (!mounted) {
      return;
    }
    _showMessage('已复制文件路径');
  }

  /// 拖动进度时停掉轮询，否则下一次 tick 会把滑块拉回原位置。
  void _onSeekStart(double _) {
    _seeking = true;
    _stopPositionPolling();
  }

  void _onSeekChanged(double seconds) {
    setState(() => _position = seconds);
    _publishProgress();
  }

  Future<void> _seekTo(double seconds) async {
    if (!_isAvailable) {
      return;
    }
    try {
      await _playback.seek(seconds);
      if (!mounted) {
        return;
      }
      setState(() => _position = seconds);
      _publishProgress();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('跳转失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _onSeekEnd(double seconds) async {
    _seeking = false;
    // 已停止（播完 / 未开始）时不要 seek：位置会改变但播放键会从头重播，
    // 等于白拖。滑块此时本身就是禁用的，这里再兜一层。
    final bool canSeek = _isAvailable && !_isStopped;
    if (canSeek) {
      await _seekTo(seconds);
    }
    if (_isPlaying && _positionTimer == null) {
      _startPositionPolling();
    }
  }

  /// 键盘快进 / 快退 5 秒
  Future<void> _seekBy(double delta) async {
    if (_currentTrack == null || !_isAvailable || _isStopped) {
      return;
    }
    final double maxPosition = _duration > 0 ? _duration : _position + delta;
    final double target = (_position + delta).clamp(0.0, maxPosition);
    await _seekTo(target);
  }

  /// 音量变化：UI 立即跟随，实际调用按 [_volumeThrottle] 合并，
  /// 避免拖动时每个像素都发一条 FFI 命令。
  void _setVolume(double volume) {
    final double next = volume.clamp(0.0, 1.0).toDouble();
    setState(() {
      if (next > 0) {
        _lastVolume = next;
      }
      _volume = next;
    });
    _scheduleSessionSave();
    if (!_isAvailable) {
      return;
    }
    _pendingVolume = next;
    _volumeTimer ??= Timer(_volumeThrottle, _flushVolume);
  }

  /// 把合并窗口内的最后一次音量发给引擎。
  void _flushVolume() {
    _volumeTimer = null;
    final double? next = _pendingVolume;
    _pendingVolume = null;
    if (next != null) {
      unawaited(_applyVolume(next));
    }
  }

  Future<void> _applyVolume(double volume) async {
    try {
      // 滑块是线性手感，引擎要的是线性振幅：走感知曲线，低音量段才调得动。
      await _playback.setVolume(volumeToAmplitude(volume));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('调节音量失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 静音 / 取消静音：立即生效，并丢弃尚未发出的中间值。
  void _toggleMute() {
    final double next = _volume > 0 ? 0 : (_lastVolume > 0 ? _lastVolume : 1);
    _volumeTimer?.cancel();
    _volumeTimer = null;
    _pendingVolume = null;
    setState(() {
      if (next > 0) {
        _lastVolume = next;
      }
      _volume = next;
    });
    _saveSessionNow();
    if (_isAvailable) {
      unawaited(_applyVolume(next));
    }
  }

  void _startPositionPolling() {
    _pollFailures = 0;
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(_tickPosition());
    });
  }

  void _stopPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _tickPosition() async {
    if (_ticking) {
      return;
    }
    _ticking = true;
    try {
      final double position = await _playback.position();
      final double duration = await _playback.duration();
      final rust.PlaybackState state = _playback.state;
      final bool wasPlaying = _isPlaying;
      _pollFailures = 0;
      if (!mounted || _seeking) {
        return;
      }
      // 只更新字段与播放条 notifier，不 setState：否则每 500ms 重建整个曲库。
      _position = position;
      if (duration > 0) {
        _duration = duration;
      }
      _isPlaying = state == rust.PlaybackState.playing;
      _publishProgress();
      if (state == rust.PlaybackState.stopped) {
        _stopPositionPolling();
        if (wasPlaying && !_seeking) {
          unawaited(_handleTrackEnded());
        }
      }
    } catch (_) {
      // 单次失败（引擎忙、响应中断）不该让进度条永久冻住：
      // 连续失败达到上限才停，期间继续按周期重试。
      _pollFailures += 1;
      if (_pollFailures >= _maxPollFailures) {
        _stopPositionPolling();
      }
    } finally {
      _ticking = false;
    }
  }

  void _showEngineNotice() {
    if (_engineNoticeShown) {
      return;
    }
    _engineNoticeShown = true;
    _showMessage('播放引擎不可用（缺少 BASS DLL 或初始化失败）：现在可以浏览曲目，暂时不能出声。');
  }

  void _showMessage(String message) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /* ---------------------------------------------------------------- 界面 */

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 放在页面根部：文本框聚焦时由 EditableText 自己消费空格与方向键，
    // 其余情况下才落到播放控制上。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): _handleSpace,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _unlessTyping(() => unawaited(_seekBy(5))),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _unlessTyping(() => unawaited(_seekBy(-5))),
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
        ): () =>
            _unlessTyping(() => unawaited(_next())),
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
        ): () =>
            _unlessTyping(() => unawaited(_previous())),
        const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () =>
            _unlessTyping(() => _setVolume(_volume + 0.05)),
        const SingleActivator(
          LogicalKeyboardKey.arrowDown,
          control: true,
        ): () =>
            _unlessTyping(() => _setVolume(_volume - 0.05)),
        const SingleActivator(LogicalKeyboardKey.keyM, control: true):
            _toggleMute,
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
            unawaited(_togglePlayback()),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
            unawaited(_next()),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
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

  Widget _buildSettingsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double total = _tracks.fold<double>(
      0,
      (double sum, Track track) => sum + track.durationSecs,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '设置',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: SettingsView(
            trackCount: _tracks.length,
            totalDurationSecs: total,
            engineAvailable: _isAvailable,
            scanning: _scanning,
            folders: _folders,
            onAddFolder: _scanning ? null : () => unawaited(_addMusicFolder()),
            onRescanFolder: _scanning
                ? null
                : (String folder) => unawaited(_rescanFolder(folder)),
            onRemoveFolder: _scanning ? null : _removeFolder,
            scanFolder: _lastScanFolder,
            scanReport: _scanReport,
            scanError: _scanError,
            onRetry: _scanning || _lastScanFolder == null
                ? null
                : () => unawaited(_scanDirectory(_lastScanFolder!)),
          ),
        ),
      ],
    );
  }

  /* -------------------------------------------------------------- 历史 */

  Future<void> _loadHistory() async {
    if (_historyLoading) {
      return;
    }
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final List<Track> tracks = await _repository.loadRecentTracks(limit: 100);
      if (!mounted) {
        return;
      }
      setState(() {
        _historyTracks = tracks;
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _historyError = error;
        _historyLoading = false;
      });
    }
  }

  Future<void> _clearHistory() async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空播放历史？'),
        content: const Text('只清除播放记录，不会删除曲库里的音乐。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await _repository.clearHistory();
      if (!mounted) {
        return;
      }
      setState(() => _historyTracks = const <Track>[]);
      _showMessage('播放历史已清空');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('清空失败：${ErrorRetry.describe(error)}');
    }
  }

  Widget _buildHistorySection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '历史',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _historyTracks.isEmpty
                  ? null
                  : () => unawaited(_playAll(_historyTracks)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              onPressed: _historyTracks.isEmpty
                  ? null
                  : () => unawaited(_clearHistory()),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('清空历史'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_historyTracks.length} 条播放记录',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildHistoryBody(context)),
      ],
    );
  }

  Widget _buildHistoryBody(BuildContext context) {
    if (_historyLoading && _historyTracks.isEmpty) {
      return const LoadingState(message: '正在读取播放历史…');
    }
    if (_historyError != null) {
      return ErrorRetry(
        error: _historyError!,
        title: '播放历史读取失败',
        onRetry: () => unawaited(_loadHistory()),
      );
    }
    if (_historyTracks.isEmpty) {
      return EmptyState(
        icon: Icons.history,
        title: '还没有播放记录',
        message: '播放过的曲目会按最近播放排在这里，方便接着上次继续听。',
        action: FilledButton.tonal(
          onPressed: () => _selectSection(LibrarySection.music),
          child: const Text('去曲库看看'),
        ),
      );
    }
    return TrackListView(
      tracks: _historyTracks,
      storageKey: const PageStorageKey<String>('tracks:history'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_historyTracks, track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_historyTracks, track, action),
    );
  }

  /* -------------------------------------------------------------- 收藏 */

  Future<void> _refreshFavoritePaths() async {
    try {
      final Set<String> paths = await _repository.loadFavoritePaths();
      if (!mounted) {
        return;
      }
      setState(() => _favoritePaths = paths);
    } catch (error) {
      debugPrint('读取收藏状态失败：$error');
    }
  }

  Future<void> _loadFavorites() async {
    if (_favoritesLoading) {
      return;
    }
    setState(() {
      _favoritesLoading = true;
      _favoritesError = null;
    });
    try {
      final List<Track> tracks = await _repository.loadFavorites();
      if (!mounted) {
        return;
      }
      setState(() {
        _favoriteTracks = tracks;
        _favoritePaths = tracks.map((Track track) => track.path).toSet();
        _favoritesLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _favoritesError = error;
        _favoritesLoading = false;
      });
    }
  }

  Future<void> _toggleFavorite(Track track) async {
    final bool next = !_favoritePaths.contains(track.path);
    final Set<String> previousPaths = Set<String>.of(_favoritePaths);
    final List<Track> previousTracks = _favoriteTracks;

    setState(() {
      if (next) {
        _favoritePaths.add(track.path);
        _favoriteTracks = <Track>[
          track,
          ..._favoriteTracks.where((Track item) => item.path != track.path),
        ];
      } else {
        _favoritePaths.remove(track.path);
        _favoriteTracks = _favoriteTracks
            .where((Track item) => item.path != track.path)
            .toList();
      }
    });

    try {
      await _repository.setFavorite(track.path, next);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _favoritePaths = previousPaths;
        _favoriteTracks = previousTracks;
      });
      _showMessage('${next ? '收藏' : '取消收藏'}失败：${ErrorRetry.describe(error)}');
    }
  }

  Widget _buildFavoritesSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '收藏',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _favoriteTracks.isEmpty
                  ? null
                  : () => unawaited(_playAll(_favoriteTracks)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_favoriteTracks.length} 首收藏',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildFavoritesBody(context)),
      ],
    );
  }

  Widget _buildFavoritesBody(BuildContext context) {
    if (_favoritesLoading && _favoriteTracks.isEmpty) {
      return const LoadingState(message: '正在读取收藏…');
    }
    if (_favoritesError != null) {
      return ErrorRetry(
        error: _favoritesError!,
        title: '收藏读取失败',
        onRetry: () => unawaited(_loadFavorites()),
      );
    }
    if (_favoriteTracks.isEmpty) {
      return EmptyState(
        icon: Icons.favorite_border,
        title: '还没有收藏',
        message: '在曲目右侧点一下爱心，喜欢的歌就会出现在这里。',
        action: FilledButton.tonal(
          onPressed: () => _selectSection(LibrarySection.music),
          child: const Text('去曲库看看'),
        ),
      );
    }
    return TrackListView(
      tracks: _favoriteTracks,
      storageKey: const PageStorageKey<String>('tracks:favorites'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_favoriteTracks, track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_favoriteTracks, track, action),
    );
  }

  /* -------------------------------------------------------------- 歌单 */

  Playlist? get _selectedPlaylist {
    final int? id = _selectedPlaylistId;
    if (id == null) {
      return null;
    }
    for (final Playlist playlist in _playlists) {
      if (playlist.id.toInt() == id) {
        return playlist;
      }
    }
    return null;
  }

  Future<void> _loadPlaylists() async {
    if (_playlistsLoading) {
      return;
    }
    setState(() {
      _playlistsLoading = true;
      _playlistsError = null;
    });
    try {
      final List<Playlist> playlists = await _repository.loadPlaylists();
      if (!mounted) {
        return;
      }
      setState(() {
        _playlists = playlists;
        _playlistsLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _playlistsError = error;
        _playlistsLoading = false;
      });
    }
  }

  Future<void> _loadPlaylistTracks(int id) async {
    setState(() {
      _playlistTracksLoading = true;
      _playlistTracksError = null;
    });
    try {
      final List<Track> tracks = await _repository.loadPlaylistTracks(id);
      if (!mounted || _selectedPlaylistId != id) {
        return;
      }
      setState(() {
        _playlistTracks = tracks;
        _playlistTracksLoading = false;
      });
    } catch (error) {
      if (!mounted || _selectedPlaylistId != id) {
        return;
      }
      setState(() {
        _playlistTracksError = error;
        _playlistTracksLoading = false;
      });
    }
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    final int id = playlist.id.toInt();
    setState(() {
      _selectedPlaylistId = id;
      _playlistTracks = const <Track>[];
      _playlistTracksLoading = true;
      _playlistTracksError = null;
    });
    await _loadPlaylistTracks(id);
  }

  String? _validatePlaylistName(String name, {int? exceptId}) {
    if (name.isEmpty) {
      return '歌单名不能为空';
    }
    final String lower = name.toLowerCase();
    final bool taken = _playlists.any(
      (Playlist playlist) =>
          playlist.id.toInt() != exceptId &&
          playlist.name.toLowerCase() == lower,
    );
    return taken ? '已有同名歌单' : null;
  }

  Future<void> _createPlaylist({String? addTrackPath}) async {
    final String? name = await showPlaylistNameDialog(
      context,
      title: '新建歌单',
      confirmText: '创建',
      validate: (String value) => _validatePlaylistName(value),
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      final Playlist playlist = await _repository.createPlaylist(name);
      bool added = false;
      String? addError;
      if (addTrackPath != null) {
        try {
          added = await _repository.addTrackToPlaylist(
            playlist.id.toInt(),
            addTrackPath,
          );
        } catch (error) {
          addError = ErrorRetry.describe(error);
        }
      }
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      if (addError != null) {
        _showMessage('已创建「$name」，但加入曲目失败：$addError');
      } else if (added) {
        _showMessage('已创建「$name」并加入 1 首');
      } else {
        _showMessage('已创建「$name」');
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('创建失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 把单曲加入歌单：先选已有歌单，也可以现场新建。
  ///
  /// 歌单列表只在进入歌单分区时加载，右键菜单在音乐分区也可能用到，
  /// 所以这里先取一次，避免对话框显示“还没有歌单”而让用户重复新建。
  Future<void> _addToPlaylist(Track track) async {
    await _loadPlaylists();
    if (!mounted) {
      return;
    }
    final PlaylistPick? pick = await showPlaylistPickerDialog(
      context,
      playlists: _playlists,
    );
    if (pick == null || !mounted) {
      return;
    }
    switch (pick) {
      case PickNewPlaylist():
        await _createPlaylist(addTrackPath: track.path);
      case PickExistingPlaylist(:final Playlist playlist):
        final int id = playlist.id.toInt();
        final String name = playlist.name;
        try {
          final bool added = await _repository.addTrackToPlaylist(
            id,
            track.path,
          );
          await _loadPlaylists();
          if (!mounted) {
            return;
          }
          _showMessage(added ? '已加入「$name」' : '「$name」里已经有这首');
        } catch (error) {
          if (!mounted) {
            return;
          }
          _showMessage('加入歌单失败：${ErrorRetry.describe(error)}');
        }
    }
  }

  Future<void> _renamePlaylist(Playlist playlist) async {
    final int id = playlist.id.toInt();
    final String? name = await showPlaylistNameDialog(
      context,
      title: '重命名歌单',
      confirmText: '保存',
      initialName: playlist.name,
      validate: (String value) => _validatePlaylistName(value, exceptId: id),
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      await _repository.renamePlaylist(id, name);
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage('已重命名为「$name」');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('重命名失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('删除「${playlist.name}」？'),
        content: Text('歌单里的 ${playlist.trackCount} 首不会被删除，只是不再属于这个歌单。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除歌单'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await _repository.deletePlaylist(playlist.id.toInt());
      if (!mounted) {
        return;
      }
      if (_selectedPlaylistId == playlist.id.toInt()) {
        setState(() => _selectedPlaylistId = null);
      }
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage('已删除「${playlist.name}」');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('删除失败：${ErrorRetry.describe(error)}');
    }
  }

  Future<void> _addTracksToPlaylist(Playlist playlist) async {
    final int id = playlist.id.toInt();
    final Set<String> existing = _playlistTracks
        .map((Track track) => track.path)
        .toSet();
    final int? added = await showAddTracksDialog(
      context,
      playlistName: playlist.name,
      tracks: _tracks,
      existingPaths: existing,
      onAdd: (String path) => _repository.addTrackToPlaylist(id, path),
    );
    if (added == null || added == 0 || !mounted) {
      return;
    }
    await _loadPlaylistTracks(id);
    await _loadPlaylists();
    if (!mounted) {
      return;
    }
    _showMessage('已添加 $added 首到「${playlist.name}」');
  }

  Future<void> _removeTrackFromPlaylist(Track track) async {
    final int? id = _selectedPlaylistId;
    if (id == null) {
      return;
    }
    try {
      await _repository.removeTrackFromPlaylist(id, track.path);
      if (!mounted) {
        return;
      }
      setState(() {
        _playlistTracks = _playlistTracks
            .where((Track item) => item.path != track.path)
            .toList();
      });
      await _loadPlaylists();
      if (!mounted) {
        return;
      }
      _showMessage('已从歌单移除「${track.title}」');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('移除失败：${ErrorRetry.describe(error)}');
    }
  }

  Widget _buildPlaylistsSection(BuildContext context) {
    final Playlist? selected = _selectedPlaylist;
    if (selected != null) {
      return _buildPlaylistDetail(context, selected);
    }

    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '歌单',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => unawaited(_createPlaylist()),
              icon: const Icon(Icons.add),
              label: const Text('新建歌单'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_playlists.length} 个歌单',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildPlaylistsBody(context)),
      ],
    );
  }

  Widget _buildPlaylistsBody(BuildContext context) {
    if (_playlistsLoading) {
      return const LoadingState(message: '正在读取歌单…');
    }
    if (_playlistsError != null) {
      return ErrorRetry(
        error: _playlistsError!,
        title: '歌单读取失败',
        onRetry: () => unawaited(_loadPlaylists()),
      );
    }
    if (_playlists.isEmpty) {
      return EmptyState(
        icon: Icons.queue_music,
        title: '还没有歌单',
        message: '把常听的曲目收进歌单，之后就不用再翻整个曲库。',
        action: FilledButton.icon(
          onPressed: () => unawaited(_createPlaylist()),
          icon: const Icon(Icons.add),
          label: const Text('新建歌单'),
        ),
      );
    }
    return PlaylistGridView(
      playlists: _playlists,
      storageKey: const PageStorageKey<String>('grid:playlists'),
      onOpen: (Playlist playlist) => unawaited(_openPlaylist(playlist)),
      onAction: (Playlist playlist, PlaylistAction action) {
        switch (action) {
          case PlaylistAction.rename:
            unawaited(_renamePlaylist(playlist));
          case PlaylistAction.delete:
            unawaited(_deletePlaylist(playlist));
        }
      },
    );
  }

  Widget _buildPlaylistDetail(BuildContext context, Playlist playlist) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailBar(
          label: '歌单',
          onBack: () => setState(() => _selectedPlaylistId = null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Icon(
                  Icons.queue_music,
                  size: 48,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${playlist.trackCount} 首 · 更新于 '
                      '${formatPlaylistUpdated(playlist.updatedAt)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: _playlistTracks.isEmpty
                              ? null
                              : () => unawaited(_playAll(_playlistTracks)),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放全部'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              unawaited(_addTracksToPlaylist(playlist)),
                          icon: const Icon(Icons.add),
                          label: const Text('添加音乐'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_renamePlaylist(playlist)),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('重命名'),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.error,
                          ),
                          onPressed: () => unawaited(_deletePlaylist(playlist)),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除歌单'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildPlaylistTracksBody(context, playlist)),
      ],
    );
  }

  Widget _buildPlaylistTracksBody(BuildContext context, Playlist playlist) {
    if (_playlistTracksLoading && _playlistTracks.isEmpty) {
      return const LoadingState(message: '正在读取歌单…');
    }
    if (_playlistTracksError != null) {
      return ErrorRetry(
        error: _playlistTracksError!,
        title: '歌单读取失败',
        onRetry: () => unawaited(_loadPlaylistTracks(playlist.id.toInt())),
      );
    }
    if (_playlistTracks.isEmpty) {
      return EmptyState(
        icon: Icons.playlist_add,
        title: '歌单还是空的',
        message: '从曲库里挑几首加进来，之后就能在这里直接播放。',
        action: FilledButton.icon(
          onPressed: () => unawaited(_addTracksToPlaylist(playlist)),
          icon: const Icon(Icons.add),
          label: const Text('添加音乐'),
        ),
      );
    }
    return TrackListView(
      tracks: _playlistTracks,
      storageKey: PageStorageKey<String>('tracks:playlist:${playlist.id}'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_playlistTracks, track)),
      onRemove: (Track track) => unawaited(_removeTrackFromPlaylist(track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_playlistTracks, track, action),
    );
  }

  Widget _buildMusicSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Track> visible = _query.isEmpty
        ? _tracks
        : (_results ?? const <Track>[]);
    final String countLabel = _query.isEmpty
        ? '${_tracks.length} 首音乐'
        : (_searching ? '正在搜索…' : '找到 ${visible.length} 首');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '音乐',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: visible.isEmpty || _searching
                  ? null
                  : () => unawaited(_playAll(visible)),
              icon: const Icon(Icons.play_arrow),
              label: Text(_query.isEmpty ? '播放全部' : '播放结果'),
            ),
            const SizedBox(width: 8),
            _SortButton(mode: _sort, onSelected: _changeSort),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          countLabel,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
        if (_scanning)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _lastScanFolder == null
                        ? '正在扫描…'
                        : '正在扫描 ${_lastScanFolder!}…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Expanded(child: _buildMusicBody(context)),
      ],
    );
  }

  Widget _buildMusicBody(BuildContext context) {
    if (_loading) {
      return const LoadingState(message: '正在读取曲库…');
    }
    if (_error != null) {
      return ErrorRetry(
        error: _error!,
        title: '曲库读取失败',
        onRetry: () => unawaited(_loadTracks()),
      );
    }
    if (_query.isNotEmpty) {
      if (_searchError != null) {
        return ErrorRetry(
          error: _searchError!,
          title: '搜索失败',
          onRetry: () => unawaited(_runSearch(_query)),
        );
      }
      if (_results == null) {
        return const LoadingState(message: '正在搜索…');
      }
      if (_results!.isEmpty) {
        if (_searching) {
          return const LoadingState(message: '正在搜索…');
        }
        return EmptyState(
          icon: Icons.search_off,
          title: '没有找到匹配的音乐',
          message: '没有标题、艺术家或专辑包含「$_query」的曲目。换个关键词试试。',
          action: TextButton(
            onPressed: _clearSearch,
            child: const Text('清除搜索'),
          ),
        );
      }
      return TrackListView(
        tracks: _results!,
        storageKey: const PageStorageKey<String>('tracks:search'),
        playingPath: _currentTrack?.path,
        onPlay: (Track track) => unawaited(_playFrom(_results!, track)),
        favoritePaths: _favoritePaths,
        onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
        onContextAction: (Track track, TrackContextAction action) =>
            _onTrackContext(_results!, track, action),
      );
    }
    if (_tracks.isEmpty) {
      return EmptyState(
        icon: Icons.library_music_outlined,
        title: '曲库还是空的',
        message: '选择包含音乐的文件夹，扫描后曲目会自动出现在这里；也可以把文件夹直接拖进窗口。',
        action: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _scanning ? null : () => unawaited(_addMusicFolder()),
              icon: _scanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.create_new_folder_outlined),
              label: Text(_scanning ? '正在扫描…' : '添加音乐目录'),
            ),
            OutlinedButton.icon(
              onPressed: _scanning ? null : () => unawaited(_loadTracks()),
              icon: const Icon(Icons.refresh),
              label: const Text('重新读取'),
            ),
          ],
        ),
      );
    }
    return TrackListView(
      tracks: _tracks,
      storageKey: const PageStorageKey<String>('tracks:music'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_tracks, track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_tracks, track, action),
    );
  }

  Widget _buildArtistsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<ArtistGroup> groups = _artistGroupsCache;

    if (_selectedArtist != null) {
      ArtistGroup? group;
      for (final ArtistGroup candidate in groups) {
        if (candidate.name == _selectedArtist) {
          group = candidate;
          break;
        }
      }
      if (group != null) {
        return _buildArtistDetail(context, group);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '艺术家',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${groups.length} 位艺术家',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _buildCollectionBody(context, groups.isEmpty, () {
            return ArtistGridView(
              artists: groups,
              storageKey: const PageStorageKey<String>('grid:artists'),
              onSelect: (ArtistGroup artist) =>
                  setState(() => _selectedArtist = artist.name),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildArtistDetail(BuildContext context, ArtistGroup group) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailBar(
          label: '艺术家',
          onBack: () => setState(() => _selectedArtist = null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: <Widget>[
              Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primaryContainer,
                ),
                alignment: Alignment.center,
                child: Text(
                  initialsOf(group.name),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${group.albumCount} 张专辑 · ${group.trackCount} 首音乐',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: () => unawaited(_playAll(group.tracks)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TrackListView(
            tracks: group.tracks,
            storageKey: PageStorageKey<String>('tracks:artist:${group.name}'),
            playingPath: _currentTrack?.path,
            onPlay: (Track track) => unawaited(_playFrom(group.tracks, track)),
            favoritePaths: _favoritePaths,
            onToggleFavorite: (Track track) =>
                unawaited(_toggleFavorite(track)),
            onContextAction: (Track track, TrackContextAction action) =>
                _onTrackContext(group.tracks, track, action),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<AlbumGroup> groups = _albumGroupsCache;

    if (_selectedAlbumKey != null) {
      AlbumGroup? group;
      for (final AlbumGroup candidate in groups) {
        if (candidate.key == _selectedAlbumKey) {
          group = candidate;
          break;
        }
      }
      if (group != null) {
        return _buildAlbumDetail(context, group);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '专辑',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${groups.length} 张专辑',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _buildCollectionBody(context, groups.isEmpty, () {
            return AlbumGridView(
              albums: groups,
              storageKey: const PageStorageKey<String>('grid:albums'),
              onSelect: (AlbumGroup album) =>
                  setState(() => _selectedAlbumKey = album.key),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildAlbumDetail(BuildContext context, AlbumGroup group) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailBar(
          label: '专辑',
          onBack: () => setState(() => _selectedAlbumKey = null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: <Widget>[
              Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Icon(
                  Icons.album,
                  size: 48,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${group.artist} · ${group.tracks.length} 首 · '
                      '${formatDuration(group.durationSecs)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: () => unawaited(_playAll(group.tracks)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TrackListView(
            tracks: group.tracks,
            storageKey: PageStorageKey<String>('tracks:album:${group.key}'),
            playingPath: _currentTrack?.path,
            onPlay: (Track track) => unawaited(_playFrom(group.tracks, track)),
            favoritePaths: _favoritePaths,
            onToggleFavorite: (Track track) =>
                unawaited(_toggleFavorite(track)),
            onContextAction: (Track track, TrackContextAction action) =>
                _onTrackContext(group.tracks, track, action),
          ),
        ),
      ],
    );
  }

  /// 艺术家 / 专辑共用的加载、错误、空态分支
  Widget _buildCollectionBody(
    BuildContext context,
    bool isEmpty,
    Widget Function() builder,
  ) {
    if (_loading) {
      return const LoadingState(message: '正在读取曲库…');
    }
    if (_error != null) {
      return ErrorRetry(
        error: _error!,
        title: '曲库读取失败',
        onRetry: () => unawaited(_loadTracks()),
      );
    }
    if (isEmpty) {
      return EmptyState(
        icon: Icons.library_music_outlined,
        title: '还没有可展示的内容',
        message: '曲库里还没有曲目，导入之后这里会自动聚合。',
        action: OutlinedButton.icon(
          onPressed: () => unawaited(_loadTracks()),
          icon: const Icon(Icons.refresh),
          label: const Text('重新读取'),
        ),
      );
    }
    return builder();
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

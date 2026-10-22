import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../common/common.dart';
import '../../rust/api/model.dart';
import '../../rust/api/player.dart' as rust;
import '../../rust/api/scan.dart' as scan;
import '../player/playback_service.dart';
import '../player/player_bar.dart';
import '../settings/settings_view.dart';
import 'library_repository.dart';
import 'library_sort.dart';
import 'widgets/collection_grids.dart';
import 'widgets/library_rail.dart';
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
  });

  /// 曲库数据源；不传则走 Rust。
  final LibraryRepository? repository;

  /// 播放能力；不传则走 Rust / BASS。
  final PlaybackService? playbackService;

  /// 选择音乐目录；不传则打开系统目录选择框。
  final DirectoryPicker? directoryPicker;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const Duration _searchDebounce = Duration(milliseconds: 300);
  static const Duration _pollInterval = Duration(milliseconds: 500);

  late final LibraryRepository _repository =
      widget.repository ?? const RustLibraryRepository();
  late final PlaybackService _playback =
      widget.playbackService ?? const RustPlaybackService();

  final TextEditingController _searchController = TextEditingController();

  Timer? _debounce;
  Timer? _positionTimer;
  int _searchToken = 0;
  bool _ticking = false;

  LibrarySection _section = LibrarySection.music;
  bool _railExpanded = true;
  LibrarySort _sort = LibrarySort.library;

  List<Track> _tracks = const <Track>[];
  List<Track>? _results;
  String _query = '';
  bool _loading = true;
  bool _searching = false;
  bool _scanning = false;
  String? _lastScanFolder;
  scan.ScanReport? _scanReport;
  Object? _scanError;
  Object? _error;
  Object? _searchError;

  String? _selectedArtist;
  String? _selectedAlbumKey;

  Track? _currentTrack;
  bool _isPlaying = false;
  bool _isAvailable = false;
  bool _seeking = false;
  double _position = 0;
  double _duration = 0;
  double _volume = 1;
  double _lastVolume = 1;
  bool _engineNoticeShown = false;

  @override
  void initState() {
    super.initState();
    _isAvailable = _readAvailability();
    unawaited(_loadTracks());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _positionTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _readAvailability() {
    try {
      return _playback.isAvailable;
    } catch (_) {
      return false;
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

    await _scanDirectory(folder.trim());
  }

  /// 扫描指定目录；设置页展示结果，空曲库时用 SnackBar 提示。
  Future<void> _scanDirectory(String folder) async {
    if (_scanning) {
      return;
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
        return;
      }
      setState(() {
        _scanning = false;
        _scanReport = report;
      });
      if (_section != LibrarySection.settings) {
        _showMessage(
          '扫描完成：更新 ${report.upserted} 首，失败 ${report.failed} 首，'
          '清理 ${report.pruned} 首',
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanning = false;
        _scanError = error;
      });
      if (_section != LibrarySection.settings) {
        _showMessage('扫描失败：${ErrorRetry.describe(error)}');
      }
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
  }

  /* ---------------------------------------------------------------- 播放 */

  Future<void> _playTrack(Track track) async {
    setState(() {
      _currentTrack = track;
      _position = 0;
      _duration = track.durationSecs;
    });
    if (!_isAvailable) {
      _showEngineNotice();
      return;
    }
    try {
      await _playback.play(track.path);
      if (!mounted) {
        return;
      }
      setState(() => _isPlaying = true);
      _startPositionPolling();
      unawaited(_recordPlay(track.path));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isPlaying = false);
      _showMessage('播放失败：${ErrorRetry.describe(error)}');
    }
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
        await _playTrack(_currentTrack!);
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
      if (_isPlaying) {
        _startPositionPolling();
      } else {
        _stopPositionPolling();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('操作失败：${ErrorRetry.describe(error)}');
    }
  }

  /// 拖动进度时停掉轮询，否则下一次 tick 会把滑块拉回原位置。
  void _onSeekStart(double _) {
    _seeking = true;
    _stopPositionPolling();
  }

  void _onSeekChanged(double seconds) {
    setState(() => _position = seconds);
  }

  Future<void> _onSeekEnd(double seconds) async {
    _seeking = false;
    if (_isAvailable) {
      try {
        await _playback.seek(seconds);
        if (!mounted) {
          return;
        }
        setState(() => _position = seconds);
      } catch (error) {
        if (!mounted) {
          return;
        }
        _showMessage('跳转失败：${ErrorRetry.describe(error)}');
      }
    }
    if (_isPlaying && _positionTimer == null) {
      _startPositionPolling();
    }
  }

  Future<void> _setVolume(double volume) async {
    final double next = volume.clamp(0.0, 1.0).toDouble();
    setState(() {
      if (next > 0) {
        _lastVolume = next;
      }
      _volume = next;
    });
    if (!_isAvailable) {
      return;
    }
    try {
      await _playback.setVolume(next);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('调节音量失败：${ErrorRetry.describe(error)}');
    }
  }

  void _toggleMute() {
    unawaited(
      _setVolume(_volume > 0 ? 0 : (_lastVolume > 0 ? _lastVolume : 1)),
    );
  }

  void _startPositionPolling() {
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
      if (!mounted || _seeking) {
        return;
      }
      setState(() {
        _position = position;
        if (duration > 0) {
          _duration = duration;
        }
        _isPlaying = state == rust.PlaybackState.playing;
      });
      if (state == rust.PlaybackState.stopped) {
        _stopPositionPolling();
      }
    } catch (_) {
      _stopPositionPolling();
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

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      body: Row(
        children: <Widget>[
          LibraryRail(
            expanded: _railExpanded,
            section: _section,
            onSelect: _selectSection,
            onToggle: () => setState(() => _railExpanded = !_railExpanded),
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                _buildTopBar(context),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: _buildSection(context),
                  ),
                ),
                PlayerBar(
                  track: _currentTrack,
                  isPlaying: _isPlaying,
                  isAvailable: _isAvailable,
                  position: _position,
                  duration: _duration,
                  volume: _volume,
                  onPlayPause: () => unawaited(_togglePlayback()),
                  onSeekStart: _onSeekStart,
                  onSeekChanged: _onSeekChanged,
                  onSeekEnd: (double seconds) => unawaited(_onSeekEnd(seconds)),
                  onVolumeChanged: (double value) =>
                      unawaited(_setVolume(value)),
                  onToggleMute: _toggleMute,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            'Lamp',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 20),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SizedBox(height: 56, child: _buildSearchField(context)),
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
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    );

    return TextField(
      controller: _searchController,
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
      return;
    }
    setState(() {
      _section = section;
      _selectedArtist = null;
      _selectedAlbumKey = null;
    });
  }

  Widget _buildSection(BuildContext context) {
    return switch (_section) {
      LibrarySection.music => _buildMusicSection(context),
      LibrarySection.playlists => _buildComingSoon(
        context,
        section: LibrarySection.playlists,
        message:
            '歌单存储接口已就绪，页面尚未接入。接入后会支持新建、重命名，'
            '以及往歌单里增删曲目。',
      ),
      LibrarySection.history => _buildComingSoon(
        context,
        section: LibrarySection.history,
        message: '播放记录已在后台保存，历史页面尚未接入；接入后会按最近播放展示。',
      ),
      LibrarySection.favorites => _buildComingSoon(
        context,
        section: LibrarySection.favorites,
        message:
            '收藏存储接口已就绪，页面尚未接入。当前不会做只存在内存里的收藏，'
            '避免重启后凭空消失。',
      ),
      LibrarySection.artists => _buildArtistsSection(context),
      LibrarySection.albums => _buildAlbumsSection(context),
      LibrarySection.settings => _buildSettingsSection(context),
    };
  }

  Widget _buildComingSoon(
    BuildContext context, {
    required LibrarySection section,
    required String message,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              section.label,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '待接入',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '依赖曲库存储接口',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: EmptyState(
            icon: section.icon,
            title: '${section.label}还没有接入',
            message: message,
          ),
        ),
      ],
    );
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
            onAddFolder: _scanning ? null : () => unawaited(_addMusicFolder()),
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
        playingPath: _currentTrack?.path,
        onPlay: (Track track) => unawaited(_playTrack(track)),
      );
    }
    if (_tracks.isEmpty) {
      return EmptyState(
        icon: Icons.library_music_outlined,
        title: '曲库还是空的',
        message: '选择包含音乐的文件夹，扫描后曲目会自动出现在这里。',
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
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playTrack(track)),
    );
  }

  Widget _buildArtistsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<ArtistGroup> groups = groupTracksByArtist(_tracks);

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
            playingPath: _currentTrack?.path,
            onPlay: (Track track) => unawaited(_playTrack(track)),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<AlbumGroup> groups = groupTracksByAlbum(_tracks);

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
            playingPath: _currentTrack?.path,
            onPlay: (Track track) => unawaited(_playTrack(track)),
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

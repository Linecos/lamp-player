part of '../library_page.dart';

/// 收藏分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _FavoritesSection on _LibraryPageState {
  /* -------------------------------------------------------------- 收藏 */

  Future<void> _refreshFavoritePaths() async {
    try {
      final Set<String> paths = await _repository.loadFavoritePaths();
      if (!mounted) {
        return;
      }
      _update(() => _favoritePaths = paths);
    } catch (error) {
      debugPrint('读取收藏状态失败：$error');
    }
  }

  Future<void> _loadFavorites() async {
    if (_favoritesLoading) {
      return;
    }
    _update(() {
      _favoritesLoading = true;
      _favoritesError = null;
    });
    try {
      final List<Track> tracks = await _repository.loadFavorites();
      if (!mounted) {
        return;
      }
      _update(() {
        _favoriteTracks = tracks;
        _favoritePaths = tracks.map((Track track) => track.path).toSet();
        _favoritesLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() {
        _favoritesError = error;
        _favoritesLoading = false;
      });
    }
  }

  Future<void> _toggleFavorite(Track track) async {
    final bool next = !_favoritePaths.contains(track.path);
    final Set<String> previousPaths = Set<String>.of(_favoritePaths);
    final List<Track> previousTracks = _favoriteTracks;

    _update(() {
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
      _update(() {
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
      selectionMode: _selectionMode,
      selectedPaths: _selectedPaths,
      onSelect: (Track track, {required bool toggle, required bool range}) =>
          _onTrackSelect(_favoriteTracks, track, toggle: toggle, range: range),
    );
  }
}

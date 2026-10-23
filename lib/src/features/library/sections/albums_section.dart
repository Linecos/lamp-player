part of '../library_page.dart';

/// 专辑分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _AlbumsSection on _LibraryPageState {
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
                  _update(() => _selectedAlbumKey = album.key),
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
          onBack: () => _update(() => _selectedAlbumKey = null),
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

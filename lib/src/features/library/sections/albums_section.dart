part of '../library_page.dart';

/// 专辑分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _AlbumsSection on _LibraryPageState {
  Widget _buildAlbumsSection(BuildContext context) {
    AlbumGroup? selected;
    final String? key = _selectedAlbumKey;
    if (key != null) {
      for (final AlbumGroup candidate in _albumGroupsCache) {
        if (candidate.key == key) {
          selected = candidate;
          break;
        }
      }
    }

    // 列表 ↔ 详情之间做个淡入上滑，和歌单、设置进听歌统计同款：只动不透明度
    // 与位移，两份子树各自 RepaintBoundary，不会每帧重画。切换的 180ms 里两份
    // 共存，结束后仍然只有一份。
    //
    // key 带分区世代：从别的分区切回来时换一个新的，免得它记着切走前的详情
    // 再淡出 180ms（那一层已经没意义，还会看着像「先跳回旧页面」）。
    return AnimatedSwitcher(
      key: ValueKey<String>(
        'albums-epoch-${_sectionEpochs[LibrarySection.albums] ?? 0}',
      ),
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previous, ?current],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            // 位移只给 1.5%（约 10px）：淡入一点点上浮就够，别做成整页平移
            position: Tween<Offset>(
              begin: const Offset(0, 0.015),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      // key 一变才会触发过渡：列表与每张专辑详情各用一个 key
      child: selected == null
          ? KeyedSubtree(
              key: const ValueKey<String>('albums-list'),
              child: RepaintBoundary(child: _buildAlbumsList(context)),
            )
          : KeyedSubtree(
              key: ValueKey<String>('albums-detail-${selected.key}'),
              child: RepaintBoundary(
                child: _buildAlbumDetail(context, selected),
              ),
            ),
    );
  }

  Widget _buildAlbumsList(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<AlbumGroup> all = _albumGroupsCache;

    final List<AlbumGroup> groups = _filterAlbums(all);

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
          _query.isEmpty ? '${all.length} 张专辑' : '找到 ${groups.length} 张专辑',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: groups.isEmpty && _query.isNotEmpty
              ? _searchEmptyState('没有找到匹配的专辑')
              : _buildCollectionBody(context, groups.isEmpty, () {
                  return AlbumGridView(
                    albums: groups,
                    storageKey: const PageStorageKey<String>('grid:albums'),
                    onSelect: (AlbumGroup album) {
                      _clearSearch();
                      _clearSelection();
                      _update(() => _selectedAlbumKey = album.key);
                    },
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
          onBack: () {
            _clearSelection();
            _update(() => _selectedAlbumKey = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(
            left: _detailHeaderInset,
            top: 8,
            bottom: 8,
          ),
          child: Row(
            children: <Widget>[
              AlbumCover(
                path: group.coverPath,
                size: detailCoverSize,
                radius: 32,
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
                      style: _headerButtonStyle(),
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
            selectionMode: _selectionMode,
            onSelectAll: _selectionMode ? _toggleSelectAll : null,
            selectionAllFavored: _selectionAllFavored,
            selectedPaths: _selectedPaths,
            onSelect:
                (Track track, {required bool toggle, required bool range}) =>
                    _onTrackSelect(
                      group.tracks,
                      track,
                      toggle: toggle,
                      range: range,
                    ),
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

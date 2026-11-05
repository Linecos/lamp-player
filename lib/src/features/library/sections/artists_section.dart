part of '../library_page.dart';

/// 艺术家分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _ArtistsSection on _LibraryPageState {
  Widget _buildArtistsSection(BuildContext context) {
    ArtistGroup? selected;
    final String? name = _selectedArtist;
    if (name != null) {
      for (final ArtistGroup candidate in _artistGroupsCache) {
        if (candidate.name == name) {
          selected = candidate;
          break;
        }
      }
    }

    // 列表 ↔ 详情之间做个淡入上滑，和歌单、专辑、设置进听歌统计同款：只动
    // 不透明度与位移，两份子树各自 RepaintBoundary，不会每帧重画。
    //
    // key 带分区世代：从别的分区切回来时换一个新的，免得它记着切走前的详情
    // 再淡出 180ms（那一层已经没意义，还会看着像「先跳回旧页面」）。
    return AnimatedSwitcher(
      key: ValueKey<String>(
        'artists-epoch-${_sectionEpochs[LibrarySection.artists] ?? 0}',
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
      // key 一变才会触发过渡：列表与每位艺术家详情各用一个 key
      child: selected == null
          ? KeyedSubtree(
              key: const ValueKey<String>('artists-list'),
              child: RepaintBoundary(child: _buildArtistsList(context)),
            )
          : KeyedSubtree(
              key: ValueKey<String>('artists-detail-${selected.name}'),
              child: RepaintBoundary(
                child: _buildArtistDetail(context, selected),
              ),
            ),
    );
  }

  Widget _buildArtistsList(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<ArtistGroup> all = _artistGroupsCache;

    final List<ArtistGroup> groups = _filterArtists(all);

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
          _query.isEmpty ? '${all.length} 位艺术家' : '找到 ${groups.length} 位艺术家',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: groups.isEmpty && _query.isNotEmpty
              ? _searchEmptyState('没有找到匹配的艺术家')
              : _buildCollectionBody(context, groups.isEmpty, () {
                  return ArtistGridView(
                    artists: groups,
                    storageKey: const PageStorageKey<String>('grid:artists'),
                    onSelect: (ArtistGroup artist) {
                      _clearSearch();
                      _clearSelection();
                      _update(() => _selectedArtist = artist.name);
                    },
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
          onBack: () {
            _clearSelection();
            _update(() => _selectedArtist = null);
          },
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
                    if (_selectionMode)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _buildSelectionBar(context),
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
            storageKey: PageStorageKey<String>('tracks:artist:${group.name}'),
            playingPath: _currentTrack?.path,
            onPlay: (Track track) => unawaited(_playFrom(group.tracks, track)),
            favoritePaths: _favoritePaths,
            onToggleFavorite: (Track track) =>
                unawaited(_toggleFavorite(track)),
            onContextAction: (Track track, TrackContextAction action) =>
                _onTrackContext(group.tracks, track, action),
            selectionMode: _selectionMode,
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
}

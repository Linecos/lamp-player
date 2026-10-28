part of '../library_page.dart';

/// 艺术家分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _ArtistsSection on _LibraryPageState {
  Widget _buildArtistsSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<ArtistGroup> all = _artistGroupsCache;

    if (_selectedArtist != null) {
      ArtistGroup? group;
      for (final ArtistGroup candidate in all) {
        if (candidate.name == _selectedArtist) {
          group = candidate;
          break;
        }
      }
      if (group != null) {
        return _buildArtistDetail(context, group);
      }
    }

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

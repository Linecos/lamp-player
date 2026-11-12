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
                    // 侧栏动画期间列数保持不变（否则封面会先变大再变小）
                    columnWidthHint: _gridColumnWidth,
                    storageKey: const PageStorageKey<String>('grid:artists'),
                    // 带上卡片封面的矩形，详情页用它做「头像飞过去」的起点
                    onSelect: _openArtistDetail,
                    // 正在飞的那张卡片先藏着，落地再显形
                    flyingTag: _coverFlightTag,
                  );
                }),
        ),
      ],
    );
  }

  Widget _buildArtistDetail(BuildContext context, ArtistGroup group) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 展示 / 播放 / 多选共用这一份，排序后播放顺序与所见一致。
    // 先就地过滤再排序：详情页里的搜索框搜的是这位艺术家的歌。
    final List<Track> tracks = _sortDetailTracks(_filterTracks(group.tracks));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DetailBar(
          label: '艺术家',
          // 退回列表时让头像按原路飞回去
          onBack: _closeArtistDetail,
        ),
        Padding(
          padding: const EdgeInsets.only(
            left: _detailHeaderInset,
            top: 8,
            bottom: 8,
          ),
          child: Row(
            // 名字 / 统计 / 播放键贴住头像底边，见专辑详情的同一处注释
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              // 飞行期间先藏着，等列表那张飞到位再显形
              CoverFlightTarget(
                key: _artistDetailCoverKey,
                hidden: _coverFlightTag == artistCoverTag(group.name),
                child: artistAvatar(
                  context,
                  group.name,
                  detailCoverSize,
                  coverPath: group.coverPath,
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
                    Row(
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          style: _headerButtonStyle(),
                          onPressed: () => unawaited(_playAll(tracks)),
                          icon: const Icon(Icons.play_arrow),
                          // 搜着的时候放的是命中结果，不是这位艺术家的全部
                          label: Text(_query.isEmpty ? '播放全部' : '播放结果'),
                        ),
                        const SizedBox(width: 12),
                        _buildSelectionToggle(context),
                        const SizedBox(width: 12),
                        // 默认「原序」＝这位艺术家的原有顺序
                        _SortButton(
                          mode: _detailSort,
                          ascending: _detailAscending,
                          keySuffix: 'artist-detail',
                          onSelected: (LibrarySort? sort) {
                            if (sort != null) {
                              _changeDetailSort(sort);
                            }
                          },
                          onToggleDirection: _toggleDetailSortDirection,
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
        Expanded(
          child: tracks.isEmpty && _query.isNotEmpty
              ? _searchEmptyState('没有找到匹配的歌曲', scope: '这位艺术家名下')
              : TrackListView(
                  // 详情页也要能「定位正在播放」：控制器与高亮路径都跟列表分区共用同一套
                  controller: _artistScroll,
                  flashPath: _flashTrackPath,
                  tracks: tracks,
                  storageKey: PageStorageKey<String>(
                    'tracks:artist:${group.name}',
                  ),
                  playingPath: _currentTrack?.path,
                  onPlay: (Track track) => unawaited(_playFrom(tracks, track)),
                  favoritePaths: _favoritePaths,
                  onToggleFavorite: (Track track) =>
                      unawaited(_toggleFavorite(track)),
                  onContextAction: (Track track, TrackContextAction action) =>
                      _onTrackContext(tracks, track, action),
                  selectionMode: _selectionMode,
                  onSelectAll: _selectionMode ? _toggleSelectAll : null,
                  selectionAllFavored: _selectionAllFavored,
                  selectedPaths: _selectedPaths,
                  onSelect:
                      (
                        Track track, {
                        required bool toggle,
                        required bool range,
                      }) => _onTrackSelect(
                        tracks,
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

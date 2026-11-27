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

    // 列表 ↔ 详情之间做个淡入上滑，和歌单、音乐库同款：只动不透明度与位移，
    // 两份子树各自 RepaintBoundary，切换的 180ms 里两份共存，结束后仍只有一份。
    //
    // 不能用「换 key 让切换器重建」来清掉切走前的状态：分区切走再切回来时，
    // 重建刚好落在用户点开专辑详情那一帧，那样旧列表就不会参与过渡
    // （表现为「切回来第一次点击没有动画」）。清状态交给 [SubPageSwitcher.jumpToken]。
    return SubPageSwitcher(
      jumpToken: _sectionEpochs[LibrarySection.albums] ?? 0,
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
        const SizedBox(height: Spacing.xs),
        Expanded(
          child: groups.isEmpty && _query.isNotEmpty
              ? _searchEmptyState('没有找到匹配的专辑')
              : _buildCollectionBody(context, groups.isEmpty, () {
                  return AlbumGridView(
                    albums: groups,
                    storageKey: const PageStorageKey<String>('grid:albums'),
                    // 带上卡片封面的矩形，详情页用它做「封面飞过去」的起点
                    onSelect: _openAlbumDetail,
                    // 正在飞的那张卡片先藏着，落地再显形
                    flyingTag: _coverFlightTag,
                  );
                }),
        ),
      ],
    );
  }

  Widget _buildAlbumDetail(BuildContext context, AlbumGroup group) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 展示 / 播放 / 多选都用这一份：用户按标题排过序，播放顺序也要跟着，
    // 否则「播放全部」和眼睛看到的顺序对不上。
    //
    // 先就地过滤再排序：常驻搜索框在详情页里搜的就是这张专辑的歌，别再让用户
    // 退回曲库去搜（外面那层列的是专辑卡片，搜歌名根本命中不了）。
    final List<Track> tracks = _sortDetailTracks(_filterTracks(group.tracks));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Stack(
          // 背景要铺到内容区那 16 的左右内边距外面，所以不能裁剪
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: -_detailHeaderInset,
              right: -_detailHeaderInset,
              // 贴到分区内容区的顶部（那里还留着 12 的上内边距）
              top: -12,
              bottom: 0,
              child: CoverBackdrop(coverPath: group.coverPath),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _DetailBar(
                  label: '专辑',
                  // 退回列表时让封面按原路飞回去
                  onBack: _closeAlbumDetail,
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    left: _detailHeaderInset,
                    top: Spacing.xs,
                    bottom: Spacing.xs,
                  ),
                  child: Row(
                    // 文字与按钮贴住封面底边：封面撑到 240 之后，顶对齐会让右侧
                    // 上半截空着、三行信息像浮在半空
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // 点封面 → 打开封面编辑窗
                        onTap: () =>
                            unawaited(_openCoverEditorFor(album: group)),
                        child: CoverFlightTarget(
                          key: _albumDetailCoverKey,
                          hidden: _coverFlightTag == albumCoverTag(group.key),
                          child: AlbumCover(
                            path: group.coverPath,
                            size: detailCoverSize,
                            radius: albumDetailCoverRadius,
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.lg),
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
                            const SizedBox(height: Spacing.xs),
                            Text(
                              '${group.artist} · ${group.tracks.length} 首 · '
                              '${formatDuration(group.durationSecs)}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: Spacing.md),
                            Row(
                              children: <Widget>[
                                FilledButton.tonalIcon(
                                  style: _headerButtonStyle(),
                                  onPressed: () => unawaited(_playAll(tracks)),
                                  icon: const Icon(Icons.play_arrow),
                                  // 搜着的时候放的是命中结果，不是整张专辑
                                  label: Text(_query.isEmpty ? '播放全部' : '播放结果'),
                                ),
                                const SizedBox(width: Spacing.sm),
                                // 与其它功能按钮同行：多选原来在页面顶栏，
                                // 要跨半个屏幕去点
                                _buildSelectionToggle(context),
                                const SizedBox(width: Spacing.sm),
                                // 默认「原序」＝专辑曲序；想看别的排序再点开
                                _SortButton(
                                  mode: _detailSort,
                                  ascending: _detailAscending,
                                  keySuffix: 'album-detail',
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
              ],
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Expanded(
          child: tracks.isEmpty && _query.isNotEmpty
              ? _searchEmptyState('没有找到匹配的歌曲', scope: '这张专辑')
              : TrackListView(
                  // 同艺术家详情：定位要能落到这张专辑的列表上
                  controller: _albumScroll,
                  flashPath: _flashTrackPath,
                  tracks: tracks,
                  storageKey: PageStorageKey<String>(
                    'tracks:album:${group.key}',
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

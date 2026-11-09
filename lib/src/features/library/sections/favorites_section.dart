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

  /// 收藏 / 取消收藏（乐观更新，失败回滚）。
  ///
  /// 必须排队：快速双击会连着发出「加收藏」和「取消收藏」两个写库调用，
  /// 它们互不等待，先发的后到就让数据库终态和界面相反——界面显示没收藏、
  /// 重启后又变回收藏。排队后第二次点击会等第一次落库完再算 next，值才对。
  Future<void> _toggleFavorite(Track track) =>
      _favoriteChain.run(() => _toggleFavoriteNow(track), label: '收藏操作');

  Future<void> _toggleFavoriteNow(Track track) async {
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

  /// 按保存的自定义顺序铺开收藏；不在顺序表里的（刚收藏的）排最前
  List<Track> _applyFavoriteOrder(List<Track> tracks) {
    final List<String> order = _favoriteOrder;
    if (order.isEmpty) {
      return tracks;
    }
    final Map<String, Track> byPath = <String, Track>{
      for (final Track track in tracks) track.path: track,
    };
    final List<Track> ordered = <Track>[];
    for (final String path in order) {
      final Track? track = byPath.remove(path);
      if (track != null) {
        ordered.add(track);
      }
    }
    // 刚收藏的还没进顺序表：放在最前面，和「收藏先后 = 新的在前」一致
    ordered.insertAll(0, byPath.values);
    return ordered;
  }

  /// 收藏拖动排序：存成自定义顺序，并把排序切回「自定义」
  void _reorderFavorites(List<Track> visible, int from, int to) {
    final List<Track> base = _applyFavoriteOrder(_favoriteTracks);
    final List<Track> next = _manualOrderAfterDrag(visible, base, from, to);
    _update(() {
      _favoriteOrder = next.map((Track track) => track.path).toList();
      // 拖过之后看到的就是自定义顺序，排序按钮也跟着变
      _manualSort = null;
    });
    _saveSessionNow();
  }

  Widget _buildFavoritesSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 先按保存的自定义顺序铺开，再套当前排序；搜索词在最后过滤
    final List<Track> ordered = _applyFavoriteOrder(_favoriteTracks);
    final List<Track> visible = _sortManualTracks(_filterTracks(ordered));

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
            _buildSelectionHeaderSlot(context),
            FilledButton.tonalIcon(
              style: _headerButtonStyle(),
              onPressed: visible.isEmpty
                  ? null
                  : () => unawaited(_playAll(visible)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
            const SizedBox(width: 8),
            _buildSelectionToggle(context),
            const SizedBox(width: 8),
            // 排序放在多选右边：和歌曲页同一套控件，多一个「原序」（恢复收藏先后）
            _SortButton(
              mode: _manualSort,
              ascending: _manualAscending,
              allowManual: true,
              keySuffix: 'favorites',
              onSelected: _changeManualSort,
              onToggleDirection: _toggleManualSortDirection,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          _query.isEmpty
              ? '${_favoriteTracks.length} 首收藏'
              : '找到 ${visible.length} 首收藏',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildFavoritesBody(context, visible)),
      ],
    );
  }

  Widget _buildFavoritesBody(BuildContext context, List<Track> visible) {
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
    if (visible.isEmpty) {
      return _searchEmptyState('没有找到匹配的收藏');
    }
    return TrackListView(
      controller: _favoritesScroll,
      flashPath: _flashTrackPath,
      tracks: visible,
      storageKey: const PageStorageKey<String>('tracks:favorites'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(visible, track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(visible, track, action),
      selectionMode: _selectionMode,
      onSelectAll: _selectionMode ? _toggleSelectAll : null,
      selectionAllFavored: _selectionAllFavored,
      selectedPaths: _selectedPaths,
      onSelect: (Track track, {required bool toggle, required bool range}) =>
          _onTrackSelect(visible, track, toggle: toggle, range: range),
      // 搜索过滤时不给拖：这时候看到的是子集，拖出来的顺序没意义
      onReorder: _query.isEmpty
          ? (int from, int to) => _reorderFavorites(visible, from, to)
          : null,
    );
  }
}

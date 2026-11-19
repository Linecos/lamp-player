part of '../library_page.dart';

/// 某个音乐目录的曲目子页。
///
/// 与音质、听歌统计同一套「分区内切换」：点音乐库首页的目录行进来，
/// 侧栏与播放岛都不动；返回只换内容，不切分区。
extension _FolderDetailSection on _LibraryPageState {
  /// 这个目录里的全部曲目（不含搜索过滤）
  List<Track> get _folderDetailTracks {
    final String? folder = _folderDetail;
    if (folder == null) {
      return const <Track>[];
    }
    return _tracks
        .where((Track track) => trackInFolder(track.path, folder))
        .toList(growable: false);
  }

  Widget _buildFolderDetail(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String folder = _folderDetail!;
    final List<Track> all = _folderDetailTracks;
    final List<Track> list = _filterTracks(all);
    final bool searching = _query.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              key: const ValueKey<String>('folder-detail-back'),
              onPressed: () => _update(() => _folderDetail = null),
              tooltip: '返回音乐库',
              icon: const Icon(Icons.arrow_back),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                folder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _buildSelectionHeaderSlot(context),
            FilledButton.tonalIcon(
              style: _headerButtonStyle(),
              onPressed: list.isEmpty || _searching
                  ? null
                  : () => unawaited(_playAll(list)),
              icon: const Icon(Icons.play_arrow),
              label: Text(searching ? '播放结果' : '播放全部'),
            ),
            const SizedBox(width: 8),
            _buildSelectionToggle(context),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          searching ? '找到 ${list.length} 首' : '${all.length} 首',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: list.isEmpty
              ? EmptyState(
                  icon: searching
                      ? Icons.search_off
                      : Icons.folder_off_outlined,
                  title: searching ? '没有找到匹配的音乐' : '这个目录还没有入库曲目',
                  message: searching
                      ? '这个目录里没有标题、艺术家或专辑包含「$_query」的曲目。'
                      : '扫一次这个目录，曲目会按当前排序出现在这里。',
                  action: searching
                      ? TextButton(
                          onPressed: _clearSearch,
                          child: const Text('清除搜索'),
                        )
                      : null,
                )
              : TrackListView(
                  key: ValueKey<String>('folder-detail-$folder'),
                  tracks: list,
                  storageKey: PageStorageKey<String>('tracks:folder-$folder'),
                  playingPath: _currentTrack?.path,
                  flashPath: _flashTrackPath,
                  onPlay: (Track track) => unawaited(_playFrom(list, track)),
                  favoritePaths: _favoritePaths,
                  onToggleFavorite: (Track track) =>
                      unawaited(_toggleFavorite(track)),
                  onContextAction: (Track track, TrackContextAction action) =>
                      _onTrackContext(list, track, action),
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
                        list,
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

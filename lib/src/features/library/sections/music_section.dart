part of '../library_page.dart';

/// 音乐分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _MusicSection on _LibraryPageState {
  /// 滚动到正在播放的曲目：按固定行高把目标行放到可视区中间。
  ///
  /// 搜索 / 筛选状态下当前曲目可能不在列表里，这时只提示不动滚动条。
  void _locateCurrentTrack() {
    final Track? current = _currentTrack;
    if (current == null) {
      _showMessage('当前没有正在播放的曲目');
      return;
    }
    final List<Track> visible = _query.isEmpty
        ? _tracks
        : (_results ?? const <Track>[]);
    final int index = visible.indexWhere(
      (Track track) => track.path == current.path,
    );
    if (index < 0) {
      _showMessage('当前曲目不在列表里（可能被隐藏或不在筛选结果中）');
      return;
    }
    if (!_musicScroll.hasClients) {
      return;
    }
    const double rowExtent = 56;
    final ScrollPosition position = _musicScroll.position;
    final double target =
        (index * rowExtent - (position.viewportDimension - rowExtent) / 2)
            .clamp(0.0, position.maxScrollExtent);
    unawaited(
      _musicScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
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
        : (_searching
              ? '正在搜索…'
              : (_searchTruncated
                    ? '找到 500+ 首（仅显示前 500）'
                    : '找到 ${visible.length} 首'));

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
            _buildSelectionHeaderSlot(context),
            IconButton(
              key: const ValueKey<String>('music-locate-current'),
              tooltip: '定位正在播放',
              onPressed: _currentTrack == null
                  ? null
                  : () => _locateCurrentTrack(),
              icon: const Icon(Icons.my_location, size: 20),
            ),
            FilledButton.tonalIcon(
              onPressed: visible.isEmpty || _searching
                  ? null
                  : () => unawaited(_playAll(visible)),
              icon: const Icon(Icons.play_arrow),
              label: Text(_query.isEmpty ? '播放全部' : '播放结果'),
            ),
            const SizedBox(width: 8),
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
        if (_scanning)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _lastScanFolder == null
                        ? '正在扫描…'
                        : '正在扫描 ${_lastScanFolder!}…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
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
        controller: _musicScroll,
        tracks: _results!,
        storageKey: const PageStorageKey<String>('tracks:search'),
        playingPath: _currentTrack?.path,
        onPlay: (Track track) => unawaited(_playFrom(_results!, track)),
        favoritePaths: _favoritePaths,
        onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
        onContextAction: (Track track, TrackContextAction action) =>
            _onTrackContext(_results!, track, action),
        selectionMode: _selectionMode,
        selectedPaths: _selectedPaths,
        onSelect: (Track track, {required bool toggle, required bool range}) =>
            _onTrackSelect(_results!, track, toggle: toggle, range: range),
      );
    }
    if (_tracks.isEmpty) {
      return EmptyState(
        icon: Icons.library_music_outlined,
        title: '曲库还是空的',
        message: '选择包含音乐的文件夹，扫描后曲目会自动出现在这里；也可以把文件夹直接拖进窗口。',
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
      controller: _musicScroll,
      tracks: _tracks,
      storageKey: const PageStorageKey<String>('tracks:music'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_tracks, track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_tracks, track, action),
      selectionMode: _selectionMode,
      selectedPaths: _selectedPaths,
      onSelect: (Track track, {required bool toggle, required bool range}) =>
          _onTrackSelect(_tracks, track, toggle: toggle, range: range),
    );
  }
}

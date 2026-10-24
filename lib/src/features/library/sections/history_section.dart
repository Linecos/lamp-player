part of '../library_page.dart';

/// 历史分区
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _HistorySection on _LibraryPageState {
  /* -------------------------------------------------------------- 历史 */

  Future<void> _loadHistory() async {
    if (_historyLoading) {
      return;
    }
    _update(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final List<Track> tracks = await _repository.loadRecentTracks(limit: 100);
      if (!mounted) {
        return;
      }
      _update(() {
        _historyTracks = tracks;
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() {
        _historyError = error;
        _historyLoading = false;
      });
    }
  }

  Future<void> _clearHistory() async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空播放历史？'),
        content: const Text('只清除播放记录，不会删除曲库里的音乐。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await _repository.clearHistory();
      if (!mounted) {
        return;
      }
      _update(() => _historyTracks = const <Track>[]);
      _showMessage('播放历史已清空');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('清空失败：${ErrorRetry.describe(error)}');
    }
  }

  Widget _buildHistorySection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '历史',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _historyTracks.isEmpty
                  ? null
                  : () => unawaited(_playAll(_historyTracks)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放全部'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              onPressed: _historyTracks.isEmpty
                  ? null
                  : () => unawaited(_clearHistory()),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('清空历史'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_historyTracks.length} 条播放记录',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildHistoryBody(context)),
      ],
    );
  }

  Widget _buildHistoryBody(BuildContext context) {
    if (_historyLoading && _historyTracks.isEmpty) {
      return const LoadingState(message: '正在读取播放历史…');
    }
    if (_historyError != null) {
      return ErrorRetry(
        error: _historyError!,
        title: '播放历史读取失败',
        onRetry: () => unawaited(_loadHistory()),
      );
    }
    if (_historyTracks.isEmpty) {
      return EmptyState(
        icon: Icons.history,
        title: '还没有播放记录',
        message: '播放过的曲目会按最近播放排在这里，方便接着上次继续听。',
        action: FilledButton.tonal(
          onPressed: () => _selectSection(LibrarySection.music),
          child: const Text('去曲库看看'),
        ),
      );
    }
    return TrackListView(
      tracks: _historyTracks,
      storageKey: const PageStorageKey<String>('tracks:history'),
      playingPath: _currentTrack?.path,
      onPlay: (Track track) => unawaited(_playFrom(_historyTracks, track)),
      favoritePaths: _favoritePaths,
      onToggleFavorite: (Track track) => unawaited(_toggleFavorite(track)),
      onContextAction: (Track track, TrackContextAction action) =>
          _onTrackContext(_historyTracks, track, action),
      selectionMode: _selectionMode,
      selectedPaths: _selectedPaths,
      onSelect: (Track track, {required bool toggle, required bool range}) =>
          _onTrackSelect(_historyTracks, track, toggle: toggle, range: range),
    );
  }
}

part of '../library_page.dart';

/// 曲库数据与加载
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _DataSection on _LibraryPageState {
  /* ---------------------------------------------------------------- 数据 */

  Future<void> _loadTracks() async {
    _update(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Track> tracks = await _repository.loadTracks();
      if (!mounted) {
        return;
      }
      _update(() {
        _tracks = sortTracks(tracks, _sort);
        _loading = false;
        // 扫描会刷新封面等字段：队列和当前曲目换成新对象，避免播放条还拿旧数据
        if (!_queue.isEmpty) {
          _queue.refreshTracks(_tracks);
        }
        final Track? current = _currentTrack;
        if (current != null) {
          final int index = _tracks.indexWhere(
            (Track track) => track.path == current.path,
          );
          if (index >= 0) {
            _currentTrack = _tracks[index];
          }
        }
      });
      if (_query.isNotEmpty) {
        unawaited(_runSearch(_query));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _update(() {
        _error = error;
        _loading = false;
      });
    }
  }
}

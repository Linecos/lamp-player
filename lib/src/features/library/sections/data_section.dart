part of '../library_page.dart';

/// 曲库数据与加载
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态：这一轮只做文件切分。
extension _DataSection on _LibraryPageState {
  /* ---------------------------------------------------------------- 数据 */

  /// [silent] 用于扫描后的刷新：保留当前列表，不切加载态、失败也不换错误页，
  /// 否则每扫一个目录整个曲库都会闪一下「正在读取曲库…」。
  Future<void> _loadTracks({bool silent = false}) async {
    if (!silent) {
      _update(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<Track> tracks = await _repository.loadTracks();
      if (!mounted) {
        return;
      }
      _update(() {
        _tracks = sortTracks(tracks, _sort);
        // 扫描会刷新标签：旧的拼音键可能已经对不上新标题，整体作废
        _pinyinKeys.clear();
        _pinyinWarmedCount = 0;
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
      if (silent) {
        // 扫描成功但读库失败：保留已有列表，别把用户已经看到的内容换成错误页
        debugPrint('扫描后刷新曲库失败：$error');
        _update(() => _loading = false);
        return;
      }
      _update(() {
        _error = error;
        _loading = false;
      });
    }
  }
}

part of '../library_page.dart';

/// 搜索与排序：输入防抖、结果请求与排序切换
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态。
extension _SearchSection on _LibraryPageState {
  /// 单次搜索最多展示的曲目数；超出时提示「500+」，而不是谎报正好 500 首
  static const int _searchLimit = 500;

  String _pinyinKeyOf(Track track) => _pinyinKeys.putIfAbsent(
    track.path,
    () => buildPinyinKey('${track.title} ${track.artist ?? ''}'),
  );

  /// 后台分帧预热拼音键。
  ///
  /// 万级曲库同步构建要几百毫秒，会卡在「第一次输入字母」的那一帧上；
  /// 这里一次只处理 200 条，然后让出事件循环，界面始终可响应。
  void _warmUpPinyinKeys() {
    if (_pinyinWarming || _pinyinWarmedCount >= _tracks.length) {
      return;
    }
    _pinyinWarming = true;
    unawaited(_warmUpPinyinChunk());
  }

  Future<void> _warmUpPinyinChunk() async {
    const int batch = 200;
    while (mounted && _pinyinWarmedCount < _tracks.length) {
      final int start = _pinyinWarmedCount;
      final int end = (start + batch).clamp(0, _tracks.length);
      for (int i = start; i < end; i++) {
        _pinyinKeyOf(_tracks[i]);
      }
      _pinyinWarmedCount = end;
      if (end >= _tracks.length) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    _pinyinWarming = false;
    if (!mounted) {
      return;
    }
    // 预热补齐了：当前查询如果还没结束，静默重跑一次拿到完整拼音结果
    if (_query.isNotEmpty && !hasCjk(_query)) {
      unawaited(_runSearch(_query, silent: true));
    }
  }

  /// 用拼音在本地曲库里找匹配；只在 FTS 没搜满且查询不含汉字时调用。
  ///
  /// 只匹配已经预热好的条目：还没轮到的曲目先跳过，等后台补完会自动重跑，
  /// 这样首次搜索不会因为「顺便建 10 万条拼音键」而卡住。
  List<Track> _pinyinMatches(String query, int limit) {
    final String needle = normalizePinyinQuery(query);
    if (needle.isEmpty) {
      return const <Track>[];
    }
    final List<Track> hits = <Track>[];
    for (final Track track in _tracks) {
      final String? key = _pinyinKeys[track.path];
      if (key == null) {
        continue;
      }
      if (key.contains(needle)) {
        hits.add(track);
        if (hits.length >= limit) {
          break;
        }
      }
    }
    return hits;
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final String query = value.trim();
    if (query != _query) {
      // 搜索结果的列表换了，之前选中的路径不一定还在，直接退出多选
      _clearSelection();
    }
    _update(() {
      _query = query;
      _searchError = null;
      if (query.isEmpty) {
        _results = null;
        _searching = false;
        _searchTruncated = false;
        _searchToken++;
      }
    });
    if (query.isEmpty) {
      return;
    }
    _debounce = Timer(_LibraryPageState._searchDebounce, () {
      unawaited(_runSearch(query));
    });
  }

  /// 执行一次搜索。
  ///
  /// [silent] 用于拼音预热完成后的补跑：结果会更完整，但不必再闪一次加载态。
  Future<void> _runSearch(String query, {bool silent = false}) async {
    final int token = ++_searchToken;
    if (!silent) {
      _update(() {
        _searching = true;
        _searchError = null;
      });
    }
    try {
      // 多取一条用来判断「还有更多」，只展示前 _searchLimit 条
      final List<Track> results = await _repository.searchTracks(
        query,
        limit: _searchLimit + 1,
      );
      if (!mounted || token != _searchToken) {
        return;
      }
      final bool truncated = results.length > _searchLimit;
      final List<Track> visible = truncated
          ? results.sublist(0, _searchLimit)
          : results;

      // FTS 只认字面：拼音首字母（yh → 夜航）在这里补上。
      // 有汉字时 FTS 已经够用，不必再全库转一遍拼音。
      List<Track> merged = visible;
      if (!hasCjk(query) && merged.length < _searchLimit) {
        // 首次输入字母时启动后台预热，本轮只匹配已建好的部分
        _warmUpPinyinKeys();
        final Set<String> seen = merged
            .map((Track track) => track.path)
            .toSet();
        final List<Track> extra = _pinyinMatches(
          query,
          _searchLimit - merged.length,
        );
        if (extra.isNotEmpty) {
          merged = <Track>[
            ...merged,
            ...extra.where((Track track) => seen.add(track.path)),
          ];
        }
      }

      _update(() {
        _results = sortTracks(merged, _sort);
        _searchTruncated = truncated || merged.length > _searchLimit;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || token != _searchToken) {
        return;
      }
      _update(() {
        _results = null;
        _searching = false;
        _searchTruncated = false;
        _searchError = error;
      });
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchToken++;
    _searchController.clear();
    _clearSelection();
    _update(() {
      _query = '';
      _results = null;
      _searching = false;
      _searchTruncated = false;
      _searchError = null;
    });
  }

  void _changeSort(LibrarySort sort) {
    if (sort == _sort) {
      return;
    }
    _update(() {
      _sort = sort;
      _tracks = sortTracks(_tracks, sort);
      final List<Track>? results = _results;
      if (results != null) {
        _results = sortTracks(results, sort);
      }
    });
    _saveSessionNow();
  }
}

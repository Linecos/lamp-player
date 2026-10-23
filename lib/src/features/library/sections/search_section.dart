part of '../library_page.dart';

/// 搜索与排序：输入防抖、结果请求与排序切换
///
/// 从 `_LibraryPageState` 拆出，仍直接读写页面状态。
extension _SearchSection on _LibraryPageState {
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final String query = value.trim();
    _update(() {
      _query = query;
      _searchError = null;
      if (query.isEmpty) {
        _results = null;
        _searching = false;
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

  Future<void> _runSearch(String query) async {
    final int token = ++_searchToken;
    _update(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final List<Track> results = await _repository.searchTracks(
        query,
        limit: 500,
      );
      if (!mounted || token != _searchToken) {
        return;
      }
      _update(() {
        _results = sortTracks(results, _sort);
        _searching = false;
      });
    } catch (error) {
      if (!mounted || token != _searchToken) {
        return;
      }
      _update(() {
        _results = null;
        _searching = false;
        _searchError = error;
      });
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchToken++;
    _searchController.clear();
    _update(() {
      _query = '';
      _results = null;
      _searching = false;
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

part of '../library_page.dart';

/// 常驻搜索框的「就地过滤」：只作用于当前分区，不查数据库。
///
/// 音乐分区仍走 FTS（支持拼音、有 500 条上限），其余分区的数据已经在内存里，
/// 按名称 / 标签做字面 + 拼音匹配即可。
extension _FilterSection on _LibraryPageState {
  /// 提示语跟着分区走，用户一眼能看出搜的是哪一层
  String get _searchHint => switch (_section) {
    LibrarySection.music => '搜索音乐',
    LibrarySection.playlists => '搜索歌单',
    LibrarySection.history => '搜索历史',
    LibrarySection.favorites => '搜索收藏',
    LibrarySection.artists => '搜索艺术家',
    LibrarySection.albums => '搜索专辑',
    LibrarySection.settings => '设置页无需搜索',
  };

  /// 设置分区没有可过滤的内容，直接禁用输入
  bool get _searchEnabled => _section != LibrarySection.settings;

  /// 只有音乐分区需要问数据库
  bool get _queriesDatabase => _section == LibrarySection.music;

  /// 名称命中：先字面包含，非汉字查询再用拼音键兜底（`yh` → 夜航）
  bool _matchesText(String text, String query) {
    if (text.isEmpty) {
      return false;
    }
    if (text.toLowerCase().contains(query.toLowerCase())) {
      return true;
    }
    if (hasCjk(query)) {
      return false;
    }
    final String key = _namePinyinKeys.putIfAbsent(
      text,
      () => buildPinyinKey(text),
    );
    return key.contains(normalizePinyinQuery(query));
  }

  bool _matchesTrack(Track track, String query) =>
      _matchesText(track.title, query) ||
      _matchesText(track.artist ?? '', query) ||
      _matchesText(track.album ?? '', query);

  List<Track> _filterTracks(List<Track> tracks) {
    if (_query.isEmpty) {
      return tracks;
    }
    return tracks
        .where((Track track) => _matchesTrack(track, _query))
        .toList();
  }

  List<AlbumGroup> _filterAlbums(List<AlbumGroup> albums) {
    if (_query.isEmpty) {
      return albums;
    }
    return albums
        .where(
          (AlbumGroup album) =>
              _matchesText(album.title, _query) ||
              _matchesText(album.artist, _query),
        )
        .toList();
  }

  List<ArtistGroup> _filterArtists(List<ArtistGroup> artists) {
    if (_query.isEmpty) {
      return artists;
    }
    return artists
        .where((ArtistGroup artist) => _matchesText(artist.name, _query))
        .toList();
  }

  List<Playlist> _filterPlaylists(List<Playlist> playlists) {
    if (_query.isEmpty) {
      return playlists;
    }
    return playlists
        .where((Playlist playlist) => _matchesText(playlist.name, _query))
        .toList();
  }

  /// 分区内搜索无结果：不要复用「曲库为空」的空态，否则会误导用户去导音乐
  Widget _searchEmptyState(String title) => EmptyState(
    icon: Icons.search_off,
    title: title,
    message: '当前分区里没有包含「$_query」的内容。换个关键词，或清除搜索查看全部。',
    action: TextButton(onPressed: _clearSearch, child: const Text('清除搜索')),
  );
}

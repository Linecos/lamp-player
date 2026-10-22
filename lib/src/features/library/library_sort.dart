import '../../rust/api/model.dart';

/// 缺少艺术家标签时的展示名
const String unknownArtist = '未知艺术家';

/// 缺少专辑标签时的展示名
const String unknownAlbum = '未知专辑';

/// 曲库列表的排序方式
enum LibrarySort {
  library('默认顺序'),
  title('标题'),
  artist('艺术家'),
  album('专辑'),
  duration('时长'),
  added('最近添加');

  const LibrarySort(this.label);

  final String label;
}

/// 取展示用艺术家名（空标签归为「未知艺术家」）
String trackArtist(Track track) {
  final String? artist = track.artist?.trim();
  return artist == null || artist.isEmpty ? unknownArtist : artist;
}

/// 取展示用专辑名（空标签归为「未知专辑」）
String trackAlbum(Track track) {
  final String? album = track.album?.trim();
  return album == null || album.isEmpty ? unknownAlbum : album;
}

/// 专辑聚合键：同一位艺术家的同名专辑算一张
String albumGroupKey(Track track) =>
    '${trackArtist(track)}\u0000${trackAlbum(track)}';

/// 按指定方式排序，返回新列表（不改动入参）。
///
/// 排序规则全部是纯 Dart 逻辑，可在 `test/` 下覆盖，不依赖 Rust。
List<Track> sortTracks(Iterable<Track> tracks, LibrarySort mode) {
  final List<Track> sorted = List<Track>.of(tracks);
  // 默认顺序完全沿用调用方（Rust 已按 artist/album/track_num 排好），
  // 不调用 sort，避免不稳定排序打乱相等元素的相对位置。
  if (mode == LibrarySort.library) {
    return sorted;
  }
  sorted.sort((Track a, Track b) {
    final int primary = switch (mode) {
      LibrarySort.library => 0,
      LibrarySort.title => _compareText(a.title, b.title),
      LibrarySort.artist => _firstNonZero(<int>[
        _compareText(trackArtist(a), trackArtist(b)),
        _compareText(trackAlbum(a), trackAlbum(b)),
        _compareNumber(a.trackNum, b.trackNum),
      ]),
      LibrarySort.album => _firstNonZero(<int>[
        _compareText(trackAlbum(a), trackAlbum(b)),
        _compareText(trackArtist(a), trackArtist(b)),
        _compareNumber(a.trackNum, b.trackNum),
      ]),
      LibrarySort.duration => b.durationSecs.compareTo(a.durationSecs),
      LibrarySort.added => b.addedAt.compareTo(a.addedAt),
    };
    if (primary != 0) {
      return primary;
    }
    if (mode == LibrarySort.library) {
      return 0;
    }
    // 同值时用标题、路径兜底，保证顺序稳定、可预期
    return _firstNonZero(<int>[
      _compareText(a.title, b.title),
      a.path.compareTo(b.path),
    ]);
  });
  return sorted;
}

/// 按艺术家聚合（只读展示用）
List<ArtistGroup> groupTracksByArtist(Iterable<Track> tracks) {
  final Map<String, List<Track>> buckets = <String, List<Track>>{};
  for (final Track track in tracks) {
    buckets.putIfAbsent(trackArtist(track), () => <Track>[]).add(track);
  }
  final List<ArtistGroup> groups = buckets.entries
      .map(
        (MapEntry<String, List<Track>> entry) => ArtistGroup(
          name: entry.key,
          tracks: sortTracks(entry.value, LibrarySort.album),
        ),
      )
      .toList();
  groups.sort((ArtistGroup a, ArtistGroup b) => _compareText(a.name, b.name));
  return groups;
}

/// 按「艺术家 + 专辑」聚合（只读展示用）
List<AlbumGroup> groupTracksByAlbum(Iterable<Track> tracks) {
  final Map<String, AlbumGroup> buckets = <String, AlbumGroup>{};
  for (final Track track in tracks) {
    final String key = albumGroupKey(track);
    buckets
        .putIfAbsent(
          key,
          () => AlbumGroup(
            key: key,
            title: trackAlbum(track),
            artist: trackArtist(track),
          ),
        )
        .tracks
        .add(track);
  }
  final List<AlbumGroup> groups = buckets.values.toList();
  for (final AlbumGroup group in groups) {
    group.tracks.sort(
      (Track a, Track b) => _firstNonZero(<int>[
        _compareNumber(a.trackNum, b.trackNum),
        _compareText(a.title, b.title),
        a.path.compareTo(b.path),
      ]),
    );
  }
  groups.sort(
    (AlbumGroup a, AlbumGroup b) => _firstNonZero(<int>[
      _compareText(a.artist, b.artist),
      _compareText(a.title, b.title),
    ]),
  );
  return groups;
}

/// 艺术家聚合结果
class ArtistGroup {
  ArtistGroup({required this.name, required this.tracks});

  final String name;
  final List<Track> tracks;

  int get albumCount => tracks.map(trackAlbum).toSet().length;

  int get trackCount => tracks.length;
}

/// 专辑聚合结果
class AlbumGroup {
  AlbumGroup({required this.key, required this.title, required this.artist});

  final String key;
  final String title;
  final String artist;
  final List<Track> tracks = <Track>[];

  double get durationSecs => tracks.fold<double>(
    0,
    (double sum, Track track) => sum + track.durationSecs,
  );
}

int _firstNonZero(List<int> values) {
  for (final int value in values) {
    if (value != 0) {
      return value;
    }
  }
  return 0;
}

int _compareText(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

int _compareNumber(int? a, int? b) => (a ?? 0).compareTo(b ?? 0);

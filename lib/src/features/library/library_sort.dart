import '../../rust/api/model.dart';

/// 缺少艺术家标签时的展示名
const String unknownArtist = '未知艺术家';

/// 缺少专辑标签时的展示名
const String unknownAlbum = '未知专辑';

/// 曲库列表的排序方式
enum LibrarySort {
  /// 默认顺序：最近添加的排在前面。
  ///
  /// 以前这里是「不排序、沿用调用方给的顺序」，而调用方拿到的列表就是上一次
  /// 排序的结果 —— 于是「默认顺序」实际上等于「上次选的那一种」，按标题排完
  /// 再切回来还是标题序。现在固定成按 `addedAt` 倒序，不再受上一次选择影响。
  library('默认顺序'),
  title('标题'),
  artist('艺术家'),
  album('专辑'),
  duration('时长'),

  /// 与默认顺序同义：保留成显式选项，习惯点这一项的人照旧能找到
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

/// 排序用的一次性键：小写串只算一遍。
///
/// 比较函数里直接 `toLowerCase()` 在万级曲库上是几十万次临时字符串分配
/// （一次排序约 n log n 次比较、每次两份），排序反而成了次要开销。
/// 这里每首曲目只算 3 次，之后比较全是 `compareTo`。
class _SortEntry {
  _SortEntry(this.track)
    : title = track.title.toLowerCase(),
      artist = trackArtist(track).toLowerCase(),
      album = trackAlbum(track).toLowerCase();

  final Track track;
  final String title;
  final String artist;
  final String album;
}

/// 按指定方式排序，返回新列表（不改动入参）。
///
/// 排序规则全部是纯 Dart 逻辑，可在 `test/` 下覆盖，不依赖 Rust。
List<Track> sortTracks(Iterable<Track> tracks, LibrarySort mode) {
  final List<_SortEntry> entries = <_SortEntry>[
    for (final Track track in tracks) _SortEntry(track),
  ];
  entries.sort((_SortEntry a, _SortEntry b) {
    final int primary = switch (mode) {
      // 默认顺序与「最近添加」同义：新导入的排在最前
      LibrarySort.library ||
      LibrarySort.added => b.track.addedAt.compareTo(a.track.addedAt),
      LibrarySort.title => a.title.compareTo(b.title),
      LibrarySort.artist => _firstNonZero(<int>[
        a.artist.compareTo(b.artist),
        a.album.compareTo(b.album),
        _compareNumber(a.track.trackNum, b.track.trackNum),
      ]),
      LibrarySort.album => _firstNonZero(<int>[
        a.album.compareTo(b.album),
        a.artist.compareTo(b.artist),
        _compareNumber(a.track.trackNum, b.track.trackNum),
      ]),
      LibrarySort.duration => b.track.durationSecs.compareTo(
        a.track.durationSecs,
      ),
    };
    if (primary != 0) {
      return primary;
    }
    // 同值时用标题、路径兜底，保证顺序稳定、可预期
    return _firstNonZero(<int>[
      a.title.compareTo(b.title),
      a.track.path.compareTo(b.track.path),
    ]);
  });
  return <Track>[for (final _SortEntry entry in entries) entry.track];
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

  /// 组内第一张可用封面；全都没有时返回 null，交给界面回退占位。
  String? get coverPath {
    for (final Track track in tracks) {
      final String? path = track.coverPath;
      if (path != null && path.isNotEmpty) {
        return path;
      }
    }
    return null;
  }
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

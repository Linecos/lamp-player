import '../../common/text/pinyin_key.dart';
import '../../rust/api/model.dart';

/// 缺少艺术家标签时的展示名
const String unknownArtist = '未知艺术家';

/// 缺少专辑标签时的展示名
const String unknownAlbum = '未知专辑';

/// 曲库列表的排序方式
///
/// 没有「默认顺序」这一项了：按钮上只显示当前是哪种顺序（「标题」「艺术家」…），
/// 首次打开就是按标题升序。
enum LibrarySort {
  title('标题'),
  artist('艺术家'),
  album('专辑'),
  duration('时长'),
  added('最近添加');

  const LibrarySort(this.label);

  final String label;

  /// 首次打开 / 用户没选过时的排序方式
  static const LibrarySort defaultSort = LibrarySort.title;

  /// 这一项切过去时的默认方向：只有「最近添加」是新的在前，其它都是升序
  bool get defaultAscending => this != LibrarySort.added;
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

/// 缩写型名字（全大写字母 / 数字，两个字符以内）：`AC`、`DC`、`X`
final RegExp _abbreviation = RegExp(r'^[A-Z0-9]+$');

/// 拆分多艺术家：标签里用 `/` 隔开的多位艺术家
/// （`Bao The Whale/Overspace`）。
///
/// 只认 `/`。`&`、`,`、`;` 在乐队名里太常见（Simon & Garfunkel、
/// Earth, Wind & Fire），按它们拆会把名字拆坏。
///
/// 反过来 `AC/DC` 这种缩写型名字会被 `/` 误伤，所以加一条：拆出来的每段
/// 都只有两个字符以内、且全是字母数字时，当作一个整体不动。
///
/// 返回的列表至少有一项；顺序按标签里的出现顺序，重复的去掉。
List<String> splitTrackArtists(Track track) =>
    splitArtistTag(trackArtist(track));

/// 拆一个艺术家标签字符串：规则与 [splitTrackArtists] 完全一致。
///
/// 统计页拿到的是 SQL 聚合过的原始标签（`A/B` 一行），没有 `Track` 可传，
/// 所以把规则放在这里共用一份，别在两处各写一遍。
List<String> splitArtistTag(String tag) {
  final String whole = tag.trim();
  if (whole.isEmpty) {
    return <String>[unknownArtist];
  }
  if (!whole.contains('/')) {
    return <String>[whole];
  }
  final List<String> parts = <String>[];
  for (final String raw in whole.split('/')) {
    final String name = raw.trim();
    if (name.isNotEmpty && !parts.contains(name)) {
      parts.add(name);
    }
  }
  if (parts.isEmpty) {
    return <String>[whole];
  }
  if (parts.length == 1) {
    // `A / ` 这种尾巴带分隔符的脏标签：只留真正那一段
    return parts;
  }
  if (parts.every(
    (String part) => part.length <= 2 && _abbreviation.hasMatch(part),
  )) {
    return <String>[whole];
  }
  return parts;
}

/// 专辑聚合键：同一位艺术家的同名专辑算一张
String albumGroupKey(Track track) =>
    '${trackArtist(track)}\u0000${trackAlbum(track)}';

/// 排序用的一次性键。
///
/// 比较函数里直接 `toLowerCase()` / 现算拼音，在万级曲库上是几十万次临时
/// 字符串分配（一次排序约 n log n 次比较、每次两份），排序反而成了次要开销。
/// 这里每首曲目只算一遍，之后比较全是 `compareTo`。
///
/// 三个键都用 `late final`：按哪种顺序排、才建哪种键。「标题」排序不会白算
/// 艺术家与专辑的拼音。
class _SortEntry {
  _SortEntry(this.track);

  final Track track;

  /// 拼音排序键：汉字转全拼、英文转小写，中英混排落在同一把尺子上。
  late final String titleKey = pinyinSortKey(track.title);
  late final String artistKey = pinyinSortKey(trackArtist(track));
  late final String albumKey = pinyinSortKey(trackAlbum(track));
}

/// 按指定方式排序，返回新列表（不改动入参）。
///
/// 排序规则全部是纯 Dart 逻辑，可在 `test/` 下覆盖，不依赖 Rust。
List<Track> sortTracks(
  Iterable<Track> tracks,
  LibrarySort mode, {
  bool? ascending,
}) {
  // 不传方向时按这一项自己的默认值：「最近添加」新的在前，其它升序
  final bool asc = ascending ?? mode.defaultAscending;
  final List<_SortEntry> entries = <_SortEntry>[
    for (final Track track in tracks) _SortEntry(track),
  ];
  entries.sort((_SortEntry a, _SortEntry b) {
    // 每种模式先按「升序」定义，方向由 ascending 统一翻转
    final int primary = switch (mode) {
      // 标题、艺术家、专辑都按**拼音**比：直接比码位的话，中文列表会排成
      // 「城市低语 → 夜航 → 天台 → 归途」这种看不懂的顺序（UTF-8 码位序），
      // 和右侧字母导航的拼音分段也对不上。
      LibrarySort.title => a.titleKey.compareTo(b.titleKey),
      LibrarySort.artist => _firstNonZero(<int>[
        a.artistKey.compareTo(b.artistKey),
        a.albumKey.compareTo(b.albumKey),
        _compareNumber(a.track.trackNum, b.track.trackNum),
      ]),
      LibrarySort.album => _firstNonZero(<int>[
        a.albumKey.compareTo(b.albumKey),
        a.artistKey.compareTo(b.artistKey),
        _compareNumber(a.track.trackNum, b.track.trackNum),
      ]),
      LibrarySort.duration => a.track.durationSecs.compareTo(
        b.track.durationSecs,
      ),
      LibrarySort.added => a.track.addedAt.compareTo(b.track.addedAt),
    };
    if (primary != 0) {
      return asc ? primary : -primary;
    }
    // 同值时用标题、路径兜底，保证顺序稳定、可预期
    return _firstNonZero(<int>[
      a.titleKey.compareTo(b.titleKey),
      a.track.path.compareTo(b.track.path),
    ]);
  });
  return <Track>[for (final _SortEntry entry in entries) entry.track];
}

/// 按艺术家聚合（只读展示用）
///
/// 多艺术家曲目（`A/B`）会同时出现在 A 和 B 两个组里——艺术家分区里两位
/// 都得有自己的入口，否则从播放页点 B 跳过来会找不到人。
List<ArtistGroup> groupTracksByArtist(Iterable<Track> tracks) {
  final Map<String, List<Track>> buckets = <String, List<Track>>{};
  for (final Track track in tracks) {
    for (final String name in splitTrackArtists(track)) {
      buckets.putIfAbsent(name, () => <Track>[]).add(track);
    }
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

  /// 专辑数。
  ///
  /// 懒算一次就存住：卡片上的「N 张专辑 · M 首」是每次重建都要读的，
  /// 而这里是 `tracks.map(...).toSet()`——几百首的艺术家每次重建都白建一个集合。
  late final int albumCount = tracks.map(trackAlbum).toSet().length;

  int get trackCount => tracks.length;

  /// 艺术家头像用的封面：组内**第一首有封面的曲目**。
  ///
  /// 组内顺序是「专辑 → 曲目号」（见 [groupTracksByArtist]），所以拿到的是
  /// 这位艺术家最早那张专辑的第一首——换个顺序重算也是同一张，不会每次
  /// 刷新都换脸。
  ///
  /// 全都没有封面时返回 null，交给界面回退首字母头像。
  /// 同样懒算一次：没有封面的那组否则每次重建都要把 tracks 走完。
  late final String? coverPath = firstCoverPath(tracks);
}

/// 一组曲目里第一张可用封面；全都没有时返回 null。
///
/// 专辑与艺术家两处共用：口径一致，才不会出现「专辑卡片有图、艺术家头像
/// 却是字母」这种同一张专辑两种表现。
String? firstCoverPath(Iterable<Track> tracks) {
  for (final Track track in tracks) {
    final String? path = track.coverPath;
    if (path != null && path.isNotEmpty) {
      return path;
    }
  }
  return null;
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
  String? get coverPath => firstCoverPath(tracks);
}

int _firstNonZero(List<int> values) {
  for (final int value in values) {
    if (value != 0) {
      return value;
    }
  }
  return 0;
}

/// 两段文本比较：先比拼音（中文按拼音、英文按小写），拼音相同再比原文。
///
/// 分组（艺术家 / 专辑）走这里，列表排序走 [_SortEntry] 里预算好的键 ——
/// 同一套规则，两处出口才不会一个按拼音、一个按码位。
int _compareText(String a, String b) {
  final int primary = pinyinSortKey(a).compareTo(pinyinSortKey(b));
  return primary != 0 ? primary : a.toLowerCase().compareTo(b.toLowerCase());
}

int _compareNumber(int? a, int? b) => (a ?? 0).compareTo(b ?? 0);

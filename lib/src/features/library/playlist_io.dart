/// 歌单导入 / 导出（M3U8 格式）。
///
/// M3U8 是各播放器通用的播放列表格式，导出的文件可以被 foobar2000 /
/// VLC 等直接打开：
/// - `#EXTM3U`：文件头；
/// - `#PLAYLIST:<名>`：歌单名（常见扩展，非强制）；
/// - `#EXTINF:<秒>,<艺术家> - <标题>`：曲目元信息，后跟一行文件路径；
/// - 其余 `#` 行一律忽略；路径按原样写绝对路径。
///
/// 导入时按「规范化路径」匹配曲库；路径对不上再按「唯一文件名」兜底，
/// 有同名歧义的文件名不兜底（宁可少导入也不导错歌）。
library;

import '../../rust/api/model.dart';

/// 导出歌单为 M3U8 文本（写入文件由调用方负责）。
String buildM3U8({required String playlistName, required List<Track> tracks}) {
  final StringBuffer buffer = StringBuffer('#EXTM3U\n');
  if (playlistName.isNotEmpty) {
    buffer.writeln('#PLAYLIST:$playlistName');
  }
  for (final Track track in tracks) {
    buffer.writeln(
      '#EXTINF:${track.durationSecs.round()},${track.artist ?? ''} - '
      '${track.title}',
    );
    buffer.writeln(track.path);
  }
  return buffer.toString();
}

/// 解析结果
class ParsedM3U {
  const ParsedM3U({this.playlistName, required this.entries});

  /// `#PLAYLIST:` 行给出的歌单名；没有则为 `null`。
  final String? playlistName;

  final List<M3UEntry> entries;
}

/// M3U 里的一条曲目记录
class M3UEntry {
  const M3UEntry({
    required this.path,
    this.durationSecs,
    this.title,
    this.artist,
  });

  final String path;
  final int? durationSecs;
  final String? title;
  final String? artist;
}

/// 解析 M3U / M3U8 文本；空行与未知 `#` 行忽略，BOM 与 CRLF 兼容。
ParsedM3U parseM3U(String content) {
  String? name;
  M3UEntry? pendingMeta;
  final List<M3UEntry> entries = <M3UEntry>[];

  // 去 UTF-8 BOM；trim 同时吃掉 CRLF 的 \r
  final String text = content.replaceFirst('\ufeff', '');
  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('#PLAYLIST:')) {
      name = line.substring('#PLAYLIST:'.length).trim();
      continue;
    }
    if (line.startsWith('#EXTINF:')) {
      pendingMeta = _parseExtInf(line.substring('#EXTINF:'.length));
      continue;
    }
    if (line.startsWith('#')) {
      continue; // #EXTM3U 与其他扩展行
    }
    // 元信息行之后的第一个非注释行是路径
    entries.add(
      M3UEntry(
        path: line,
        durationSecs: pendingMeta?.durationSecs,
        title: pendingMeta?.title,
        artist: pendingMeta?.artist,
      ),
    );
    pendingMeta = null;
  }
  return ParsedM3U(playlistName: name, entries: entries);
}

/// `123,Artist - Title` → 条目；格式不合规时只有 duration 可能为 null
M3UEntry _parseExtInf(String body) {
  final int comma = body.indexOf(',');
  final int? seconds = comma < 0
      ? null
      : int.tryParse(body.substring(0, comma).trim());
  final String info = comma < 0 ? body : body.substring(comma + 1).trim();
  final int sep = info.indexOf(' - ');
  if (sep < 0) {
    return M3UEntry(path: '', durationSecs: seconds, title: info);
  }
  return M3UEntry(
    path: '',
    durationSecs: seconds,
    artist: info.substring(0, sep).trim(),
    title: info.substring(sep + 3).trim(),
  );
}

/// 用导入条目匹配曲库曲目；返回按导入顺序排列、已去重的匹配结果。
///
/// 匹配策略：先按规范化路径（统一 `/` 与小写）精确匹配；
/// 路径对不上时按文件名兜底，但**同名多个候选的文件名不参与兜底**。
List<Track> matchImportedEntries(
  List<M3UEntry> entries,
  List<Track> libraryTracks,
) {
  final Map<String, Track> byPath = <String, Track>{
    for (final Track track in libraryTracks) _normalizePath(track.path): track,
  };
  // 文件名 → 曲目；同名多个候选时值为 null（歧义，不兜底）
  final Map<String, Track?> byFileName = <String, Track?>{};
  for (final Track track in libraryTracks) {
    final String key = _normalizePath(_fileName(track.path));
    byFileName[key] = byFileName.containsKey(key) ? null : track;
  }

  final List<Track> matched = <Track>[];
  final Set<String> seen = <String>{};
  for (final M3UEntry entry in entries) {
    final Track? track =
        byPath[_normalizePath(entry.path)] ??
        byFileName[_normalizePath(_fileName(entry.path))];
    if (track != null && seen.add(track.path)) {
      matched.add(track);
    }
  }
  return matched;
}

/// 导入报告：匹配上多少首、文件里一共多少条
({int matched, int total}) importStats(
  List<M3UEntry> entries,
  List<Track> matched,
) => (matched: matched.length, total: entries.length);

String _normalizePath(String path) => path.replaceAll('\\', '/').toLowerCase();

String _fileName(String path) {
  final int index = path.lastIndexOf(RegExp(r'[\\/]'));
  return index < 0 ? path : path.substring(index + 1);
}

import 'dart:io';

/// 与 `rust/src/scanner.rs` 的 `AUDIO_EXTENSIONS` 保持一致。
///
/// 改这里记得同步 Rust 侧：漏一种的表现是「拖这种格式进来没反应」，
/// 而它的文件格式其实能扫。
const Set<String> _audioExtensions = <String>{
  'mp3',
  'flac',
  'wav',
  'ogg',
  'm4a',
  'aac',
  'ape',
  'opus',
};

int _lastSeparator(String path) {
  final int forward = path.lastIndexOf('/');
  final int backward = path.lastIndexOf(r'\');
  return forward > backward ? forward : backward;
}

bool _hasAudioExtension(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) {
    return false;
  }
  // 分隔符比点更靠右说明「点」出现在目录名里，这个文件名本身没有扩展名
  if (_lastSeparator(path) > dot) {
    return false;
  }
  return _audioExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// 把拖入的路径归一成需要扫描的音乐目录。
///
/// 文件夹取自身，音频文件取所在目录；忽略空路径与大小写重复项，保持拖入顺序。
/// [isDirectory] / [parentOf] 可注入，便于在测试里绕过真实文件系统。
///
/// 非音频文件直接丢弃：对文件一律「取所在目录」意味着误拖一个 PDF 就会
/// 把它所在的桌面 / 下载目录整个加进曲库并全盘扫描，代价太大。
List<String> foldersFromDropPaths(
  Iterable<String> paths, {
  bool Function(String path)? isDirectory,
  String Function(String path)? parentOf,
}) {
  final bool Function(String path) directoryCheck =
      isDirectory ?? (String path) => FileSystemEntity.isDirectorySync(path);
  final String Function(String path) parentResolver =
      parentOf ?? (String path) => File(path).parent.path;

  final Set<String> seen = <String>{};
  final List<String> folders = <String>[];
  for (final String raw in paths) {
    final String path = raw.trim();
    if (path.isEmpty) {
      continue;
    }
    final bool isDir;
    try {
      isDir = directoryCheck(path);
    } catch (_) {
      continue;
    }
    if (!isDir && !_hasAudioExtension(path)) {
      continue;
    }
    String folder;
    try {
      folder = isDir ? path : parentResolver(path);
    } catch (_) {
      continue;
    }
    folder = folder.trim();
    if (folder.isEmpty) {
      continue;
    }
    if (seen.add(folder.toLowerCase())) {
      folders.add(folder);
    }
  }
  return folders;
}

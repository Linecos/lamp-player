import 'dart:io';

/// 把拖入的路径归一成需要扫描的音乐目录。
///
/// 文件夹取自身，文件取所在目录；忽略空路径与大小写重复项，保持拖入顺序。
/// [isDirectory] / [parentOf] 可注入，便于在测试里绕过真实文件系统。
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
    String folder;
    try {
      folder = directoryCheck(path) ? path : parentResolver(path);
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

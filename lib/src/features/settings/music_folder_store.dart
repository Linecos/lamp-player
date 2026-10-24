import 'package:shared_preferences/shared_preferences.dart';

/// 已添加的音乐目录：读写都走这个接口，`test/` 下注入内存实现。
abstract interface class MusicFolderStore {
  /// 读取已保存的目录列表（已做规范化）
  Future<List<String>> load();

  /// 覆盖保存整个列表
  Future<void> save(List<String> folders);
}

/// 基于 `shared_preferences` 的实现。
///
/// 读写失败（插件不可用、存储损坏）都退化为「空列表 / 静默失败」，
/// 不阻塞曲库使用，最多下次启动时目录列表丢失。
class PrefsMusicFolderStore implements MusicFolderStore {
  const PrefsMusicFolderStore();

  /// 存储键；单独暴露便于测试直接断言写入内容
  static const String prefsKey = 'music_folders';

  @override
  Future<List<String>> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return normalizeFolders(
        prefs.getStringList(prefsKey) ?? const <String>[],
      );
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<void> save(List<String> folders) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, normalizeFolders(folders));
    } catch (_) {
      // 保存失败不影响本次会话已添加的目录
    }
  }
}

/// 盘根（如 `E:/`）
final RegExp _driveRoot = RegExp(r'^[A-Za-z]:[\\/]$');

/// UNC 共享根（形如 `//server/share/`）
final RegExp _uncRoot = RegExp(r'^\\\\[^\\/]+\\[^\\/]+[\\/]$');

/// 归一化单个目录路径：去首尾空白、去掉末尾多余分隔符。
///
/// 拖拽导入给的路径常带尾斜杠（形如 `E:/Music/`），与选择器返回的
/// `E:/Music` 会被当成两个目录，列表里出现重复条目。盘根与 UNC 共享根
/// 本身就以分隔符结尾，保留原样。
String normalizeFolderPath(String raw) {
  final String path = raw.trim();
  if (path.isEmpty) {
    return path;
  }
  if (_driveRoot.hasMatch(path)) {
    return '${path.substring(0, 2)}\\';
  }
  if (_uncRoot.hasMatch(path)) {
    return path.substring(0, path.length - 1);
  }
  String trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('\\') || trimmed.endsWith('/'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// 规范化目录列表：去首尾空白、丢掉空项、按大小写不敏感去重、保持添加顺序。
///
/// Windows 路径大小写不敏感，同一目录用不同大小写添加两次
/// 应当只保留一条；带不带尾斜杠也视为同一个目录（见 [normalizeFolderPath]）。
List<String> normalizeFolders(Iterable<String> folders) {
  final List<String> result = <String>[];
  final Set<String> seen = <String>{};
  for (final String raw in folders) {
    final String folder = normalizeFolderPath(raw);
    if (folder.isEmpty) {
      continue;
    }
    if (seen.add(folder.toLowerCase())) {
      result.add(folder);
    }
  }
  return result;
}

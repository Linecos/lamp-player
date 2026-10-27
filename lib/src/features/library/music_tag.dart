import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 「用 MusicTag 打开」的结果
enum MusicTagResult {
  /// 已经把文件交给 MusicTag
  launched,

  /// 没找到 / 还没选过 MusicTag.exe，需要用户指定一次
  notConfigured,

  /// 当前平台没有「启动外部 exe」这条路（非 Windows）
  unsupported,
}

/// MusicTag 可执行文件路径的持久化
abstract interface class MusicTagStore {
  Future<String?> load();

  Future<void> save(String? path);
}

/// 走 shared_preferences 的实现；读写失败按「没配置过」处理。
class PrefsMusicTagStore implements MusicTagStore {
  static const String prefsKey = 'ui_music_tag_path';

  @override
  Future<String?> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? path = prefs.getString(prefsKey);
      return (path == null || path.isEmpty) ? null : path;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String? path) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (path == null || path.isEmpty) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, path);
      }
    } catch (_) {
      // 记不住最多是下次再问一遍，不影响编辑本身
    }
  }
}

/// 外部标签编辑器 MusicTag（音乐标签）的启动器。
///
/// MusicTag 是绿色软件，装在哪完全看用户：先看记住的路径，再在 `PATH` 与几个
/// 常见目录里找，都找不到就返回 [MusicTagResult.notConfigured]，由页面引导
/// 用户手动选一次 `MusicTag.exe`（选完记住）。
class MusicTagLauncher {
  MusicTagLauncher({
    MusicTagStore? store,
    Future<void> Function(String exe, List<String> args)? start,
    Future<String?> Function()? picker,
    Future<List<String>> Function()? candidates,
    bool? isSupported,
  }) : _store = store ?? PrefsMusicTagStore(),
       _start = start ?? _startDetached,
       _picker = picker ?? _pickExecutable,
       _candidates = candidates ?? _probe,
       isSupported = isSupported ?? Platform.isWindows;

  /// MusicTag 的可执行文件名（大小写按官方发布包）
  static const String exeName = 'MusicTag.exe';

  /// 当前平台能不能启动外部 exe；测试里可注入，不依赖跑测试的系统
  final bool isSupported;

  final MusicTagStore _store;
  final Future<void> Function(String exe, List<String> args) _start;
  final Future<String?> Function() _picker;
  final Future<List<String>> Function() _candidates;

  /// 打开 [paths]（通常是单曲）
  Future<MusicTagResult> open(List<String> paths) async {
    if (!isSupported) {
      return MusicTagResult.unsupported;
    }
    final String? exe = await resolve();
    if (exe == null) {
      return MusicTagResult.notConfigured;
    }
    try {
      await _start(exe, paths);
      return MusicTagResult.launched;
    } catch (_) {
      // 路径过期（软件被删 / 改名）：清掉记住的路径，下次让用户重新选
      await _store.save(null);
      return MusicTagResult.notConfigured;
    }
  }

  /// 让用户手动选一次 MusicTag.exe；成功返回 `true`
  Future<bool> chooseExecutable() async {
    final String? picked = await _picker();
    if (picked == null || picked.trim().isEmpty) {
      return false;
    }
    await _store.save(picked.trim());
    return true;
  }

  /// 记住的路径 → PATH / 常见目录；命中后顺手记下来
  Future<String?> resolve() async {
    final String? saved = await _store.load();
    if (saved != null && File(saved).existsSync()) {
      return saved;
    }
    for (final String candidate in await _candidates()) {
      if (File(candidate).existsSync()) {
        await _store.save(candidate);
        return candidate;
      }
    }
    return null;
  }

  static Future<List<String>> _probe() async {
    final List<String> candidates = <String>[];
    final String? pathEnv = Platform.environment['PATH'];
    if (pathEnv != null) {
      for (final String dir in pathEnv.split(';')) {
        final String trimmed = dir.trim();
        if (trimmed.isNotEmpty) {
          candidates.add(p.join(trimmed, exeName));
        }
      }
    }
    // 绿色版一般的解压位置：程序目录 / 用户程序目录
    for (final String key in <String>[
      'ProgramFiles',
      'ProgramFiles(x86)',
      'LOCALAPPDATA',
    ]) {
      final String? root = Platform.environment[key];
      if (root == null) {
        continue;
      }
      candidates.add(p.join(root, 'MusicTag', exeName));
      candidates.add(p.join(root, 'Programs', 'MusicTag', exeName));
    }
    return candidates;
  }

  /// detached：玩家关掉播放器时 MusicTag 不该跟着退出
  static Future<void> _startDetached(String exe, List<String> args) async {
    await Process.start(exe, args, mode: ProcessStartMode.detached);
  }

  static Future<String?> _pickExecutable() async {
    const XTypeGroup exeType = XTypeGroup(
      label: 'MusicTag.exe',
      extensions: <String>['exe'],
    );
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[exeType],
    );
    return file?.path;
  }
}

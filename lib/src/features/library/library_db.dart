import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:lamp_player/src/rust/api/db.dart';

/// 曲库文件的固定文件名
const String kLibraryFileName = 'library.lampdb';

/// 曲库文件在支持目录下的完整路径（纯路径拼接，便于单元测试）。
String libraryDbPath(Directory supportDirectory) =>
    p.join(supportDirectory.path, kLibraryFileName);

/// 解析出曲库文件路径；目标目录不存在则顺带创建。
///
/// `supportDirectory` 为空时取应用支持目录（`path_provider`）。
/// 依赖平台通道，`flutter test` 下无法直接调用，所以保留了注入口。
Future<String> resolveLibraryDbPath(Directory? supportDirectory) async {
  final Directory directory =
      supportDirectory ?? await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return libraryDbPath(directory);
}

/// 启动时初始化曲库：应用支持目录 → `initDb`。
///
/// 同一路径重复调用是幂等的（Rust 侧保证），报错会抛给调用方展示。
Future<void> initLibrary({Directory? supportDirectory}) async {
  final String dbPath = await resolveLibraryDbPath(supportDirectory);
  await initDb(path: dbPath);
}

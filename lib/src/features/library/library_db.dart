import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:lamp_player/src/rust/api/db.dart';

/// 曲库文件名；标准 `.db` 后缀，SQLite 工具能按扩展名直接识别。
const String kLibraryFileName = 'library.db';

/// 旧版文件名，启动时自动改名。
const String kLegacyLibraryFileName = 'library.lampdb';

/// WAL sidecar：WAL 里可能有尚未 checkpoint 的数据，必须跟着主库一起搬。
///
/// 主库不在这里——它必须**最后**搬，见 [migrateLegacyLibrary]。
const List<String> _dbSidecarSuffixes = <String>['-wal', '-shm'];

/// 迁移结果：调用方据此决定打开哪个库、要不要提示。
enum LibraryMigration {
  /// 没有旧库，什么都没做。
  none,

  /// 旧库（含 sidecar）已搬到新文件名。
  moved,

  /// 新旧库同时存在：不覆盖、不动任何文件。
  conflict,

  /// 文件被占用等原因搬不动，已回滚，调用方应继续用旧路径打开。
  blocked,
}

/// 曲库文件在支持目录下的完整路径（纯路径拼接，便于单元测试）。
String libraryDbPath(Directory supportDirectory) =>
    p.join(supportDirectory.path, kLibraryFileName);

/// 旧版曲库文件路径，仅供迁移使用。
String legacyLibraryDbPath(Directory supportDirectory) =>
    p.join(supportDirectory.path, kLegacyLibraryFileName);

/// 把旧版 `library.lampdb`（含 sidecar）就地改名为 `library.db`。
///
/// 顺序是 **sidecar 先搬、主库最后**：只要主库还叫旧名字，下次启动就会把整个
/// 迁移重做一遍，中途崩掉最多白搬一次。反过来先搬主库的话，崩在中间会留下
/// 「空的新主库 + 旧名字的 WAL」，而新主库已存在时迁移会直接跳过，那份 WAL
/// 再也不会被认领——实测主库 4 KB、WAL 1.3 MB，等于整个曲库消失。
Future<LibraryMigration> migrateLegacyLibrary(
  Directory supportDirectory,
) async {
  final File legacy = File(legacyLibraryDbPath(supportDirectory));
  final File target = File(libraryDbPath(supportDirectory));
  if (!await legacy.exists()) return LibraryMigration.none;

  if (await target.exists()) {
    // 0 字节的新库是空壳（DBX / 编辑器建过又取消、上次中断留下的），里面
    // 不可能有数据，让位给旧库；有内容就当成真冲突，两边都不动。
    if (await target.length() != 0) return LibraryMigration.conflict;
    try {
      await target.delete();
    } on FileSystemException {
      return LibraryMigration.conflict;
    }
  }

  final List<String> moved = <String>[];
  try {
    for (final String suffix in _dbSidecarSuffixes) {
      final File from = File('${legacy.path}$suffix');
      if (!await from.exists()) continue;
      final File to = File('${target.path}$suffix');
      // 目标同名文件只可能是没有主库的孤儿；留着会让 rename 失败。
      // 注意只在「确实要搬」时删：上次迁移已经搬过去的那份要保留。
      if (await to.exists()) await to.delete();
      await from.rename(to.path);
      moved.add(suffix);
    }
    await legacy.rename(target.path);
    return LibraryMigration.moved;
  } on FileSystemException {
    // 被 DBX / 杀软占住时 rename 会抛异常。把已经搬走的 sidecar 搬回去，
    // 让调用方继续用旧路径打开，而不是把库开成「主库没了、WAL 也没了」。
    for (final String suffix in moved.reversed) {
      try {
        await File('${target.path}$suffix').rename('${legacy.path}$suffix');
      } on FileSystemException {
        // 回滚也失败就保持现状：主库仍在旧名字上，下次启动会重做迁移。
      }
    }
    return LibraryMigration.blocked;
  }
}

/// 解析出曲库文件路径；目标目录不存在则顺带创建，旧版文件先改名。
///
/// `supportDirectory` 为空时取应用支持目录（`path_provider`）。
/// 依赖平台通道，`flutter test` 下无法直接调用，所以保留了注入口。
Future<String> resolveLibraryDbPath(Directory? supportDirectory) async {
  final Directory directory =
      supportDirectory ?? await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final LibraryMigration migration = await migrateLegacyLibrary(directory);
  switch (migration) {
    case LibraryMigration.blocked:
      // 搬不动就先按旧名字打开，下次启动再试：改名失败不该让用户打不开曲库。
      debugPrint('曲库改名失败（$kLegacyLibraryFileName 可能被占用），本次继续使用旧文件名');
      return legacyLibraryDbPath(directory);
    case LibraryMigration.conflict:
      debugPrint(
        '新旧曲库同时存在，继续使用 $kLibraryFileName；'
        '$kLegacyLibraryFileName 保留未动，确认无用后可手动删除',
      );
      return libraryDbPath(directory);
    case LibraryMigration.none:
    case LibraryMigration.moved:
      return libraryDbPath(directory);
  }
}

/// 启动时初始化曲库：应用支持目录 → `initDb`。
///
/// 同一路径重复调用是幂等的（Rust 侧保证），报错会抛给调用方展示。
Future<void> initLibrary({Directory? supportDirectory}) async {
  final String dbPath = await resolveLibraryDbPath(supportDirectory);
  await initDb(path: dbPath);
}

/// 退出前关闭曲库：Rust 侧会 `optimize` 并截断 WAL，把数据合并回主库。
///
/// 不关的话 WAL 会一直涨（主库看着仍只有几 KB），只拷主库的备份会丢数据。
Future<void> closeLibrary() => closeDb();

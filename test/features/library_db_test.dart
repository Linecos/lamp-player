// 曲库启动链路的纯 Dart 测试：目录解析不依赖 FFI，`flutter test` 就能跑。
// 真实 initDb 的行为在 rust/tests/db.rs 与 integration_test 里验证。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_db.dart';

void main() {
  group('libraryDbPath', () {
    test('拼在支持目录下，文件名固定为 library.db', () {
      final Directory dir = Platform.isWindows
          ? Directory(r'C:\Users\lan\AppData\Roaming\Lamp Player')
          : Directory('/home/lan/AppData/Lamp Player');
      final String path = libraryDbPath(dir);
      expect(path.endsWith('library.db'), isTrue);
      expect(path.endsWith('.lampdb'), isFalse);
      expect(path.contains(dir.path), isTrue);
    });
  });

  group('resolveLibraryDbPath', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lamp_library_db_test_');
      addTearDown(() => temp.delete(recursive: true));
    });

    test('不存在的子目录会顺带创建', () async {
      final Directory nested = Directory(
        '${temp.path}${Platform.pathSeparator}a${Platform.pathSeparator}b',
      );

      final String dbPath = await resolveLibraryDbPath(nested);

      expect(nested.existsSync(), isTrue, reason: '目标目录应被创建');
      expect(dbPath.endsWith('library.db'), isTrue);
    });

    test('已存在的目录不报错，路径保持一致', () async {
      final String first = await resolveLibraryDbPath(temp);
      final String second = await resolveLibraryDbPath(temp);

      expect(first, second);
    });

    test('改名失败时回退到旧路径，不让用户打不开曲库', () async {
      writeFile(temp, 'library.lampdb', 'main');
      writeFile(temp, 'library.lampdb-wal', 'wal');
      // 目标位置被一个目录占住，rename 必然失败
      blockPath(temp, 'library.db-wal');

      final String dbPath = await resolveLibraryDbPath(temp);

      expect(dbPath, legacyLibraryDbPath(temp));
      expect(File(legacyLibraryDbPath(temp)).readAsStringSync(), 'main');
    });
  });

  group('migrateLegacyLibrary', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lamp_library_migrate_');
      addTearDown(() => temp.delete(recursive: true));
    });

    test('旧库连同 WAL / SHM 一起改名', () async {
      final File legacy = writeFile(temp, 'library.lampdb', 'main');
      writeFile(temp, 'library.lampdb-wal', 'wal');
      writeFile(temp, 'library.lampdb-shm', 'shm');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.moved);

      expect(legacy.existsSync(), isFalse);
      expect(File('${legacy.path}-wal').existsSync(), isFalse);
      expect(File('${legacy.path}-shm').existsSync(), isFalse);
      final File target = File(libraryDbPath(temp));
      expect(target.readAsStringSync(), 'main');
      expect(File('${target.path}-wal').readAsStringSync(), 'wal');
      expect(File('${target.path}-shm').readAsStringSync(), 'shm');
    });

    test('只有主库、没有 sidecar 也能迁移', () async {
      writeFile(temp, 'library.lampdb', 'main');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.moved);
      expect(File(libraryDbPath(temp)).existsSync(), isTrue);
    });

    test('新库有内容时不覆盖，两边都不动', () async {
      final File legacy = writeFile(temp, 'library.lampdb', 'old');
      final File target = writeFile(temp, 'library.db', 'new');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.conflict);
      expect(target.readAsStringSync(), 'new', reason: '不能覆盖已有的新库');
      expect(legacy.readAsStringSync(), 'old');
    });

    test('0 字节的新库是空壳，让位给旧库', () async {
      final File legacy = writeFile(temp, 'library.lampdb', 'main');
      writeFile(temp, 'library.lampdb-wal', 'wal');
      final File empty = writeFile(temp, 'library.db', '');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.moved);
      expect(legacy.existsSync(), isFalse);
      expect(empty.readAsStringSync(), 'main');
      expect(File('${empty.path}-wal').readAsStringSync(), 'wal');
    });

    test('没有旧库时什么都不做', () async {
      expect(await migrateLegacyLibrary(temp), LibraryMigration.none);
      expect(File(libraryDbPath(temp)).existsSync(), isFalse);
    });

    test('残留的孤儿 sidecar 不阻塞迁移', () async {
      writeFile(temp, 'library.lampdb', 'main');
      writeFile(temp, 'library.lampdb-wal', 'wal');
      writeFile(temp, 'library.db-wal', 'orphan');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.moved);
      final File target = File(libraryDbPath(temp));
      expect(target.readAsStringSync(), 'main');
      expect(File('${target.path}-wal').readAsStringSync(), 'wal');
    });

    test('崩在「sidecar 搬完、主库还没搬」时，下次启动补完且不丢 WAL', () async {
      // 模拟上次迁移：WAL 已搬到新名字，主库还在旧名字
      final File legacy = writeFile(temp, 'library.lampdb', 'main');
      writeFile(temp, 'library.db-wal', 'wal-already-moved');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.moved);

      expect(legacy.existsSync(), isFalse);
      final File target = File(libraryDbPath(temp));
      expect(target.readAsStringSync(), 'main');
      expect(
        File('${target.path}-wal').readAsStringSync(),
        'wal-already-moved',
        reason: '已经搬过去的 WAL 不能被当成孤儿删掉',
      );
    });

    test('文件被占用时回滚并返回 blocked，旧库原样保留', () async {
      final File legacy = writeFile(temp, 'library.lampdb', 'main');
      final File legacyWal = writeFile(temp, 'library.lampdb-wal', 'wal');
      // 目标位置被一个目录占住，rename 必然抛 FileSystemException
      blockPath(temp, 'library.db-wal');

      expect(await migrateLegacyLibrary(temp), LibraryMigration.blocked);

      expect(legacy.readAsStringSync(), 'main');
      expect(legacyWal.readAsStringSync(), 'wal');
      expect(File(libraryDbPath(temp)).existsSync(), isFalse);
    });
  });
}

/// 在目录里写一个文本文件。
File writeFile(Directory dir, String name, String content) =>
    File('${dir.path}${Platform.pathSeparator}$name')
      ..writeAsStringSync(content);

/// 用「非空目录」占住某个路径，让指向它的 rename / delete 必然失败。
///
/// Windows 与 POSIX 上 rename 到已存在的目录都会抛 [FileSystemException]，
/// 用来模拟「文件被别的进程占住」。
void blockPath(Directory dir, String name) {
  final Directory blocker = Directory(
    '${dir.path}${Platform.pathSeparator}$name',
  )..createSync(recursive: true);
  File('${blocker.path}${Platform.pathSeparator}keep.txt')
      .writeAsStringSync('keep');
}

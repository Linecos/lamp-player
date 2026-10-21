// 曲库启动链路的纯 Dart 测试：目录解析不依赖 FFI，`flutter test` 就能跑。
// 真实 initDb 的行为在 rust/tests/db.rs 与 integration_test 里验证。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_db.dart';

void main() {
  group('libraryDbPath', () {
    test('拼在支持目录下，文件名固定', () {
      final Directory dir = Platform.isWindows
          ? Directory(r'C:\Users\lan\AppData\Roaming\Lamp Player')
          : Directory('/home/lan/AppData/Lamp Player');
      final String path = libraryDbPath(dir);
      expect(path.endsWith('library.lampdb'), isTrue);
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
      expect(dbPath.endsWith('library.lampdb'), isTrue);
    });

    test('已存在的目录不报错，路径保持一致', () async {
      final String first = await resolveLibraryDbPath(temp);
      final String second = await resolveLibraryDbPath(temp);

      expect(first, second);
    });
  });
}

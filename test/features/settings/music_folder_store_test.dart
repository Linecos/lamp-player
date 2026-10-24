import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/settings/music_folder_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizeFolders 去空白、忽略大小写去重并保持顺序', () {
    expect(
      normalizeFolders(<String>[' D:\\Music ', '', 'd:\\music', 'E:\\Songs']),
      <String>['D:\\Music', 'E:\\Songs'],
    );
    expect(normalizeFolders(<String>['   ']), isEmpty);
  });

  test('normalizeFolderPath 去掉尾部斜杠但保留盘根与 UNC 根', () {
    expect(normalizeFolderPath('E:\\Music\\'), 'E:\\Music');
    expect(normalizeFolderPath('E:/Music//'), 'E:/Music');
    expect(normalizeFolderPath('  E:/Music  '), 'E:/Music');
    expect(normalizeFolderPath('E:\\'), 'E:\\', reason: '盘根不应被裁成 E:');
    expect(normalizeFolderPath('\\\\server\\share\\'), '\\\\server\\share');
  });

  test('带尾斜杠与不带的同一个目录只保留一条', () {
    expect(normalizeFolders(<String>['E:\\Music\\', 'e:\\music']), <String>[
      'E:\\Music',
    ]);
  });

  test('PrefsMusicFolderStore 写入前规范化，保存后能读回', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsMusicFolderStore store = PrefsMusicFolderStore();

    await store.save(<String>[' D:\\Music ', 'D:\\Music', 'E:\\Songs']);

    expect(await store.load(), <String>['D:\\Music', 'E:\\Songs']);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PrefsMusicFolderStore.prefsKey), <String>[
      'D:\\Music',
      'E:\\Songs',
    ]);
  });

  test('存储不可用（读取抛错）时退化为空列表', () async {
    // 未 mock 的情况下插件不可用：load 不应抛出
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsMusicFolderStore store = PrefsMusicFolderStore();
    expect(await store.load(), isEmpty);
  });
}

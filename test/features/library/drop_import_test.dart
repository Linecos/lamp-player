import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/drop_import.dart';

void main() {
  String parentOf(String path) => path.substring(0, path.lastIndexOf('\\'));

  bool isDirectory(String path) => !path.contains('.');

  test('文件夹取自身，文件取所在目录', () {
    final List<String> folders = foldersFromDropPaths(
      <String>[r'D:\Music', r'D:\Music\夜航.mp3', r'E:\Songs\潮汐.flac'],
      isDirectory: isDirectory,
      parentOf: parentOf,
    );

    expect(folders, <String>[r'D:\Music', r'E:\Songs']);
  });

  test('同一目录下的多个文件只扫描一次，且忽略大小写差异', () {
    final List<String> folders = foldersFromDropPaths(
      <String>[r'D:\Music\a.mp3', r'd:\music\b.mp3', r'D:\Music'],
      isDirectory: (String path) => path == r'D:\Music',
      parentOf: parentOf,
    );

    expect(folders, <String>[r'D:\Music']);
  });

  test('忽略空路径与取不到父目录的项', () {
    final List<String> folders = foldersFromDropPaths(
      <String>['  ', '', 'plainfile'],
      isDirectory: (String _) => false,
      parentOf: (String path) =>
          path.contains('\\') ? path.substring(0, path.lastIndexOf('\\')) : '',
    );

    expect(folders, isEmpty);
  });
}

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

  test('非音频文件不把它所在目录拖进曲库', () {
    // 误拖一个文档就把它所在的桌面 / 下载目录整个加进来并全盘扫描，
    // 代价太大：文件必须带音频扩展名才认
    final List<String> folders = foldersFromDropPaths(
      <String>[
        r'C:\Users\me\Desktop\季度报告.docx',
        r'C:\Users\me\Desktop\cover.jpg',
        r'C:\Users\me\Desktop\无扩展名',
        r'D:\Music\夜航.MP3',
      ],
      isDirectory: (String _) => false,
      parentOf: parentOf,
    );

    expect(folders, <String>[r'D:\Music'], reason: '扩展名大小写不敏感');
  });

  test('目录名里的点不算扩展名', () {
    final List<String> folders = foldersFromDropPaths(
      <String>[r'D:\Music\Best.of.2020\夜航.mp3'],
      isDirectory: (String _) => false,
      parentOf: parentOf,
    );

    expect(folders, <String>[r'D:\Music\Best.of.2020']);
  });
}

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/music_tag.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

/// 造一个真实存在的 MusicTag.exe（内容无所谓，只看路径可执行判断）
String _createExe() {
  final Directory dir = Directory.systemTemp.createTempSync('lamp_musictag_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return (File(p.join(dir.path, 'MusicTag.exe'))..writeAsStringSync('')).path;
}

MusicTagLauncher _launcher({
  required FakeMusicTagStore store,
  required List<(String, List<String>)> launched,
  String? pick,
  List<String> candidates = const <String>[],
  bool supported = true,
}) {
  return MusicTagLauncher(
    // 显式打开：CI 跑在 Linux 上，默认值会是 false
    isSupported: supported,
    store: store,
    start: (String exe, List<String> args) async => launched.add((exe, args)),
    picker: () async => pick,
    candidates: () async => candidates,
  );
}

Future<void> _openMenu(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first, buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('右键「用 MusicTag 打开」会把文件路径交给 MusicTag，并可刷新曲库', (
    WidgetTester tester,
  ) async {
    final String exe = _createExe();
    final List<(String, List<String>)> launched = <(String, List<String>)>[];
    final FakeMusicTagStore store = FakeMusicTagStore(exe);
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      musicTagLauncher: _launcher(store: store, launched: launched),
    );

    await _openMenu(tester, '夜航');
    expect(find.text('用 MusicTag 打开'), findsOneWidget);

    await tester.tap(find.text('用 MusicTag 打开'));
    await tester.pumpAndSettle();

    expect(launched.length, 1);
    expect(launched.single.$1, exe);
    expect(launched.single.$2, <String>['/music/夜航.mp3']);
    expect(find.textContaining('已用 MusicTag 打开：夜航'), findsOneWidget);

    await tester.tap(find.text('改完了，刷新'));
    await tester.pumpAndSettle();

    expect(
      repository.scannedFolders,
      contains(p.dirname('/music/夜航.mp3')),
      reason: '刷新应重扫该曲目所在目录',
    );
    expect(find.text('已刷新曲库'), findsOneWidget);
  });

  testWidgets('找不到 MusicTag 时引导选择一次，选完记住并打开', (WidgetTester tester) async {
    final String exe = _createExe();
    final List<(String, List<String>)> launched = <(String, List<String>)>[];
    final FakeMusicTagStore store = FakeMusicTagStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      musicTagLauncher: _launcher(store: store, launched: launched, pick: exe),
    );

    await _openMenu(tester, '夜航');
    await tester.tap(find.text('用 MusicTag 打开'));
    await tester.pumpAndSettle();

    expect(find.text('没有找到 MusicTag'), findsOneWidget, reason: '未配置时应弹引导');
    expect(launched, isEmpty);

    await tester.tap(find.text('选择 MusicTag.exe'));
    await tester.pumpAndSettle();

    expect(store.path, exe, reason: '选好的路径要记住');
    expect(launched.single.$1, exe);
    expect(launched.single.$2, <String>['/music/夜航.mp3']);
  });

  testWidgets('引导框点取消则不启动、只提示一次', (WidgetTester tester) async {
    final List<(String, List<String>)> launched = <(String, List<String>)>[];
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      musicTagLauncher: _launcher(
        store: FakeMusicTagStore(),
        launched: launched,
      ),
    );

    await _openMenu(tester, '夜航');
    await tester.tap(find.text('用 MusicTag 打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(launched, isEmpty);
    expect(find.text('没有打开：还没指定 MusicTag.exe'), findsOneWidget);
  });

  testWidgets('非 Windows 平台只提示不支持，不尝试启动', (WidgetTester tester) async {
    final List<(String, List<String>)> launched = <(String, List<String>)>[];
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      musicTagLauncher: _launcher(
        store: FakeMusicTagStore(_createExe()),
        launched: launched,
        supported: false,
      ),
    );

    await _openMenu(tester, '夜航');
    await tester.tap(find.text('用 MusicTag 打开'));
    await tester.pumpAndSettle();

    expect(launched, isEmpty);
    expect(find.text('当前平台暂不支持外部标签编辑器'), findsOneWidget);
    expect(find.text('没有找到 MusicTag'), findsNothing);
  });

  testWidgets('常见目录里能找到 MusicTag 时不用问用户', (WidgetTester tester) async {
    final String exe = _createExe();
    final List<(String, List<String>)> launched = <(String, List<String>)>[];
    final FakeMusicTagStore store = FakeMusicTagStore();
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      musicTagLauncher: _launcher(
        store: store,
        launched: launched,
        candidates: <String>[exe],
      ),
    );

    await _openMenu(tester, '夜航');
    await tester.tap(find.text('用 MusicTag 打开'));
    await tester.pumpAndSettle();

    expect(find.text('没有找到 MusicTag'), findsNothing);
    expect(launched.single.$1, exe);
    expect(store.path, exe, reason: '自动找到的路径也要记住');
  });
}

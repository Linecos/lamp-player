import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/track_list_view.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

/// D:\Music 里两首、E:\Songs 里一首
List<Track> _twoFolders() => <Track>[
  sampleTrack(title: '夜航', album: '第一张', path: r'D:\Music\a.mp3'),
  sampleTrack(title: '灯下', album: '第一张', path: r'D:\Music\b.mp3'),
  sampleTrack(title: '潮汐记', album: '第二张', path: r'E:\Songs\c.mp3'),
];

FakeMusicFolderStore _store() =>
    FakeMusicFolderStore(folders: <String>[r'D:\Music', r'E:\Songs']);

Finder _rowOf(String folder) => find.descendant(
  of: find.byKey(const ValueKey<String>('library-panel-folders')),
  matching: find.text(folder),
);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点目录行进入子页，只列这个目录的曲目', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: _twoFolders(), folderStore: _store());
    await openLibrarySettings(tester);

    await tester.tap(_rowOf(r'D:\Music'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('folder-detail-back')), findsOne);
    expect(find.text('2 首'), findsWidgets);
    final Finder list = find.byType(TrackListView);
    expect(list, findsOneWidget);
    expect(
      find.descendant(of: list, matching: find.text('夜航')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: list, matching: find.text('灯下')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: list, matching: find.text('潮汐记')),
      findsNothing,
      reason: '另一个目录的曲目不该出现',
    );
  });

  testWidgets('子页里播放全部只放这个目录', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: _twoFolders(),
      folderStore: _store(),
      playback: playback,
    );
    await openLibrarySettings(tester);
    await tester.tap(_rowOf(r'D:\Music'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('播放全部'));
    await tester.pumpAndSettle();

    // 列表按当前排序（拼音升序）：灯下 deng 排在 夜航 ye 前面
    expect(playback.playedPaths, <String>[r'D:\Music\b.mp3']);
  });

  testWidgets('子页里多选只勾这个目录的曲目', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: _twoFolders(), folderStore: _store());
    await openLibrarySettings(tester);
    await tester.tap(_rowOf(r'D:\Music'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('library-selection-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('track-select-all')));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 首'), findsOneWidget);
  });

  testWidgets('返回按钮与 Esc 都回到音乐库首页', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: _twoFolders(), folderStore: _store());
    await openLibrarySettings(tester);
    await tester.tap(_rowOf(r'D:\Music'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('folder-detail-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('folder-detail-back')),
      findsNothing,
    );
    expect(find.text('音乐目录'), findsOneWidget);

    await tester.tap(_rowOf(r'E:\Songs'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('folder-detail-back')), findsOne);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('folder-detail-back')),
      findsNothing,
    );
    expect(find.text('音乐目录'), findsOneWidget);
  });

  testWidgets('子页里搜索提示是「搜索音乐」，输入只筛这个目录', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: _twoFolders(), folderStore: _store());
    await openLibrarySettings(tester);
    await tester.tap(_rowOf(r'D:\Music'));
    await tester.pumpAndSettle();

    expect(find.text('搜索音乐'), findsOneWidget);

    await _search(tester, '灯下');
    expect(find.text('找到 1 首'), findsOneWidget);
    expect(find.text('夜航'), findsNothing);
  });
}

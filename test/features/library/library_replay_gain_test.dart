import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

Future<void> _enterSelectionAndSelectAll(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('library-selection-toggle')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('全选'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('多选「计算 ReplayGain」：确认后逐首写入并重扫受影响目录', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    )..analyzedGain = -6.5;
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
    );

    await _enterSelectionAndSelectAll(tester);
    expect(find.byTooltip('计算 ReplayGain'), findsOneWidget);

    await tester.tap(find.byTooltip('计算 ReplayGain'));
    await tester.pumpAndSettle();
    expect(find.textContaining('计算 2 首曲目的 ReplayGain'), findsOneWidget);

    await tester.tap(find.text('开始计算'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains.length, 2, reason: '每首都要写入一次');
    expect(repository.writtenGains.values, everyElement(-6.5));
    expect(repository.scannedFolders, isNotEmpty, reason: '写标签后要重扫受影响目录');
    expect(find.textContaining('已写入 2 首'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing, reason: '进度框应已关闭');
  });

  testWidgets('确认框点取消不写任何文件', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: true),
    );

    await _enterSelectionAndSelectAll(tester);
    await tester.tap(find.byTooltip('计算 ReplayGain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains, isEmpty);
    expect(repository.scannedFolders, isEmpty);
  });

  testWidgets('文件只读写不进去时报失败数，其余曲目照常进行', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: FakePlaybackService(isAvailable: true),
    );
    repository.writeGainError = StateError('文件只读');

    await _enterSelectionAndSelectAll(tester);
    await tester.tap(find.byTooltip('计算 ReplayGain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始计算'));
    await tester.pumpAndSettle();

    expect(repository.writtenGains, isEmpty);
    expect(find.textContaining('2 首失败'), findsOneWidget);
  });

  testWidgets('没选曲目时按钮不可点', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(
      find.byKey(const ValueKey<String>('library-selection-toggle')),
    );
    await tester.pumpAndSettle();

    final IconButton button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.graphic_eq),
    );
    expect(button.onPressed, isNull);
  });
}

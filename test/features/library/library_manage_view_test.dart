import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/views/library_manage_view.dart';
import 'package:lamp_player/src/rust/api/scan.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

const ScanReport _sampleReport = ScanReport(
  scanned: 5,
  unchanged: 2,
  upserted: 3,
  failed: 1,
  walkErrors: 0,
  pruned: 1,
  elapsedMs: 1500,
);

Future<void> _pumpManage(
  WidgetTester tester, {
  int trackCount = 0,
  bool scanning = false,
  List<String> folders = const <String>[],
  String? folder,
  ScanReport? report,
  Object? error,
  VoidCallback? onAddFolder,
  VoidCallback? onRetry,
  VoidCallback? onOpenStats,
  ValueChanged<String>? onRescanFolder,
  ValueChanged<String>? onRemoveFolder,
  String query = '',
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: LibraryManageView(
          trackCount: trackCount,
          scanning: scanning,
          folders: folders,
          scanFolder: folder,
          scanReport: report,
          scanError: error,
          onAddFolder: onAddFolder,
          onRetry: onRetry,
          onOpenStats: onOpenStats,
          onRescanFolder: onRescanFolder,
          onRemoveFolder: onRemoveFolder,
          query: query,
        ),
      ),
    ),
  );
  if (scanning) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('曲目数量与听歌统计入口都在音乐库里', (WidgetTester tester) async {
    int opened = 0;
    await _pumpManage(tester, trackCount: 125, onOpenStats: () => opened += 1);

    expect(find.text('曲目数量'), findsOneWidget);
    expect(find.text('125 首'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('library-open-stats')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('点击添加音乐目录触发选择回调', (WidgetTester tester) async {
    int calls = 0;
    await _pumpManage(tester, onAddFolder: () => calls += 1);

    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('扫描中显示进度并禁用入口', (WidgetTester tester) async {
    int calls = 0;
    await _pumpManage(
      tester,
      scanning: true,
      folder: r'C:\Music',
      onAddFolder: () => calls += 1,
    );

    expect(find.text(r'正在扫描 C:\Music'), findsOneWidget);
    expect(find.text('正在扫描…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    await tester.tap(find.text('添加音乐目录'));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('扫描完成展示统计', (WidgetTester tester) async {
    await _pumpManage(tester, folder: r'C:\Music', report: _sampleReport);

    expect(find.text('扫描完成'), findsOneWidget);
    expect(find.textContaining('入库 3 首'), findsOneWidget);
    expect(find.textContaining('失败 1 个'), findsOneWidget);
    expect(find.text(r'C:\Music'), findsOneWidget);
    expect(find.text('耗时 1.5 秒'), findsOneWidget);
  });

  testWidgets('扫描失败展示重试', (WidgetTester tester) async {
    int retries = 0;
    await _pumpManage(
      tester,
      folder: r'C:\Music',
      error: Exception('目录不可读'),
      onRetry: () => retries += 1,
    );

    expect(find.text('扫描失败'), findsOneWidget);
    expect(find.text('目录不可读'), findsOneWidget);

    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('音乐目录为空时显示空态提示', (WidgetTester tester) async {
    await _pumpManage(tester);

    expect(find.text('还没有添加音乐目录，先在上方添加一个'), findsOneWidget);
  });

  testWidgets('目录行提供重新扫描与移除回调', (WidgetTester tester) async {
    final List<String> rescanned = <String>[];
    final List<String> removed = <String>[];
    await _pumpManage(
      tester,
      folders: const <String>['D:/Music', 'E:/Songs'],
      onRescanFolder: rescanned.add,
      onRemoveFolder: removed.add,
    );

    expect(find.text('D:/Music'), findsOneWidget);
    expect(find.text('E:/Songs'), findsOneWidget);
    expect(find.byTooltip('重新扫描'), findsNWidgets(2));

    await tester.tap(find.byTooltip('重新扫描').first);
    await tester.pumpAndSettle();
    expect(rescanned, <String>['D:/Music']);

    await tester.tap(find.byTooltip('从列表移除').last);
    await tester.pumpAndSettle();
    expect(removed, <String>['E:/Songs']);
  });

  testWidgets('搜索词只留命中的行，全不命中时给空态', (WidgetTester tester) async {
    await _pumpManage(tester, query: '统计');

    expect(find.text('听歌统计'), findsOneWidget);
    expect(find.text('添加音乐目录'), findsNothing);

    await _pumpManage(tester, query: '不存在的词');
    expect(find.text('没有匹配的项目'), findsOneWidget);
  });
}

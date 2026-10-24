import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
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

Future<void> _pumpSettings(
  WidgetTester tester, {
  bool scanning = false,
  String? folder,
  ScanReport? report,
  Object? error,
  VoidCallback? onAddFolder,
  VoidCallback? onRetry,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: SettingsView(
          trackCount: 3,
          totalDurationSecs: 180,
          engineAvailable: true,
          scanning: scanning,
          scanFolder: folder,
          scanReport: report,
          scanError: error,
          onAddFolder: onAddFolder,
          onRetry: onRetry,
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
  testWidgets('点击添加音乐目录触发选择回调', (WidgetTester tester) async {
    int calls = 0;
    await _pumpSettings(tester, onAddFolder: () => calls += 1);

    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('扫描中显示进度并禁用入口', (WidgetTester tester) async {
    int calls = 0;
    await _pumpSettings(
      tester,
      scanning: true,
      folder: r'C:\Music',
      onAddFolder: () => calls += 1,
    );

    expect(find.text(r'正在扫描 C:\Music'), findsOneWidget);
    expect(find.text('正在扫描并入库…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    await tester.tap(find.text('添加音乐目录'));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('扫描完成展示统计', (WidgetTester tester) async {
    await _pumpSettings(tester, folder: r'C:\Music', report: _sampleReport);

    expect(find.text('扫描完成'), findsOneWidget);
    expect(find.textContaining('入库 3 首'), findsOneWidget);
    expect(find.textContaining('失败 1 个'), findsOneWidget);
    expect(find.text(r'C:\Music'), findsOneWidget);
    expect(find.text('耗时 1.5 秒'), findsOneWidget);
  });

  testWidgets('扫描失败展示重试', (WidgetTester tester) async {
    int retries = 0;
    await _pumpSettings(
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
}

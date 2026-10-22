import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/settings/library_scan_service.dart';
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

class _FakeScanService implements LibraryScanService {
  _FakeScanService({this.folder, this.error, this.delay});

  final String? folder;
  final Object? error;
  final Duration? delay;

  int pickCalls = 0;
  int scanCalls = 0;
  String? lastFolder;

  @override
  Future<String?> pickFolder() async {
    pickCalls += 1;
    return folder;
  }

  @override
  Future<ScanReport> scanFolder(String folder) async {
    scanCalls += 1;
    lastFolder = folder;
    final Duration? wait = delay;
    if (wait != null) {
      await Future<void>.delayed(wait);
    }
    final Object? failure = error;
    if (failure != null) {
      throw failure;
    }
    return _sampleReport;
  }
}

Future<void> _pumpSettings(
  WidgetTester tester,
  _FakeScanService scanner, {
  ValueChanged<ScanReport>? onScanned,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SettingsView(
          trackCount: 3,
          totalDurationSecs: 180,
          engineAvailable: true,
          scanService: scanner,
          onScanned: onScanned,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('取消选择目录时不触发扫描', (WidgetTester tester) async {
    final _FakeScanService scanner = _FakeScanService();
    await _pumpSettings(tester, scanner);

    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(scanner.pickCalls, 1);
    expect(scanner.scanCalls, 0);
    expect(find.text('扫描完成'), findsNothing);
  });

  testWidgets('扫描中显示进度，完成后展示统计并回调', (WidgetTester tester) async {
    final _FakeScanService scanner = _FakeScanService(
      folder: r'C:\Music',
      delay: const Duration(milliseconds: 200),
    );
    ScanReport? received;
    await _pumpSettings(
      tester,
      scanner,
      onScanned: (ScanReport r) => received = r,
    );

    await tester.tap(find.text('添加音乐目录'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('正在扫描'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('扫描完成'), findsOneWidget);
    expect(find.textContaining('新增 3 首'), findsOneWidget);
    expect(find.textContaining('失败 1 个'), findsOneWidget);
    expect(scanner.lastFolder, r'C:\Music');
    expect(received, isNotNull);
  });

  testWidgets('扫描失败展示重试，点击后重新扫描', (WidgetTester tester) async {
    final _FakeScanService scanner = _FakeScanService(
      folder: r'C:\Music',
      error: StateError('目录不可读'),
    );
    await _pumpSettings(tester, scanner);

    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(find.text('扫描失败'), findsOneWidget);
    expect(scanner.scanCalls, 1);

    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(scanner.scanCalls, 2);
  });
}

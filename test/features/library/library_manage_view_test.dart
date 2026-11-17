import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_revision.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/views/library_manage_view.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/scan.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

const ScanReport _sampleReport = ScanReport(
  scanned: 5,
  unchanged: 2,
  upserted: 3,
  failed: 1,
  walkErrors: 0,
  pruned: 1,
  elapsedMs: 1500,
);

List<Track> _tracksInFolder() {
  return <Track>[
    sampleTrack(title: '夜航', path: r'D:\Music\a.mp3'),
    sampleTrack(title: '灯下', path: r'D:\Music\b.mp3'),
  ];
}

Future<void> _pumpManage(
  WidgetTester tester, {
  List<Track>? tracks,
  List<String> folders = const <String>[r'D:\Music'],
  bool scanning = false,
  String? folder,
  ScanReport? report,
  Object? error,
  bool pruningMissing = false,
  int? prunedCount,
  Object? pruneError,
  VoidCallback? onAddFolder,
  VoidCallback? onRetry,
  VoidCallback? onOpenStats,
  VoidCallback? onPrune,
  ValueChanged<String>? onRescanFolder,
  ValueChanged<String>? onRemoveFolder,
  String query = '',
}) async {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: LibraryManageView(
          tracks: tracks ?? _tracksInFolder(),
          folders: folders,
          scanning: scanning,
          scanFolder: folder,
          scanReport: report,
          scanError: error,
          pruningMissing: pruningMissing,
          prunedMissingCount: prunedCount,
          pruneMissingError: pruneError,
          onAddFolder: onAddFolder,
          onRetry: onRetry,
          onOpenStats: onOpenStats,
          onPruneMissing: onPrune,
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

/// 读某个指标块上显示的数字
String _metric(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

void main() {
  testWidgets('顶部四个指标从曲目算出来', (WidgetTester tester) async {
    await _pumpManage(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', path: r'D:\Music\a.mp3'),
        sampleTrack(
          title: '灯下',
          artist: '陈屿',
          album: '潮汐记',
          path: r'D:\Music\b.mp3',
        ),
        sampleTrack(
          title: '雨落',
          artist: '陈屿',
          album: '潮汐记',
          durationSecs: 60,
          path: r'D:\Music\c.mp3',
        ),
      ],
    );

    expect(find.text('曲目'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    // 专辑 2 张、艺术家 2 位（林间电台 / 陈屿）
    expect(find.text('2'), findsNWidgets(2));
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('总时长'), findsOneWidget);
    expect(find.text('0.1 小时'), findsOneWidget);
  });

  testWidgets('目录卡展示数量与专辑数', (WidgetTester tester) async {
    await _pumpManage(tester);

    expect(find.text(r'D:\Music'), findsOneWidget);
    expect(find.text('2 首'), findsOneWidget);
    expect(find.text('音乐目录'), findsOneWidget);
    expect(find.text('1 个'), findsOneWidget);
  });

  testWidgets('两个块高度固定，不随内容变高', (WidgetTester tester) async {
    await _pumpManage(
      tester,
      folders: const <String>[r'D://Music', r'E://Songs', r'F://Other'],
      tracks: <Track>[
        for (int i = 0; i < 40; i += 1)
          sampleTrack(title: '曲目$i', path: r'D://Music//$i.mp3'),
      ],
    );

    // 251 逻辑像素 = 本机 125% 缩放下标尺上的 314
    expect(tester.panelSize('library-panel-folders').height, 251);
    expect(tester.panelSize('library-panel-hidden').height, 251);
  });

  testWidgets('听歌统计瓷贴可点开统计子页', (WidgetTester tester) async {
    int opened = 0;
    await _pumpManage(tester, onOpenStats: () => opened += 1);

    await tester.tap(find.byKey(const ValueKey<String>('library-open-stats')));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('被隐藏的歌曲单独成块', (WidgetTester tester) async {
    await _pumpManage(tester);

    expect(find.text('被隐藏的歌曲'), findsOneWidget);
    // 测试环境没有 Rust 库：块里给出失败提示而不是崩掉
    expect(find.textContaining('读取失败'), findsOneWidget);
  });

  testWidgets('清理缺失瓷贴展示状态并触发运行', (WidgetTester tester) async {
    int runs = 0;
    await _pumpManage(tester, onPrune: () => runs += 1);

    expect(find.text('还没检查过'), findsOneWidget);
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(runs, 1);

    await _pumpManage(tester, prunedCount: 0, onPrune: () => runs += 1);
    expect(find.text('没有发现缺失文件'), findsOneWidget);

    await _pumpManage(tester, prunedCount: 3, onPrune: () => runs += 1);
    expect(find.text('已清理 3 条'), findsOneWidget);
  });

  testWidgets('隐藏列表跟着曲库变化重拉，面板销毁后不再响应', (WidgetTester tester) async {
    await _pumpManage(tester);
    expect(find.textContaining('读取失败'), findsOneWidget);

    // 在别处隐藏了歌 / 扫描完成：这个块在分区快照里始终活着，只靠
    // initState 拉一次的话新数据永远进不来，所以它得盯着 libraryRevision
    markLibraryChanged();
    await tester.pumpAndSettle();
    expect(find.textContaining('读取失败'), findsOneWidget, reason: '重拉不应崩');

    // 面板跟着页面走掉之后，再通知一次不该碰到已销毁的 State
    await tester.pumpWidget(const SizedBox.shrink());
    markLibraryChanged();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理不可用时仍显示运行按钮，不换成进入箭头', (WidgetTester tester) async {
    // 正在扫描 / 正在清理时 onRun 传的是 null：如果按 onRun 判类型，
    // 这一块会在那几秒里变成可进入的箭头，像换了个功能
    await _pumpManage(tester, onPrune: null);

    expect(find.text('运行'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('library-prune-missing')),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
      reason: '这一块不该变成「可进入」的样子',
    );
  });

  testWidgets('专辑数与专辑分区算的一致（同一个聚合键）', (WidgetTester tester) async {
    // 自己拼 `album|artist` 当键会多算：同一张专辑的艺术家标签只差一个
    // 尾随空格，裸字符串是两条，albumGroupKey 会先 trim 再拼，是一条
    final List<Track> tracks = <Track>[
      sampleTrack(title: 'a', artist: '甲', album: '合辑', path: r'D://M//1.mp3'),
      sampleTrack(title: 'b', artist: '甲 ', album: '合辑', path: r'D://M//2.mp3'),
      sampleTrack(title: 'c', artist: null, album: null, path: r'D://M//3.mp3'),
    ];
    await _pumpManage(tester, tracks: tracks, folders: const <String>[]);

    expect(
      _metric(tester, 'library-count-albums'),
      '${groupTracksByAlbum(tracks).length}',
    );
  });

  testWidgets('艺术家数与艺术家分区算的一致（多艺术家拆开算）', (WidgetTester tester) async {
    // `甲/乙` 在艺术家分区是两个人，没有标签的曲目落进「未知艺术家」；
    // 按裸字符串数只会得到两条
    final List<Track> tracks = <Track>[
      sampleTrack(
        title: 'a',
        artist: '甲/乙',
        album: '合辑',
        path: r'D://M//1.mp3',
      ),
      sampleTrack(title: 'b', artist: null, album: null, path: r'D://M//2.mp3'),
    ];
    await _pumpManage(tester, tracks: tracks, folders: const <String>[]);

    expect(
      _metric(tester, 'library-count-artists'),
      '${groupTracksByArtist(tracks).length}',
    );
  });

  testWidgets('没有目录时给空态与添加入口', (WidgetTester tester) async {
    int added = 0;
    await _pumpManage(
      tester,
      folders: const <String>[],
      tracks: const <Track>[],
      onAddFolder: () => added += 1,
    );

    expect(find.text('还没有添加音乐目录，先在上方添加一个'), findsOneWidget);
    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();
    expect(added, 1);
  });

  testWidgets('扫描中在目录卡里显示进度并禁用重扫', (WidgetTester tester) async {
    await _pumpManage(
      tester,
      scanning: true,
      folder: r'D:\Music',
      onRescanFolder: (String _) {},
    );

    expect(find.textContaining('正在扫描…'), findsOneWidget);
    expect(find.text(r'正在扫描 D:\Music'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
  });

  testWidgets('扫描完成展示统计', (WidgetTester tester) async {
    await _pumpManage(tester, folder: r'D:\Music', report: _sampleReport);

    expect(find.text('扫描完成'), findsOneWidget);
    expect(find.textContaining('入库 3 首'), findsOneWidget);
    expect(find.textContaining('失败 1 个'), findsOneWidget);
    expect(find.textContaining('耗时 1.5 秒'), findsOneWidget);
  });

  testWidgets('扫描失败展示重试', (WidgetTester tester) async {
    int retries = 0;
    await _pumpManage(
      tester,
      folder: r'D:\Music',
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

  testWidgets('目录行的重新扫描与移除回调', (WidgetTester tester) async {
    final List<String> rescanned = <String>[];
    final List<String> removed = <String>[];
    await _pumpManage(
      tester,
      onRescanFolder: rescanned.add,
      onRemoveFolder: removed.add,
    );

    await tester.tap(find.byTooltip('重新扫描'));
    await tester.pumpAndSettle();
    expect(rescanned, <String>[r'D:\Music']);

    await tester.tap(find.byTooltip('从列表移除'));
    await tester.pumpAndSettle();
    expect(removed, <String>[r'D:\Music']);
  });

  testWidgets('搜索词只留路径命中的目录', (WidgetTester tester) async {
    await _pumpManage(
      tester,
      folders: const <String>[r'D:\Music', r'E:\无损'],
      tracks: <Track>[
        sampleTrack(title: '夜航', path: r'D:\Music\a.mp3'),
        sampleTrack(title: '灯下', path: r'E:\无损\b.mp3'),
      ],
      query: '无损',
    );

    expect(find.text(r'E:\无损'), findsOneWidget);
    expect(find.text(r'D:\Music'), findsNothing);
    expect(find.text('2 个'), findsOneWidget);
  });
}

extension on WidgetTester {
  Size panelSize(String key) => getSize(find.byKey(ValueKey<String>(key)));
}

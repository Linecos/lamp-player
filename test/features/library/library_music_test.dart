import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/session_store.dart';
import 'package:lamp_player/src/features/library/library_revision.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
  testWidgets('展示曲目列表与数量', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    expect(find.text('2 首音乐'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);
    expect(find.text('夜之专辑'), findsOneWidget);
    // 两行都在虚拟列表里
    expect(find.text('03:00'), findsWidgets);
  });

  testWidgets('右键单曲可隐藏，菜单项在第一组内', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );

    final Finder row = find.text('夜航');
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(tester.getCenter(row));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('加入歌单…'), findsOneWidget);
    expect(find.text('隐藏歌曲'), findsOneWidget);
    // 位置：排在「加入歌单…」之后、「在资源管理器中显示」之前，即第一组内
    final double removeY = tester.getCenter(find.text('隐藏歌曲')).dy;
    expect(removeY, greaterThan(tester.getCenter(find.text('加入歌单…')).dy));
    expect(removeY, lessThan(tester.getCenter(find.text('在资源管理器中显示')).dy));

    await tester.tap(find.text('隐藏歌曲'));
    await tester.pumpAndSettle();

    expect(repository.hideTracksCalls, 1);
    expect(repository.lastHiddenPaths, hasLength(1));
    expect(find.text('夜航'), findsNothing, reason: '移除后该行应从列表消失');
    expect(find.text('潮汐'), findsOneWidget, reason: '其它曲目不受影响');
  });

  testWidgets('别处恢复隐藏歌曲后曲库自动重载', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    final int before = repository.loadCalls;

    // 设置页里点了「恢复」：仓库里多回一首，然后通知曲库页
    repository.tracks = <Track>[
      ...repository.tracks,
      sampleTrack(title: '回来的'),
    ];
    markLibraryChanged();
    await tester.pumpAndSettle();

    expect(repository.loadCalls, before + 1, reason: '收到通知要重新拉列表');
    expect(find.text('回来的'), findsOneWidget, reason: '恢复的曲子要立刻出现在列表里');
  });

  testWidgets('长按播放键把列表滚回当前曲目', (WidgetTester tester) async {
    final List<Track> tracks = List<Track>.generate(
      30,
      (int index) =>
          sampleTrack(title: '曲目 $index', path: '/music/track_$index.mp3'),
    );
    await pumpLibrary(tester, tracks: tracks);

    // 播放第一首，再把列表拖到底
    await tester.tap(find.text('曲目 0'));
    await tester.pumpAndSettle();

    final Finder list = find.byKey(
      const PageStorageKey<String>('tracks:music'),
    );
    await tester.drag(list, const Offset(0, -2400));
    await tester.pumpAndSettle();
    final double before = tester.widget<ListView>(list).controller!.offset;
    expect(before, greaterThan(200), reason: '先滚到下面才有意义');

    // 长按播放键触发定位：先确认回调确实接上了，再验证手势
    final Finder playBtn = find.byKey(
      const ValueKey<String>('player-play-pause'),
    );
    expect(
      tester.widget<PlayerBar>(find.byType(PlayerBar)).onLocateCurrent,
      isNotNull,
      reason: '播放岛应接上长按定位回调',
    );

    final TestGesture press = await tester.startGesture(
      tester.getCenter(playBtn),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await press.up();
    await tester.pumpAndSettle();

    final double after = tester.widget<ListView>(list).controller!.offset;
    expect(after, lessThan(before), reason: '长按应把列表滚回当前曲目');
    expect(after, lessThan(80), reason: '第一首在列表顶部');
  });

  testWidgets('Windows 的紧凑密度下，排序按钮和「播放全部」一样高', (WidgetTester tester) async {
    // 主题用的是 VisualDensity.adaptivePlatformDensity：桌面平台取 compact，
    // 会把按钮的 minimumSize 高度再削 8（40 → 32）。排序那颗胶囊是手写的
    // Container(height: 40)，不受密度影响，于是真机上就一高一矮。
    // 测试默认跑在 android（standard），不切平台根本测不出这个差异。
    // 这变量必须在测试体结束前还原，放 addTearDown 会被框架判成「改了没还」
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpLibrary(tester, tracks: twoTracks());

      final Rect playAll = tester.getRect(
        find
            .ancestor(
              of: find.text('播放全部'),
              matching: find.byType(FilledButton),
            )
            .first,
      );
      final Rect pill = tester.getRect(
        find.byKey(const ValueKey<String>('library-sort')),
      );

      expect(playAll.height, 40, reason: '桌面密度下别被 compact 削成 32');
      expect(pill.height, 40, reason: '排序胶囊本来就是 40');
      expect(
        playAll.top,
        closeTo(pill.top, 0.5),
        reason: '同一行的两个控件要顶边对齐，不然看着一高一矮',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('排序胶囊：文字靠左、方向箭头自绘、墨迹裁在胶囊里', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    final Rect pill = tester.getRect(
      find.byKey(const ValueKey<String>('library-sort')),
    );

    // 文字块要贴着左端：左段不放前导图标，只有一层内边距
    final Rect label = tester.getRect(
      find.byKey(const ValueKey<String>('library-sort-label')),
    );
    expect(
      label.left - pill.left,
      closeTo(14, 2),
      reason: '文字到胶囊左端应当只有内边距的距离，不留给空占位',
    );

    // 方向箭头是自绘的 CustomPaint：图标字体的 Release 子集一旦过期，
    // Icon 就渲染成空白（实测过），箭头不能赌它
    // （胶囊的 clipBehavior 内部也会生成一个 CustomPaint，所以按 painter 类型挑）
    final Finder arrow = find.descendant(
      of: find.byKey(const ValueKey<String>('library-sort')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is CustomPaint &&
            w.painter != null &&
            w.painter.runtimeType.toString() == '_SortArrowPainter',
      ),
    );
    expect(arrow, findsOneWidget);

    // 墨迹画在胶囊自己的透明 Material 上，才会被胶囊圆角裁住；
    // 不垫这层的话高亮一路画到 Scaffold 的 Material 上，跨出胶囊
    final Finder ink = find.descendant(
      of: find.byKey(const ValueKey<String>('library-sort')),
      matching: find.byType(Material),
    );
    expect(ink, findsOneWidget);
    expect(tester.widget<Material>(ink).type, MaterialType.transparency);

    // 左段的悬停高亮要铺满整段：InkWell 高亮跟着 child 走，
    // child 不撑到胶囊高度的话就只有贴着文字的一条
    final Iterable<Rect> inkRects = find
        .descendant(
          of: find.byKey(const ValueKey<String>('library-sort')),
          matching: find.byType(InkWell),
        )
        .evaluate()
        .map(
          (Element element) =>
              (element.renderObject! as RenderBox).localToGlobal(Offset.zero) &
              (element.renderObject! as RenderBox).size,
        );
    expect(inkRects, isNotEmpty);
    // 胶囊 40 高，但 1px 边框会把内容区压到 38：高亮铺满内容区就是对的
    final double innerHeight = pill.height - 2;
    expect(
      inkRects.every((Rect rect) => (rect.height - innerHeight).abs() < 0.5),
      isTrue,
      reason: '两个分段的墨迹都要铺满内容区（40 减去边框）',
    );
  });

  testWidgets('定位：Ctrl+L 也能触发，目标行短暂高亮', (WidgetTester tester) async {
    final List<Track> tracks = List<Track>.generate(
      30,
      (int index) =>
          sampleTrack(title: '曲目 $index', path: '/music/track_$index.mp3'),
    );
    await pumpLibrary(tester, tracks: tracks);

    await tester.tap(find.text('曲目 0'));
    await tester.pumpAndSettle();

    final Finder list = find.byKey(
      const PageStorageKey<String>('tracks:music'),
    );
    await tester.drag(list, const Offset(0, -2400));
    await tester.pumpAndSettle();
    final double before = tester.widget<ListView>(list).controller!.offset;
    expect(before, greaterThan(200));

    // 快捷键与按钮走同一条路径
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      tester.widget<ListView>(list).controller!.offset,
      lessThan(before),
      reason: 'Ctrl+L 应把列表滚回当前曲目',
    );

    /// 目标行外面那层强调容器（静止时是透明）
    Color flashColor() {
      final BoxDecoration decoration =
          tester
                  .widget<AnimatedContainer>(
                    find
                        .ancestor(
                          of: find.text('曲目 0'),
                          matching: find.byType(AnimatedContainer),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      return decoration.color!;
    }

    expect(flashColor().a, greaterThan(0), reason: '定位后目标行要亮一下');

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(flashColor().a, 0, reason: '短暂高亮后自动熄灭');
  });

  testWidgets('收藏分区也能定位正在播放的曲目', (WidgetTester tester) async {
    final List<Track> tracks = List<Track>.generate(
      30,
      (int index) =>
          sampleTrack(title: '曲目 $index', path: '/music/track_$index.mp3'),
    );
    await pumpLibrary(
      tester,
      tracks: tracks,
      seed: (FakeLibraryRepository repo) async {
        await repo.setFavorites(
          tracks.map((Track track) => track.path).toList(),
          true,
        );
      },
    );

    await tester.tap(find.text('曲目 0'));
    await tester.pumpAndSettle();
    await openFavorites(tester);

    final Finder list = find.byKey(
      const PageStorageKey<String>('tracks:favorites'),
    );
    await tester.drag(list, const Offset(0, -2400));
    await tester.pumpAndSettle();
    final double before = tester.widget<ListView>(list).controller!.offset;
    expect(before, greaterThan(200));

    // 收藏分区同样能在播放岛上长按定位（回调按分区切换）
    await tester.longPress(
      find.byKey(const ValueKey<String>('player-play-pause')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<ListView>(list).controller!.offset,
      lessThan(before),
      reason: '收藏分区的列表要滚回当前曲目',
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('艺术家详情页也能定位正在播放的曲目', (WidgetTester tester) async {
    final List<Track> tracks = List<Track>.generate(
      30,
      (int index) => sampleTrack(
        title: '曲目 $index',
        path: '/music/track_$index.mp3',
        artist: '林间电台',
        album: '夜之专辑',
      ),
    );
    await pumpLibrary(tester, tracks: tracks);

    await tester.tap(find.text('曲目 0'));
    await tester.pumpAndSettle();

    // 切到艺术家分区并进详情：这里以前会提示「当前没有正在播放的曲目」
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    // 播放岛的副标题也叫这个艺术家，只在艺术家网格里点
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('artists-list')),
        matching: find.text('林间电台'),
      ),
    );
    await tester.pumpAndSettle();

    final Finder list = find.byKey(
      const PageStorageKey<String>('tracks:artist:林间电台'),
    );
    await tester.drag(list, const Offset(0, -2400));
    await tester.pumpAndSettle();
    final double before = tester.widget<ListView>(list).controller!.offset;
    expect(before, greaterThan(200));

    await tester.longPress(
      find.byKey(const ValueKey<String>('player-play-pause')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<ListView>(list).controller!.offset,
      lessThan(before),
      reason: '艺术家详情里的列表同样要滚回当前曲目',
    );
    expect(find.text('当前没有正在播放的曲目'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('专辑详情页也能定位正在播放的曲目', (WidgetTester tester) async {
    final List<Track> tracks = List<Track>.generate(
      30,
      (int index) => sampleTrack(
        title: '曲目 $index',
        path: '/music/track_$index.mp3',
        artist: '林间电台',
        album: '夜之专辑',
      ),
    );
    await pumpLibrary(tester, tracks: tracks);

    await tester.tap(find.text('曲目 0'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.library_books_outlined));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();

    // 专辑分组的 key 是「艺术家\u0000专辑」拼出来的（见 albumGroupKey）
    final Finder list = find.byKey(
      const PageStorageKey<String>('tracks:album:林间电台\u0000夜之专辑'),
    );
    await tester.drag(list, const Offset(0, -2400));
    await tester.pumpAndSettle();
    final double before = tester.widget<ListView>(list).controller!.offset;
    expect(before, greaterThan(200));

    await tester.longPress(
      find.byKey(const ValueKey<String>('player-play-pause')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<ListView>(list).controller!.offset,
      lessThan(before),
      reason: '专辑详情里的列表同样要滚回当前曲目',
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('空曲库展示空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: const <Track>[]);

    expect(find.text('曲库还是空的'), findsOneWidget);
    expect(find.text('重新读取'), findsOneWidget);
  });

  testWidgets('升级后缺封面时自动补扫已添加目录一次', (WidgetTester tester) async {
    final FakeMusicFolderStore folders = FakeMusicFolderStore(
      folders: <String>[r'D:\Music'],
    );
    final FakeSessionStore session = FakeSessionStore(
      snapshot: const SessionSnapshot(coverBackfillAttempted: false),
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      folderStore: folders,
      sessionStore: session,
    );

    expect(repository.scannedFolders, <String>[r'D:\Music']);
    expect(session.snapshot.coverBackfillAttempted, isTrue);
    expect(find.byType(SnackBar), findsNothing, reason: '补扫应静默进行');
  });

  testWidgets('已尝试过补扫时启动不再自动扫描', (WidgetTester tester) async {
    final FakeMusicFolderStore folders = FakeMusicFolderStore(
      folders: <String>[r'D:\Music'],
    );
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      folderStore: folders,
    );

    expect(repository.scannedFolders, isEmpty);
  });

  testWidgets('空曲库可添加音乐目录并触发扫描', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: const <Track>[],
      directoryPicker: () async => ' /music ',
    );

    await tester.tap(find.text('添加音乐目录'));
    await tester.pumpAndSettle();

    expect(repository.scannedFolders, <String>['/music']);
    expect(repository.loadCalls, 2, reason: '扫描后应重新读取曲库');
    expect(find.textContaining('扫描完成'), findsOneWidget);
  });

  testWidgets('读取失败展示错误态，重试后恢复', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
      configure: (FakeLibraryRepository repo) {
        repo.loadError = Exception('数据库打不开');
      },
    );

    expect(find.text('曲库读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    repository.loadError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('夜航'), findsOneWidget);
  });

  testWidgets('搜索输入防抖 300ms 后才发起请求', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );

    await tester.enterText(find.byType(TextField), '夜');
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.searchCalls, 0, reason: '防抖窗口内不应请求');

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(repository.searchCalls, 1);
    expect(repository.lastQuery, '夜');
    expect(find.text('找到 1 首'), findsOneWidget);
    expect(find.text('潮汐'), findsNothing);
  });

  testWidgets('拼音首字母也能搜到中文曲目', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    // 假仓库按字面匹配，'yh' 不会命中「夜航」；拼音兜底应当补上
    await tester.enterText(find.byType(TextField), 'yh');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('找到 1 首'), findsOneWidget);
    expect(find.text('夜航'), findsWidgets);
    expect(find.text('潮汐'), findsNothing);
  });

  testWidgets('搜索命中超过 500 条时提示 500+', (WidgetTester tester) async {
    final List<Track> many = <Track>[
      for (int index = 0; index < 501; index += 1)
        sampleTrack(title: '夜航 $index', path: '/music/$index.mp3'),
    ];
    await pumpLibrary(tester, tracks: many);

    await tester.enterText(find.byType(TextField), '夜航');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('找到 500+ 首（仅显示前 500）'), findsOneWidget);
  });

  testWidgets('清空搜索恢复完整列表', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.enterText(find.byType(TextField), '夜');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('潮汐'), findsNothing);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    expect(find.text('2 首音乐'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);
  });

  testWidgets('搜索无结果展示空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.enterText(find.byType(TextField), '不存在的歌');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('没有找到匹配的音乐'), findsOneWidget);
  });

  testWidgets('搜索失败展示错误态，重试后恢复', (WidgetTester tester) async {
    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    repository.searchError = Exception('FTS 语法错误');

    await tester.enterText(find.byType(TextField), '夜');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('搜索失败'), findsOneWidget);

    repository.searchError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('找到 1 首'), findsOneWidget);
  });

  testWidgets('艺术家分区可聚合并进入详情、返回', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[
      ...twoTracks(),
      sampleTrack(title: '灯下', artist: '林间电台', album: '夜之专辑'),
    ];
    await pumpLibrary(tester, tracks: tracks);

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();

    expect(find.text('2 位艺术家'), findsOneWidget);
    expect(find.text('1 张专辑 · 2 首'), findsOneWidget);

    await tester.tap(find.text('林间电台'));
    await tester.pumpAndSettle();

    expect(find.text('1 张专辑 · 2 首音乐'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('2 位艺术家'), findsOneWidget);
  });

  testWidgets('首次进入艺术家分区直接显示真实数据，不闪空快照', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        ...twoTracks(),
        sampleTrack(title: '灯下', artist: '林间电台', album: '夜之专辑'),
      ],
    );

    await tester.tap(find.byIcon(Icons.person_outline));
    // 第一帧只换侧栏高亮，第二帧才切内容
    await tester.pump();
    await tester.pump();

    expect(find.text('0 位艺术家'), findsNothing, reason: '从未访问过的分区不该用空曲库建快照');
    expect(find.text('2 位艺术家'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('2 位艺术家'), findsOneWidget);
  });

  testWidgets('音乐分区右键加入歌单能看到已有歌单', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      playback: playback,
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('晨间');
      },
    );

    // 页面停在「音乐」分区，从未进入歌单页
    await tester.tap(find.text('夜航').first, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入歌单…'));
    await tester.pumpAndSettle();

    expect(find.text('晨间'), findsOneWidget, reason: '应能列出已有歌单');
    expect(find.text('还没有歌单，点右下角新建一个。'), findsNothing);

    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();
    expect(find.text('已加入「晨间」'), findsOneWidget);
  });

  testWidgets('启动时恢复上次选择的排序方式', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: 'B 曲', artist: '甲'),
        sampleTrack(title: 'A 曲', artist: '乙'),
      ],
      sessionStore: FakeSessionStore(
        snapshot: const SessionSnapshot(sort: LibrarySort.title),
      ),
    );

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('library-sort-label')),
          )
          .data,
      '标题',
    );
    final double aY = tester.getTopLeft(find.text('A 曲')).dy;
    final double bY = tester.getTopLeft(find.text('B 曲')).dy;
    expect(aY, lessThan(bY), reason: '应按标题排序，而不是保留默认顺序');
  });

  testWidgets('切换排序方式会写回会话', (WidgetTester tester) async {
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(tester, tracks: twoTracks(), sessionStore: session);

    await tester.tap(find.byKey(const ValueKey<String>('library-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('艺术家').last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('library-sort-label')),
          )
          .data,
      '艺术家',
    );
    expect(session.snapshot.sort, LibrarySort.artist);
  });

  testWidgets('拖入文件夹会复用扫描流程并显示导入结果', (WidgetTester tester) async {
    final Directory dropped = Directory.systemTemp.createTempSync('lamp_drop_');
    addTearDown(() => dropped.deleteSync(recursive: true));

    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: const <Track>[],
    );

    Future<void> sendDropEvent(String method, Object arguments) async {
      final ByteData data = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop',
        data,
        (ByteData? _) {},
      );
    }

    await sendDropEvent('entered', <double>[100, 100]);
    await tester.pump();
    expect(find.text('松开即可导入音乐'), findsOneWidget);

    await sendDropEvent('performOperation', <String>[dropped.path]);
    await tester.pumpAndSettle();

    expect(find.text('松开即可导入音乐'), findsNothing);
    expect(repository.scannedFolders, <String>[dropped.path]);
    expect(find.textContaining('导入完成'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('扫描后的静默刷新不会闪加载态', (WidgetTester tester) async {
    final Directory dropped = Directory.systemTemp.createTempSync(
      'lamp_silent_',
    );
    addTearDown(() => dropped.deleteSync(recursive: true));

    final FakeLibraryRepository repository = await pumpLibrary(
      tester,
      tracks: twoTracks(),
    );
    // 挂住扫描后的那次读取，模拟大曲库读得慢
    repository.loadGate = Completer<void>();

    Future<void> sendDropEvent(String method, Object arguments) async {
      final ByteData data = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop',
        data,
        (ByteData? _) {},
      );
    }

    await sendDropEvent('entered', <double>[100, 100]);
    await tester.pump();
    await sendDropEvent('performOperation', <String>[dropped.path]);
    // 扫描已经结束，刷新还挂在 loadGate 上；这里不能 pumpAndSettle，
    // 扫描中的进度圈会一直转
    await tester.pump();
    await tester.pump();

    expect(repository.scannedFolders, <String>[dropped.path]);
    expect(find.text('正在读取曲库…'), findsNothing, reason: '静默刷新不该把列表换成加载态');
    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);

    repository.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('导入完成'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

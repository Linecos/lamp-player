import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/alphabet_index.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/alphabet_grid.dart';
import 'package:lamp_player/src/features/library/widgets/collection_grids.dart';
import 'package:lamp_player/src/features/library/widgets/cover_flight.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

ArtistGroup _artist(String name) => ArtistGroup(
  name: name,
  tracks: <Track>[sampleTrack(title: '曲目', artist: name)],
);

AlbumGroup _album(String title, String artist) {
  final AlbumGroup group = AlbumGroup(
    key: '$artist/$title',
    title: title,
    artist: artist,
  );
  group.tracks.add(
    sampleTrack(title: '$title - 1', artist: artist, album: title),
  );
  return group;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double height = 600,
}) async {
  // 卡片宽度固定 220，比原来「按宽度均分」更大，矮视口里后面几段会来不及建
  // 出来（懒加载），分段断言就会误判成「缺段」
  tester.view.physicalSize = Size(800, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

void main() {
  final List<ArtistGroup> manyArtists = <ArtistGroup>[
    for (final String letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
      for (int i = 0; i < 3; i += 1) _artist('$letter Artist $i'),
  ];

  testWidgets('艺术家按首字母分段，点字母跳到该段', (WidgetTester tester) async {
    await _pump(
      tester,
      ArtistGridView(artists: manyArtists, onSelect: (_, _, _) {}),
    );

    // 初始只能看到 A 段标题，后面的还没滚到
    expect(
      find.byKey(const ValueKey<String>('alphabet-header-A')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('alphabet-header-M')),
      findsNothing,
    );

    final double top = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    await tester.tap(find.byKey(const ValueKey<String>('alphabet-rail-M')));
    await tester.pumpAndSettle();

    final Finder header = find.byKey(
      const ValueKey<String>('alphabet-header-M'),
    );
    expect(header, findsOneWidget);
    // 跳转落点：该段标题正好贴着视口顶部
    expect(tester.getTopLeft(header).dy - top, lessThan(2));
  });

  testWidgets('窗口变窄后位置跟着内容走，加重项还是同一段', (WidgetTester tester) async {
    await _pump(
      tester,
      ArtistGridView(artists: manyArtists, onSelect: (_, _, _) {}),
    );
    await tester.pumpAndSettle();

    String bold() => <String>[
      for (final String letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
        if (tester
                .widget<Text>(
                  find.descendant(
                    of: find.byKey(ValueKey<String>('alphabet-rail-$letter')),
                    matching: find.byType(Text),
                  ),
                )
                .style
                ?.fontWeight ==
            FontWeight.w700)
          letter,
    ].first;

    /// 每段一样高（每个字母下都是 3 位艺术家），按宽度算段高
    double sectionExtent(double width) {
      final AlphabetGridMetrics metrics = AlphabetGridMetrics(
        viewportWidth: width - gridRightReserve,
        tileWidth: 190,
        tileHeight: 246,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        headerExtent: alphabetHeaderExtent,
        topPadding: 8,
      );
      return alphabetHeaderExtent + metrics.gridExtent(3);
    }

    final ScrollableState scrollable = tester.state(
      find.byType(Scrollable).first,
    );
    // 停在 C 段中间（避开段边界，差一像素不会判到隔壁）
    final double pixels = 8 + 2.5 * sectionExtent(800);
    scrollable.position.jumpTo(pixels);
    await tester.pump();
    expect(bold(), 'C');

    // 窗口收窄：列数变了、每段高度翻倍。位置按「你看到的那一条」换算过去，
    // 所以加重项还是 C，只是滚动偏移跟着变大了——不再是「偏移不动、
    // 同一个像素指向别的段」
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(400, 600);
    await tester.pumpAndSettle();
    expect(bold(), 'C', reason: '换几何后位置跟着内容走，看到的还是同一段');
    expect(
      scrollable.position.pixels,
      greaterThan(pixels),
      reason: '每段变高了，同一个锚点对应的偏移也要变大',
    );
  });

  testWidgets('侧栏动画逐帧变宽时，视口顶上那一条始终不动', (WidgetTester tester) async {
    // 侧栏是 220ms 的缓动动画，内容区每帧都在变宽，行高跟着变。
    // 两个要求：
    //   1. 修正必须落在**同一帧**（帧后 jumpTo 会先画错再跳）；
    //   2. 缓动曲线首尾每帧只变零点几像素，那种帧也必须修，否则错位会攒起来，
    //      表现为动画开头和结尾各跳一小下。
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1;

    final ValueNotifier<double> width = ValueNotifier<double>(900);
    addTearDown(width.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<double>(
              valueListenable: width,
              builder: (BuildContext context, double w, Widget? _) => SizedBox(
                width: w,
                height: 600,
                child: ArtistGridView(
                  artists: manyArtists,
                  onSelect: (_, _, _) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final ScrollableState scrollable = tester.state(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(2000);
    await tester.pump();

    // 每个字母下都是 3 位艺术家
    final List<int> counts = List<int>.filled(26, 3);
    AlphabetGridMetrics metricsAt(double w) => AlphabetGridMetrics(
      viewportWidth: w - gridRightReserve,
      tileWidth: 190,
      tileHeight: 246,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      headerExtent: alphabetHeaderExtent,
      topPadding: 8,
    );

    final AlphabetScrollAnchor anchor = alphabetAnchorAt(
      metricsAt(900),
      metricsAt(900).sectionOffsets(counts),
      counts,
      scrollable.position.pixels,
    )!;

    // easeInOutCubic：首尾几乎不动，正是「只变了零点几像素」的那些帧
    double easeInOut(double t) => t < 0.5
        ? 4 * t * t * t
        : 1 - 2 * (2 - 2 * t) * (2 - 2 * t) * (2 - 2 * t) / 2;

    for (int step = 1; step <= 20; step += 1) {
      width.value = 900 + 300 * easeInOut(step / 20);
      await tester.pump(const Duration(milliseconds: 16));

      final AlphabetGridMetrics metrics = metricsAt(width.value);
      final List<double> offsets = metrics.sectionOffsets(counts);
      final double expected = alphabetOffsetOf(metrics, offsets, anchor);
      expect(
        (scrollable.position.pixels - expected).abs(),
        lessThan(1),
        reason:
            '第 $step 帧偏了 ${(scrollable.position.pixels - expected).abs()} 像素',
      );
    }
  });

  testWidgets('跨段滚动只动导航条，整棵网格不重建', (WidgetTester tester) async {
    await _pump(
      tester,
      ArtistGridView(artists: manyArtists, onSelect: (_, _, _) {}),
    );
    await tester.pumpAndSettle();

    /// 加重（w700）的那个字母
    FontWeight? weightOf(String letter) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey<String>('alphabet-rail-$letter')),
            matching: find.byType(Text),
          ),
        )
        .style
        ?.fontWeight;

    // 一开始停在顶部，A 段是当前的
    expect(weightOf('A'), FontWeight.w700);
    final CustomScrollView before = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView).first,
    );

    // 往下滚过 A 段：跨段时只该通知导航条
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();

    final String active = <String>[
      for (final String letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
        if (weightOf(letter) == FontWeight.w700) letter,
    ].first;
    expect(
      active,
      isNot('A'),
      reason:
          '滚过一段之后加重项要跟着走（以前只有滚动通知里 setState 才更新，'
          '位置被恢复或窗口改宽时会对不上）',
    );

    final CustomScrollView after = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView).first,
    );
    expect(
      identical(before, after),
      isTrue,
      reason:
          '跨段时只有导航条要重画：整棵网格跟着 setState 会把二十来个 '
          'SliverGrid 和它们的 delegate 一起重建',
    );
  });

  testWidgets('字母导航贴最右侧但与滚动条保持距离', (WidgetTester tester) async {
    await _pump(
      tester,
      ArtistGridView(artists: manyArtists, onSelect: (_, _, _) {}),
    );

    final Rect rail = tester.getRect(
      find.byKey(const ValueKey<String>('alphabet-rail-A')),
    );
    final Rect viewport = tester.getRect(find.byType(CustomScrollView));

    // 导航条右缘离视口右缘还有一段距离（滚动条就贴在视口边上）
    expect(viewport.right - rail.right, greaterThanOrEqualTo(16));
    // 而且不能跑到视口外面
    expect(rail.right, lessThanOrEqualTo(viewport.right));
  });

  testWidgets('专辑按专辑名首字母分段', (WidgetTester tester) async {
    await _pump(
      tester,
      AlbumGridView(
        albums: <AlbumGroup>[
          _album('夜航', '林间电台'),
          _album('Adele 21', 'Adele'),
          _album('3 Doors', 'Various'),
        ],
        onSelect: (_, _, _) {},
      ),
      height: 1200,
    );

    for (final String letter in <String>['A', 'Y', '#']) {
      expect(
        find.byKey(ValueKey<String>('alphabet-header-$letter')),
        findsOneWidget,
        reason: '缺少 $letter 段',
      );
    }
  });

  testWidgets('侧栏动画途中列数不变，卡片高度不变', (WidgetTester tester) async {
    // 卡片宽度固定：侧栏收起时内容区从 868 连续变到 1000，卡片一个像素都不该
    // 动。列数按最窄那一档（展开态，868）算，整段过渡里也不会中途多挤一列。
    final List<AlbumGroup> albums = <AlbumGroup>[
      for (int i = 0; i < 12; i += 1) _album('专辑 $i', '林间电台'),
    ];

    /// 返回「第一行几张卡」和第一张卡片的尺寸
    Future<(int, Size)> firstRow(double width) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.defaultSeed),
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: 600,
              child: AlbumGridView(albums: albums, onSelect: (_, _, _) {}),
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder covers = find.byType(CoverFlightTarget);
      final List<Rect> rects = <Rect>[
        for (int i = 0; i < covers.evaluate().length; i += 1)
          tester.getRect(covers.at(i)),
      ];
      final double top = rects.first.top;
      final int inRow = rects.where((Rect r) => (r.top - top).abs() < 1).length;
      final Size card = tester.getSize(
        find
            .descendant(
              of: find.byType(AlbumGridView),
              matching: find.byType(InkWell),
            )
            .first,
      );
      return (inRow, card);
    }

    final List<(int, Size)> rows = <(int, Size)>[
      for (final double width in <double>[868, 900, 940, 968, 1000])
        await firstRow(width),
    ];

    for (final (int _, Size card) in rows) {
      expect(
        card.height,
        closeTo(rows.first.$2.height, 0.01),
        reason: '行高是固定值，内容区变宽也不该变',
      );
      expect(
        (card.width - rows.first.$2.width).abs() / rows.first.$2.width,
        lessThan(0.1),
        reason: '宽度只在列数变化带来的均分误差里浮动',
      );
    }
  });

  testWidgets('开关侧栏后仍停在原来那一段', (WidgetTester tester) async {
    // 列数从 7 变 6 时每段的行数跟着变，光保住像素偏移就会滚到别的段，
    // 所以切换后要按「顶上是谁」把位置换算过去。
    await pumpLibrary(
      tester,
      tracks: <Track>[
        for (final String letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
          for (int i = 0; i < 13; i += 1)
            sampleTrack(
              title: '$letter$i',
              artist: '$letter Artist $i',
              album: '$letter Album',
              path: '/music/$letter$i.mp3',
            ),
      ],
      viewSize: const Size(1440, 900),
    );
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('艺术家')),
    );
    await tester.pumpAndSettle();

    double headerTop(String letter) => tester
        .getRect(find.byKey(ValueKey<String>('alphabet-header-$letter')))
        .top;

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    // 收起态是 7 列：每段 13 位 → 2 行，段高 = 34 + 2×250 + 16 = 550，
    // L 是第 12 段，段首偏移 = 8 + 11 × 550
    tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position
        .jumpTo(6058);
    await tester.pumpAndSettle();
    final double closedTop = headerTop('L');
    expect(closedTop, lessThan(200), reason: 'L 段应该在视口顶部附近');

    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pumpAndSettle();
    expect(
      headerTop('L'),
      closeTo(closedTop, 1),
      reason: '展开侧栏后顶上的还该是 L，不能挤到别的段',
    );

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();
    expect(headerTop('L'), closeTo(closedTop, 1), reason: '再收回去也要回到原来的位置');
  });

  testWidgets('侧栏 220ms 动画全程卡片尺寸不动', (WidgetTester tester) async {
    // 列数跟着每一帧的宽度算的话，动画走到一半必然多挤出一列、整排重新均分，
    // 看起来就是「抽一下」。这里按终态宽度排布，动画期间只把多出来的宽度
    // 裁掉 / 留白，所以每一帧的卡片尺寸都该和结束时一模一样。
    await pumpLibrary(
      tester,
      tracks: <Track>[
        for (int i = 0; i < 24; i += 1)
          sampleTrack(
            title: '曲目 $i',
            artist: '艺人 ${i % 12}',
            album: '专辑 ${i % 6}',
            path: '/music/$i.mp3',
          ),
      ],
      viewSize: const Size(1440, 900),
    );
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('艺术家')),
    );
    await tester.pumpAndSettle();

    Size card() => tester.getSize(
      find
          .descendant(
            of: find.byType(ArtistGridView),
            matching: find.byType(InkWell),
          )
          .first,
    );

    /// 点一下按钮，逐帧记录卡片尺寸
    Future<List<Size>> trace(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      final List<Size> sizes = <Size>[];
      for (int i = 0; i < 14; i += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        sizes.add(card());
      }
      await tester.pumpAndSettle();
      return sizes;
    }

    for (final (String tooltip, String label) in <(String, String)>[
      ('收起导航栏', '收起'),
      ('展开导航栏', '展开'),
    ]) {
      final List<Size> frames = await trace(tooltip);
      final Size settled = card();
      for (final Size size in frames) {
        expect(
          size.height,
          closeTo(settled.height, 0.01),
          reason: '$label侧栏时卡片高度不该变：$size vs $settled',
        );
        expect(
          size.width,
          closeTo(settled.width, 0.5),
          reason: '$label侧栏时卡片宽度不该跟着动画变：$size vs $settled',
        );
      }
    }
  });

  testWidgets('开关侧栏时卡片高度完全不变', (WidgetTester tester) async {
    final List<Track> tracks = <Track>[
      for (int i = 0; i < 8; i += 1)
        for (int j = 0; j < 3; j += 1)
          sampleTrack(
            title: '$i-$j',
            artist: '艺人$i',
            album: '专辑$i',
            trackNum: j + 1,
            path: '/music/$i-$j.mp3',
          ),
    ];
    // 1440 宽：侧栏 220ms 展开 / 收起，内容区宽度整段都在变
    await pumpLibrary(tester, tracks: tracks, viewSize: const Size(1440, 900));
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('专辑')),
    );
    await tester.pumpAndSettle();

    /// 卡片外框（Material 里的 InkWell 就是整张卡）
    Size cardSize() {
      return tester.getSize(
        find
            .descendant(
              of: find.byType(AlbumGridView),
              matching: find.byType(InkWell),
            )
            .first,
      );
    }

    /// 点一下按钮，逐帧记录封面宽度
    Future<List<double>> trace(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      final List<double> heights = <double>[];
      for (int i = 0; i < 16; i += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        heights.add(cardSize().height);
      }
      await tester.pumpAndSettle();
      heights.add(cardSize().height);
      return heights;
    }

    final List<double> closing = await trace('收起导航栏');
    for (final double height in closing) {
      expect(
        height,
        closeTo(closing.first, 0.1),
        reason: '卡片高度是固定值，收起侧栏时不该变：${closing.join(" -> ")}',
      );
    }

    final List<double> opening = await trace('展开导航栏');
    for (final double height in opening) {
      expect(
        height,
        closeTo(opening.first, 0.1),
        reason: '卡片高度是固定值，展开侧栏时也不该变：${opening.join(" -> ")}',
      );
    }
  });
}

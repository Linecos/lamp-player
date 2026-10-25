import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/title_bar.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
  testWidgets('侧边导航可收起与展开', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开导航栏'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);

    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.menu_open), findsOneWidget);
  });

  testWidgets('侧边栏顶部显示应用图标与名称，并贴住窗口顶部', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    final Finder rail = find.byType(LibraryRail);
    expect(tester.getTopLeft(rail).dy, 0, reason: '侧栏应一直画到窗口顶部');
    expect(find.text('Lamp Player'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
      findsOneWidget,
    );

    final Offset brandCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
    );
    final Offset toggleCenter = tester.getCenter(find.byTooltip('收起导航栏'));
    expect(
      brandCenter.dx,
      closeTo(toggleCenter.dx, 0.01),
      reason: '品牌图标应与折叠按钮同一中轴',
    );

    final Rect brandRect = tester.getRect(find.text('Lamp Player'));
    expect(brandRect.top, greaterThanOrEqualTo(0));
    expect(
      brandRect.bottom,
      lessThanOrEqualTo(LampTitleBar.height),
      reason: '品牌名应落在标题条高度内',
    );
  });

  testWidgets('侧边栏收起有宽度过渡动画', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    final Finder rail = find.byType(LibraryRail);
    expect(tester.getSize(rail).width, LibraryRail.expandedWidth);

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final double midWidth = tester.getSize(rail).width;
    expect(midWidth, greaterThan(LibraryRail.collapsedWidth));
    expect(midWidth, lessThan(LibraryRail.expandedWidth));

    await tester.pumpAndSettle();
    expect(tester.getSize(rail).width, LibraryRail.collapsedWidth);
  });

  testWidgets('收起侧边栏后只显示图标，并与折叠按钮对齐', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    final Finder rail = find.byType(LibraryRail);
    expect(
      tester.getSize(rail).width,
      LibraryRail.collapsedWidth,
      reason: '收起后应收窄到图标宽度',
    );
    for (final String label in <String>[
      '音乐',
      '歌单',
      '历史',
      '收藏',
      '艺术家',
      '专辑',
      '设置',
    ]) {
      expect(
        find.descendant(of: rail, matching: find.text(label)),
        findsNothing,
        reason: '收起后不应再显示「$label」',
      );
    }

    expect(find.text('Lamp Player'), findsNothing, reason: '收起后品牌名应隐藏');
    expect(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
      findsOneWidget,
      reason: '收起后品牌图标应保留',
    );

    final Offset toggleCenter = tester.getCenter(find.byTooltip('展开导航栏'));
    final Offset musicCenter = tester.getCenter(
      find.descendant(of: rail, matching: find.byIcon(Icons.music_note)),
    );
    final Offset brandCenter = tester.getCenter(
      find.byKey(const ValueKey<String>('rail-brand-mark')),
    );
    expect(musicCenter.dx, closeTo(toggleCenter.dx, 0.01), reason: '应在同一中轴');
    expect(
      brandCenter.dx,
      closeTo(toggleCenter.dx, 0.01),
      reason: '品牌图标也应在同一中轴',
    );
  });

  testWidgets('点击侧边栏切换分区只做淡入，旧内容立即移除', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    expect(find.text('2 首音乐'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('设置')),
    );
    // 第一帧只换侧栏高亮，内容切换在下一帧
    await tester.pump();
    expect(find.text('2 首音乐'), findsOneWidget, reason: '这一帧内容还没换');

    await tester.pump(const Duration(milliseconds: 80));

    // 交叉淡变会让两份全屏列表同时布局绘制（切换必掉帧），
    // 所以旧分区立即移除、只让新分区淡入
    expect(find.text('2 首音乐'), findsNothing, reason: '旧分区应立即移除');
    expect(find.text('曲目数量'), findsOneWidget, reason: '新分区应已挂载');

    await tester.pumpAndSettle();
    expect(find.text('2 首音乐'), findsNothing);
    expect(find.text('曲目数量'), findsOneWidget);
  });

  testWidgets('从详情点击当前分区返回列表也有过渡', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        ...twoTracks(),
        sampleTrack(title: '灯下', artist: '林间电台', album: '夜之专辑'),
      ],
    );
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('林间电台'));
    await tester.pumpAndSettle();
    expect(find.text('1 张专辑 · 2 首音乐'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('艺术家')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('1 张专辑 · 2 首音乐'), findsNothing, reason: '详情应立即移除');
    expect(find.text('2 位艺术家'), findsOneWidget, reason: '列表应已挂载');

    await tester.pumpAndSettle();
    expect(find.text('1 张专辑 · 2 首音乐'), findsNothing);
    expect(find.text('2 位艺术家'), findsOneWidget);
  });

  testWidgets('侧边栏包含七个入口', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    for (final String label in <String>[
      '音乐',
      '歌单',
      '历史',
      '收藏',
      '艺术家',
      '专辑',
      '设置',
    ]) {
      expect(
        find.descendant(
          of: find.byType(LibraryRail),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: '侧边栏缺少「$label」',
      );
    }
  });
}

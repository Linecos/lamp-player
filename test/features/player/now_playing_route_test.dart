import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/now_playing_route.dart';

void main() {
  testWidgets('打开时从下方滑入，结束后归位', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: SizedBox.expand()),
        builder: (BuildContext context, Widget? child) => Navigator(
          onGenerateRoute: (RouteSettings settings) => PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => const Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    );

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          NowPlayingPageRoute(
            builder: (BuildContext context) =>
                const Scaffold(body: Text('播放页')),
          ),
        );
    // 第一帧：动画刚开始
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    final Finder page = find.text('播放页');
    expect(page, findsOneWidget);
    // 不做整页渐显：opacity 动画会给 Impeller 每帧一张全屏离屏图层
    expect(
      find.ancestor(of: page, matching: find.byType(FadeTransition)),
      findsNothing,
      reason: '转场只改位移矩阵，不分配离屏图层',
    );
    // 从下方滑入：还差一截没到顶
    final SlideTransition slide = tester.widget<SlideTransition>(
      find.ancestor(of: page, matching: find.byType(SlideTransition)).last,
    );
    expect(slide.position.value.dy, inExclusiveRange(0, 0.2));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(page), Offset.zero);
  });

  testWidgets('返回时反向播放：页面退回下方', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  NowPlayingPageRoute(
                    builder: (BuildContext context) =>
                        const Scaffold(body: Text('播放页')),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('播放页'), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final Finder page = find.text('播放页');
    final SlideTransition slide = tester.widget<SlideTransition>(
      find.ancestor(of: page, matching: find.byType(SlideTransition)).last,
    );
    expect(slide.position.value.dy, greaterThan(0), reason: '返回时往下滑');

    await tester.pumpAndSettle();
    expect(page, findsNothing);
  });
}

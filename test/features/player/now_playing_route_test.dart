import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/now_playing_route.dart';

void main() {
  testWidgets('打开时从下方滑入并渐显，结束后归位', (WidgetTester tester) async {
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
    // 渐显：动画头几帧页面还是半透明
    final FadeTransition fade = tester.widget<FadeTransition>(
      find.ancestor(of: page, matching: find.byType(FadeTransition)).last,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    // 从下方滑入：还差一截没到顶
    final SlideTransition slide = tester.widget<SlideTransition>(
      find.ancestor(of: page, matching: find.byType(SlideTransition)).last,
    );
    expect(slide.position.value.dy, inExclusiveRange(0, 0.2));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(page), Offset.zero);
    final FadeTransition settled = tester.widget<FadeTransition>(
      find.ancestor(of: page, matching: find.byType(FadeTransition)).last,
    );
    expect(settled.opacity.value, 1);
  });

  testWidgets('返回时反向播放：页面退回下方并淡出', (WidgetTester tester) async {
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
    final FadeTransition fade = tester.widget<FadeTransition>(
      find.ancestor(of: page, matching: find.byType(FadeTransition)).last,
    );
    expect(fade.opacity.value, lessThan(1), reason: '返回时同时淡出');

    await tester.pumpAndSettle();
    expect(page, findsNothing);
  });
}

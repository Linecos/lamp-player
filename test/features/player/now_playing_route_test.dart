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
    // 整页渐显要在：Hero 飞行层画在 Navigator 最上层，页面越透明，封面就越像
    // 「自己长大了」，而不是贴着一张滑进来的图（去掉淡入会把观感整个改掉）
    final FadeTransition fade = tester.widget<FadeTransition>(
      find.ancestor(of: page, matching: find.byType(FadeTransition)).last,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1), reason: '转场中页面是半透明的');
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
    expect(settled.opacity.value, 1, reason: '落定后必须完全不透明');
  });

  testWidgets('前进转场中 pop 会被拦下，转场结束再自动关', (WidgetTester tester) async {
    // 转场中被 pop 是 Hero flight 残骸的触发器（flutter#121325 /
    // SO 78080285）：飞行层跟着路由动画走，中途 pop 会撞上「收不了尾」，
    // 残骸永远挂在 Overlay 上（实测：岛上封面消失 + 带阴影的大封面冻在半空）
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // 转场中 pop：被 popDisposition 拦下，页面还在
    // （用 maybePop——播放页 Esc 走的就是这条路；裸 pop() 不查 popDisposition）
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('播放页'), findsOneWidget, reason: '转场中被拦下，页面不能消失');

    // 转场走完：排队的 pop 自动执行
    await tester.pumpAndSettle();
    expect(find.text('播放页'), findsNothing, reason: '排队的 pop 要在转场结束时执行');
    expect(find.text('打开'), findsOneWidget, reason: '回到的是下层路由');
  });

  testWidgets('后退转场中再 pop 不会把下层路由也带掉', (WidgetTester tester) async {
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

    // 关一次：进入后退转场
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 手快再补一刀：被拦下且不排队，退完只关播放页这一层
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(find.text('播放页'), findsNothing);
    expect(find.text('打开'), findsOneWidget, reason: '连按两次 Esc 也只能关到播放页为止');
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

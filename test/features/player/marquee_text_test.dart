import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/marquee_text.dart';

/// 测试字体每字符就是一个 fontSize 的方块：20 字 × 20px = 400，稳超 200
const String _long = 'Under the Starlight (feat. Adam Christopher)';

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 200, child: child)),
    ),
  );
}

/// 把鼠标挪到某个组件中心（Desktop 端的悬停要靠真指针事件触发）
Future<TestGesture> _hover(WidgetTester tester, Finder finder) async {
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
  return gesture;
}

/// 第一份文字的左边界（跟着滚动一起挪）
double _firstLeft(WidgetTester tester) =>
    tester.getRect(find.text(_long).first).left;

void main() {
  testWidgets('装得下就退化成普通一行，没有渐隐也不吃鼠标', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const MarqueeText(text: '夜航', style: TextStyle(fontSize: 20))),
    );

    expect(find.text('夜航'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(MarqueeText),
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
  });

  testWidgets('放不下时铺两份同样的文字并渐隐', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const MarqueeText(text: _long, style: TextStyle(fontSize: 20))),
    );

    // 两份：一份走完接上另一份，循环处看不出接缝
    expect(find.text(_long), findsNWidgets(2));
    expect(find.byType(ShaderMask), findsOneWidget);

    // 读屏只读一遍
    final SemanticsHandle handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(_long), findsOneWidget);
    handle.dispose();
  });

  testWidgets('静止时不滚：位置一直停在第一个字', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const MarqueeText(text: _long, style: TextStyle(fontSize: 20))),
    );

    final double start = _firstLeft(tester);
    for (int i = 0; i < 12; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_firstLeft(tester), start, reason: '没有鼠标压上来，一个像素都不该动');
  });

  testWidgets('鼠标压上去才滚，移开后回到第一个字', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const MarqueeText(text: _long, style: TextStyle(fontSize: 20))),
    );
    final double start = _firstLeft(tester);

    final TestGesture gesture = await _hover(tester, find.byType(MarqueeText));
    await tester.pump(const Duration(milliseconds: 400));
    final double scrolled = _firstLeft(tester);
    expect(scrolled, lessThan(start - 4), reason: '悬停后应该开始往左滚');

    // 移开鼠标：停下来并倒回第一个字
    await gesture.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(_firstLeft(tester), closeTo(start, 0.5));
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '回到起点后动画要彻底停住，不能还在空转',
    );
  });

  testWidgets('换歌后回到第一个字，不会接着上一首的位置', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const MarqueeText(text: _long, style: TextStyle(fontSize: 20))),
    );
    const String other = 'Under the Starlight (feat. Someone Else)';

    final TestGesture gesture = await _hover(tester, find.byType(MarqueeText));
    await tester.pump(const Duration(milliseconds: 400));
    // 先确认它确实已经滚出去了（否则下面的断言等于没测）
    expect(
      _firstLeft(tester),
      lessThan(tester.getRect(find.byType(MarqueeText)).left - 4),
    );

    await tester.pumpWidget(
      _host(const MarqueeText(text: other, style: TextStyle(fontSize: 20))),
    );
    await tester.pump();

    final Rect first = tester.getRect(find.text(other).first);
    final Rect box = tester.getRect(find.byType(MarqueeText));
    expect(first.left, closeTo(box.left, 0.5), reason: '新歌名要从第一个字开始');

    await gesture.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
  });
}

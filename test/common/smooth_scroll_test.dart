import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/scroll/smooth_scroll.dart';

void main() {
  Widget buildList(SmoothScrollController controller) {
    return MaterialApp(
      home: ListView.builder(
        controller: controller,
        itemExtent: 50,
        itemCount: 200,
        itemBuilder: (BuildContext context, int index) =>
            SizedBox(height: 50, child: Text('$index')),
      ),
    );
  }

  Future<void> wheel(WidgetTester tester, double delta) async {
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(ListView))),
    );
    await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  }

  testWidgets('滚轮不是一帧跳完，而是分帧走完', (WidgetTester tester) async {
    final SmoothScrollController controller = SmoothScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await wheel(tester, 60);
    await tester.pump();

    // 第一帧只走掉一部分：这正是「平滑」与「一格跳完」的区别
    expect(controller.offset, greaterThan(0.0));
    expect(controller.offset, lessThan(60.0));

    await tester.pump(const Duration(milliseconds: 100));
    // 单调往前走，不会来回晃
    final double middle = controller.offset;
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, greaterThan(middle));

    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.offset, closeTo(60.0, 0.6));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('连续滚轮叠目标，不会一格一顿', (WidgetTester tester) async {
    final SmoothScrollController controller = SmoothScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await wheel(tester, 60);
    await tester.pump(const Duration(milliseconds: 40));
    await wheel(tester, 60);
    await tester.pump(const Duration(milliseconds: 600));

    expect(controller.offset, closeTo(120.0, 0.6));
  });

  testWidgets('滚到底后夹在最大偏移，不会越界', (WidgetTester tester) async {
    final SmoothScrollController controller = SmoothScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 远远超过列表末尾
    await wheel(tester, 100000);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 800));

    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 0.6),
    );
  });
}

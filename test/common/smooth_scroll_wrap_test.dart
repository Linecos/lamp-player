import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/scroll/smooth_scroll.dart';

/// 走「视图自带控制器」这条路时，滚轮是否真的分帧走完。
///
/// 不能靠根 `PrimaryScrollController`：`ModalRoute` 给每个路由都套了一个
/// 只对移动平台生效的 `PrimaryScrollController`，桌面端页面里的裸 `ListView`
/// 会退回自己的私有控制器（实测 position 是 `ScrollPositionWithSingleContext`），
/// 于是只有带平滑控制器的列表才平滑。
Future<void> _wheel(WidgetTester tester, double delta) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(tester.getCenter(find.byType(Scrollable).first)),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pump();
}

void main() {
  testWidgets('SmoothListView：位置是平滑版，首帧只走一部分', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmoothListView(
            children: <Widget>[
              for (int i = 0; i < 100; i++)
                SizedBox(height: 50, child: Text('$i')),
            ],
          ),
        ),
      ),
    );
    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position, isA<SmoothScrollPosition>());

    await _wheel(tester, 60);
    expect(position.pixels, greaterThan(0.0));
    expect(position.pixels, lessThan(60.0));

    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, closeTo(60.0, 0.6));
  });

  testWidgets('SmoothScroll(builder:)：同样拿到平滑位置', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmoothScroll(
            builder: (BuildContext context, ScrollController controller) =>
                ListView.builder(
                  controller: controller,
                  itemExtent: 50,
                  itemCount: 100,
                  itemBuilder: (BuildContext context, int index) =>
                      Text('$index'),
                ),
          ),
        ),
      ),
    );
    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position, isA<SmoothScrollPosition>());

    await _wheel(tester, 60);
    expect(position.pixels, lessThan(60.0));
  });
}

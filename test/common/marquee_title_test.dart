import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/marquee_title.dart';

const TextStyle _style = TextStyle(fontSize: 20);
const String _longText = 'A very long song title that does not fit at all';
const double _viewport = 120;

Future<void> _pump(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _viewport,
            height: 30,
            child: MarqueeTitle(text: text, style: _style, velocity: 200),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 第一份文字的左边界：滚动时它会一直往左走
double _titleLeft(WidgetTester tester, String text) => tester
    .getTopLeft(
      find
          .descendant(of: find.byType(MarqueeTitle), matching: find.text(text))
          .first,
    )
    .dx;

double _titleWidth(WidgetTester tester, String text) => tester
    .getSize(
      find
          .descendant(of: find.byType(MarqueeTitle), matching: find.text(text))
          .first,
    )
    .width;

void main() {
  group('右侧渐隐', () {
    /// 渐隐带厚度（逻辑像素）：取 stops 里「满 → 全透明」那一段
    double spanOf(LinearGradient g, double width) =>
        (g.stops![g.colors.length - 2] - g.stops![2]) * width;

    test('带宽固定，不随框宽变窄', () {
      for (final double width in <double>[180, 240, 420]) {
        final LinearGradient g = MarqueeTitle.fadeGradient(
          width: width,
          leftFade: 0,
        );
        expect(
          spanOf(g, width),
          closeTo(30, 0.6),
          reason:
              '$width 宽的框里渐隐也该有 30px：按百分比算窄框只有十几像素，'
              '最后一个字会几乎全亮地怼到边上',
        );
      }
    });

    test('收在边界内 1px，且最后一截完全透明', () {
      const double width = 240;
      final LinearGradient g = MarqueeTitle.fadeGradient(
        width: width,
        leftFade: 0,
      );
      final List<double> stops = g.stops!;
      expect(
        stops[stops.length - 2],
        closeTo((width - 1) / width, 1e-9),
        reason:
            '透明要提前一个像素到位：裁剪的抗锯齿会漏出边界外不到 1px，'
            'ShaderMask 遮不到那里，漏出去的就是边上那条亮线',
      );
      expect(g.colors.last.a, 0);
      expect(g.colors[g.colors.length - 2].a, 0);
      // 单调递增，否则渐变本身就有硬边
      for (int i = 1; i < stops.length; i += 1) {
        expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
      }
    });

    test('很窄的位置不超过三分之一，别整条都在淡', () {
      const double width = 40;
      final LinearGradient g = MarqueeTitle.fadeGradient(
        width: width,
        leftFade: 0,
      );
      expect(spanOf(g, width), lessThan(width / 2));
    });

    test('左淡为 0 时最左边是纯白，不留 1px 硬边', () {
      final LinearGradient g = MarqueeTitle.fadeGradient(
        width: 200,
        leftFade: 0,
      );
      expect(g.colors.first.a, 1);
      // 左淡有值时起步就是透明的
      expect(
        MarqueeTitle.fadeGradient(width: 200, leftFade: 0.05).colors.first.a,
        0,
      );
    });
  });

  group('左侧渐隐', () {
    // 一圈 900 像素、ramp 14 像素：滚过 14px 之后左淡就该是满的
    const double cycle = 900;

    test('静止时为 0，滚起来才渐入到满', () {
      final ({double leftFade, double travelled, double lastValue}) idle =
          MarqueeTitle.stepLeftFade(
            value: 0,
            lastValue: 0,
            cycle: cycle,
            travelled: 0,
          );
      expect(idle.leftFade, 0, reason: '还没滚，第一个字不该被淡掉');

      final ({double leftFade, double travelled, double lastValue}) moving =
          MarqueeTitle.stepLeftFade(
            value: 0.05,
            lastValue: 0,
            cycle: cycle,
            travelled: idle.travelled,
          );
      expect(moving.leftFade, greaterThan(0), reason: '滚起来就该有左淡');
      expect(
        MarqueeTitle.stepLeftFade(
          value: 0.1,
          lastValue: moving.lastValue,
          cycle: cycle,
          travelled: moving.travelled,
        ).leftFade,
        closeTo(0.05, 0.001),
        reason: '滚够 14px 之后到满',
      );
    });

    test('跨圈衔接时左淡不清零，遮罩不会闪一下', () {
      // 模拟一圈末尾 → 下一圈开头：value 从 0.99 掉回 0.01
      const List<double> values = <double>[0.9, 0.95, 0.99, 0.01, 0.05, 0.1];
      double travelled = 0;
      double lastValue = 0;
      final List<double> fades = <double>[];
      for (final double value in values) {
        final ({double leftFade, double travelled, double lastValue}) step =
            MarqueeTitle.stepLeftFade(
              value: value,
              lastValue: lastValue,
              cycle: cycle,
              travelled: travelled,
            );
        travelled = step.travelled;
        lastValue = step.lastValue;
        fades.add(step.leftFade);
      }

      // 从 0.9 起就该一直是满的：任何一帧掉下来，看上去就是遮罩闪了一下
      for (final double fade in fades) {
        expect(fade, closeTo(0.05, 0.001), reason: '跨圈那一帧也要保持满，否则就是「遮掩→消失→遮掩」');
      }
    });

    test('归位时按剩余位移收掉，回到起点正好为 0', () {
      const double full = 0.05;
      final ({double leftFade, double travelled, double lastValue}) back =
          MarqueeTitle.stepLeftFade(
            value: 0.5,
            lastValue: 0.6,
            cycle: cycle,
            travelled: 600,
          );
      expect(back.leftFade, closeTo(full, 0.001), reason: '还有大半屏位移，保持满');

      final ({double leftFade, double travelled, double lastValue}) done =
          MarqueeTitle.stepLeftFade(
            value: 0,
            lastValue: back.lastValue,
            cycle: cycle,
            travelled: back.travelled,
          );
      expect(done.leftFade, 0, reason: '已经回到起点，左淡收干净');
    });
  });

  testWidgets('放得下就不渐隐、悬停也不动', (WidgetTester tester) async {
    await _pump(tester, 'Short');

    expect(find.byType(ShaderMask), findsNothing, reason: '没超出就不该淡出');

    final double before = _titleLeft(tester, 'Short');
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byType(MarqueeTitle)));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(_titleLeft(tester, 'Short'), before, reason: '短标题不该动');
    await mouse.removePointer();
  });

  testWidgets('两端渐隐，悬停缓慢左滚、移开滑回原位', (WidgetTester tester) async {
    await _pump(tester, _longText);

    expect(find.byType(ShaderMask), findsOneWidget, reason: '溢出时两头都要渐隐');
    final double start = _titleLeft(tester, _longText);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byType(MarqueeTitle)));

    // 悬停后先等一会儿再动：鼠标只是路过不该让文字乱跑
    await tester.pump(const Duration(milliseconds: 300));
    expect(_titleLeft(tester, _longText), start, reason: '悬停延迟内不动');

    // 延迟到点这一帧才把动画启动起来，再多推一点才看得到位移
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
    final double scrolled = _titleLeft(tester, _longText);
    expect(scrolled, lessThan(start - 20), reason: '悬停后应当向左滚');

    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _titleLeft(tester, _longText),
      lessThan(scrolled),
      reason: '是缓慢连续滚，不是一下跳过去',
    );

    // 移开：滑回开头
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      _titleLeft(tester, _longText),
      closeTo(start, 1),
      reason: '鼠标移开要慢慢回到开头',
    );

    await mouse.removePointer();
  });

  /// 悬停并把动画推进到一圈的 [fraction] 处，返回此时第一份文字的左边界
  Future<double> scrollTo(
    WidgetTester tester,
    TestGesture mouse,
    double fraction,
  ) async {
    final double textWidth = _titleWidth(tester, _longText);
    final Duration cycle = Duration(
      milliseconds: ((textWidth + 32) / 200 * 1000).round(),
    );
    await mouse.moveTo(tester.getCenter(find.byType(MarqueeTitle)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(cycle * fraction);
    return _titleLeft(tester, _longText);
  }

  testWidgets('后半圈移开：滑回本轮起点，不往前快进到下一圈', (WidgetTester tester) async {
    await _pump(tester, _longText);
    final double start = _titleLeft(tester, _longText);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    // 0.7 圈：已经快走到本轮末尾
    final double deep = await scrollTo(tester, mouse, 0.7);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      _titleLeft(tester, _longText),
      greaterThan(deep + 1),
      reason: '归位就是往右滑回本轮开头，不往前快进到下一圈',
    );

    await tester.pump(const Duration(milliseconds: 700));
    expect(
      _titleLeft(tester, _longText),
      closeTo(start, 2),
      reason: '归位后停在开头那个画面上',
    );
    await mouse.removePointer();
  });

  testWidgets('连滚好几圈后移开，也只退到本轮开头', (WidgetTester tester) async {
    await _pump(tester, _longText);
    final double start = _titleLeft(tester, _longText);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    // 3.4 圈：循环里根本不记圈数，位移永远是「一圈内」的量
    final double deep = await scrollTo(tester, mouse, 3.4);
    expect(deep, lessThan(start - 100), reason: '确实滚出去很远');

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      _titleLeft(tester, _longText),
      closeTo(start, 2),
      reason: '不管循环了几圈，退回来都只退回本轮开头',
    );
    await mouse.removePointer();
  });

  testWidgets('前半圈移开：往回到本轮起点', (WidgetTester tester) async {
    await _pump(tester, _longText);
    final double start = _titleLeft(tester, _longText);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    final double early = await scrollTo(tester, mouse, 0.2);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      _titleLeft(tester, _longText),
      greaterThan(early + 1),
      reason: '离本轮起点更近，应该往右滑回去',
    );

    await tester.pump(const Duration(milliseconds: 700));
    expect(_titleLeft(tester, _longText), closeTo(start, 2));
    await mouse.removePointer();
  });

  testWidgets('滚到底首尾相接继续播，不会一路向左滑走', (WidgetTester tester) async {
    await _pump(tester, _longText);

    final double start = _titleLeft(tester, _longText);
    // 循环长度 = 一份文字 + 空白（gap 取 max(32, 视口 12%)，这里视口窄，取 32）
    final double textWidth = _titleWidth(tester, _longText);
    final double cycle = textWidth + 32;
    final Duration oneCycle = Duration(
      milliseconds: (cycle / 200 * 1000).round(),
    );

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byType(MarqueeTitle)));
    await tester.pump(const Duration(milliseconds: 500));

    // 跑完一整圈：位置应当回到起点（第二份文字的开头接了上来）
    await tester.pump(oneCycle);
    expect(
      _titleLeft(tester, _longText),
      closeTo(start, 12),
      reason: '一圈走完要首尾相接，位移回到起点',
    );

    // 再跑半圈：继续向左，说明还在循环里
    await tester.pump(oneCycle ~/ 2);
    expect(
      _titleLeft(tester, _longText),
      lessThan(start - 100),
      reason: '循环没停，仍然在往左走',
    );

    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 700));
  });
}

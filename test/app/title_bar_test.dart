import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/title_bar.dart';
import 'package:lamp_player/src/app/window_controls.dart';

/// 不依赖 window_manager 的假实现。
class FakeWindowControls implements WindowControls {
  int minimizeCalls = 0;
  int toggleCalls = 0;
  int closeCalls = 0;
  int dragCalls = 0;

  bool maximized = false;
  bool failAll = false;

  /// 模拟「系统改变了最大化状态」（Win+↑、贴边等）
  final StreamController<bool> maximizeEvents =
      StreamController<bool>.broadcast();

  @override
  Stream<bool> get maximizeChanges => maximizeEvents.stream;

  @override
  Future<void> minimize() async {
    if (failAll) {
      throw StateError('不可用');
    }
    minimizeCalls += 1;
  }

  @override
  Future<bool> toggleMaximize() async {
    if (failAll) {
      throw StateError('不可用');
    }
    toggleCalls += 1;
    maximized = !maximized;
    return maximized;
  }

  @override
  Future<bool> isMaximized() async {
    if (failAll) {
      throw StateError('不可用');
    }
    return maximized;
  }

  @override
  Future<void> close() async {
    if (failAll) {
      throw StateError('不可用');
    }
    closeCalls += 1;
  }

  @override
  Future<void> startDragging() async {
    if (failAll) {
      throw StateError('不可用');
    }
    dragCalls += 1;
  }
}

const ValueKey<String> _minimizeKey = ValueKey<String>('window-minimize');
const ValueKey<String> _maximizeKey = ValueKey<String>('window-maximize');
const ValueKey<String> _closeKey = ValueKey<String>('window-close');
const ValueKey<String> _dragKey = ValueKey<String>('window-drag-area');

Future<void> _pumpTitleBar(
  WidgetTester tester,
  FakeWindowControls controls,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            LampTitleBar(controls: controls),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('标题栏保留拖动区与三个窗口按钮，应用名交给侧栏', (WidgetTester tester) async {
    await _pumpTitleBar(tester, FakeWindowControls());

    expect(find.byKey(_dragKey), findsOneWidget);
    expect(find.text('Lamp Player'), findsNothing, reason: '应用名固定在侧栏顶部');
    expect(find.byKey(_minimizeKey), findsOneWidget);
    expect(find.byKey(_maximizeKey), findsOneWidget);
    expect(find.byKey(_closeKey), findsOneWidget);
  });

  testWidgets('overlay 模式下标题条浮在页面顶部', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WindowChrome(
          controls: FakeWindowControls(),
          overlay: true,
          child: const ColoredBox(color: Colors.red, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();

    final Rect dragRect = tester.getRect(find.byKey(_dragKey));
    expect(dragRect.top, 0);
    expect(dragRect.height, LampTitleBar.height);
    expect(find.byKey(_closeKey), findsOneWidget);
  });

  testWidgets('overlay 模式左上角让给页面，点击不被拖动区吃掉', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WindowChrome(
          controls: FakeWindowControls(),
          overlay: true,
          child: Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps += 1,
              child: const SizedBox(width: 120, height: LampTitleBar.height),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final Rect dragRect = tester.getRect(find.byKey(_dragKey));
    expect(
      dragRect.left,
      LampTitleBar.defaultLeftInset,
      reason: '拖动区应从让位宽度之后开始',
    );

    await tester.tapAt(const Offset(60, 20));
    await tester.pump();

    expect(taps, 1, reason: '让位区的点击要透给页面');
  });

  testWidgets('controlsOnly 只保留窗口按钮，不画拖动区', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LampTitleBar(controls: controls, controlsOnly: true),
        ),
      ),
    );

    expect(find.byKey(_dragKey), findsNothing);
    expect(find.byKey(_minimizeKey), findsOneWidget);
    expect(find.byKey(_maximizeKey), findsOneWidget);
    expect(find.byKey(_closeKey), findsOneWidget);
  });

  testWidgets('点最小化与关闭会调用窗口控制', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls();
    await _pumpTitleBar(tester, controls);

    await tester.tap(find.byKey(_minimizeKey));
    await tester.pump();
    expect(controls.minimizeCalls, 1);

    await tester.tap(find.byKey(_closeKey));
    await tester.pump();
    expect(controls.closeCalls, 1);
  });

  testWidgets('点最大化会切换状态并换成还原图标', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls();
    await _pumpTitleBar(tester, controls);

    expect(
      find.byKey(const ValueKey<String>('window-glyph-maximize')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(_maximizeKey));
    await tester.pumpAndSettle();

    expect(controls.toggleCalls, 1);
    expect(controls.maximized, isTrue);
    expect(
      find.byKey(const ValueKey<String>('window-glyph-restore')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('window-glyph-maximize')),
      findsNothing,
    );

    await tester.tap(find.byKey(_maximizeKey));
    await tester.pumpAndSettle();

    expect(controls.toggleCalls, 2);
    expect(controls.maximized, isFalse);
    expect(
      find.byKey(const ValueKey<String>('window-glyph-maximize')),
      findsOneWidget,
    );
  });

  testWidgets('双击标题区域切换最大化', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls();
    await _pumpTitleBar(tester, controls);

    await tester.tap(find.byKey(_dragKey));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(_dragKey));
    await tester.pumpAndSettle();

    expect(controls.toggleCalls, 1);
  });

  testWidgets('按住标题区域会开始拖动窗口', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls();
    await _pumpTitleBar(tester, controls);

    await tester.drag(find.byKey(_dragKey), const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(controls.dragCalls, greaterThan(0));
  });

  testWidgets('系统触发的最大化会同步图标', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls();
    await _pumpTitleBar(tester, controls);

    expect(
      find.byKey(const ValueKey<String>('window-glyph-maximize')),
      findsOneWidget,
    );

    // 模拟 Win+↑：窗口管理器发事件，但没人点我们的按钮
    controls.maximized = true;
    controls.maximizeEvents.add(true);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('window-glyph-restore')),
      findsOneWidget,
      reason: '应显示「还原」图标',
    );

    controls.maximized = false;
    controls.maximizeEvents.add(false);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('window-glyph-maximize')),
      findsOneWidget,
    );
    await controls.maximizeEvents.close();
  });

  testWidgets('窗口控制不可用时点按钮不崩溃', (WidgetTester tester) async {
    final FakeWindowControls controls = FakeWindowControls()..failAll = true;
    await _pumpTitleBar(tester, controls);

    await tester.tap(find.byKey(_minimizeKey));
    await tester.pump();
    await tester.tap(find.byKey(_maximizeKey));
    await tester.pump();
    await tester.tap(find.byKey(_closeKey));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

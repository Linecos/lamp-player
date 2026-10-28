import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/spectrum_ribbon.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 一帧假频谱：中间高、两头低，跟真实音乐的形状接近
List<double> _bands() => <double>[
  for (int i = 0; i < 24; i += 1) 0.2 + 0.7 * ((i % 7) / 7),
];

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark(AppTheme.defaultSeed),
    home: Scaffold(
      body: Stack(fit: StackFit.expand, children: <Widget>[child]),
    ),
  );
}

void main() {
  testWidgets('有数据时画在整宽上', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
      _bands(),
    );
    addTearDown(bands.dispose);

    await tester.pumpWidget(
      _host(
        SpectrumRibbon(
          key: const ValueKey<String>('ribbon'),
          bands: bands,
          animate: false,
        ),
      ),
    );
    await tester.pump();

    final Finder ribbon = find.byKey(const ValueKey<String>('ribbon'));
    expect(ribbon, findsOneWidget);
    // 铺满整宽（StackFit.expand 下与屏幕同宽），不再是左侧一小截
    expect(tester.getSize(ribbon).width, 1200);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('暂停（数据清空）时淡出而不是冻住一帧', (WidgetTester tester) async {
    final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
      _bands(),
    );
    addTearDown(bands.dispose);

    await tester.pumpWidget(
      _host(SpectrumRibbon(bands: bands, animate: false)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    bands.value = const <double>[];
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });

  testWidgets('压在可滚动内容上，拖动照常滚动', (WidgetTester tester) async {
    final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
      _bands(),
    );
    addTearDown(bands.dispose);
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppTheme.defaultSeed),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ListView.builder(
                controller: scroll,
                itemCount: 60,
                itemBuilder: (BuildContext context, int index) =>
                    SizedBox(height: 56, child: Text('第 $index 行歌词')),
              ),
              SpectrumRibbon(bands: bands, animate: false),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(IgnorePointer), findsWidgets);
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
  });
}

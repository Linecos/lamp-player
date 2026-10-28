import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/spectrum_wave.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 一帧假频谱：低频整体更强、高频更弱，每段各自起伏
List<double> _bands() => <double>[
  for (int i = 0; i < 24; i += 1)
    (0.95 - i * 0.02) * (0.45 + 0.55 * ((i * 61) % 17) / 16),
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
  testWidgets('有数据时铺满整宽', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
      _bands(),
    );
    addTearDown(bands.dispose);

    await tester.pumpWidget(
      _host(SpectrumWave(key: const ValueKey<String>('wave'), bands: bands)),
    );
    await tester.pump();

    final Finder wave = find.byKey(const ValueKey<String>('wave'));
    expect(wave, findsOneWidget);
    expect(tester.getSize(wave).width, 1200);
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

    await tester.pumpWidget(_host(SpectrumWave(bands: bands)));
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

  testWidgets('只有数据驱动，没有额外动画', (WidgetTester tester) async {
    final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
      _bands(),
    );
    addTearDown(bands.dispose);

    await tester.pumpWidget(_host(SpectrumWave(bands: bands)));
    // 有无限循环动画时这一步会超时，跑得完就说明「不会自己动」
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
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
              SpectrumWave(bands: bands),
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

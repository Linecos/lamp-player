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

  group('配色跟随主题', () {
    test('两端只在基准色附近换色相，明度与饱和度不动', () {
      const Color base = Color(0xFF2196F3);
      final HSLColor baseHsl = HSLColor.fromColor(base);
      final List<Color> tints = spectrumTints(base);

      expect(tints.length, 3);
      expect(tints[1], base, reason: '中段就是主题色本身');
      expect(
        HSLColor.fromColor(tints[0]).hue,
        closeTo(baseHsl.hue - spectrumHueSpread, 1),
      );
      expect(
        HSLColor.fromColor(tints[2]).hue,
        closeTo(baseHsl.hue + spectrumHueSpread, 1),
      );
      for (final Color tint in <Color>[tints[0], tints[2]]) {
        final HSLColor hsl = HSLColor.fromColor(tint);
        expect(hsl.lightness, closeTo(baseHsl.lightness, 0.02));
        expect(hsl.saturation, closeTo(baseHsl.saturation, 0.02));
      }
    });

    test('无彩色主题不会被染上颜色', () {
      // Monochrome 配色下 primary 是灰的：转色相等于没转，整排跟着变灰才对
      const Color grey = Color(0xFF8A8A8A);
      final HSLColor greyHsl = HSLColor.fromColor(grey);
      for (final Color tint in spectrumTints(grey)) {
        final HSLColor hsl = HSLColor.fromColor(tint);
        expect(hsl.saturation, lessThan(0.02));
        expect(hsl.lightness, closeTo(greyHsl.lightness, 0.02));
      }
    });

    testWidgets('不传颜色时取当前主题主色', (WidgetTester tester) async {
      final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
        _bands(),
      );
      addTearDown(bands.dispose);

      late ColorScheme scheme;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.defaultSeed),
          home: Builder(
            builder: (BuildContext context) {
              scheme = Theme.of(context).colorScheme;
              return Scaffold(body: SpectrumWave(bands: bands));
            },
          ),
        ),
      );
      await tester.pump();

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(SpectrumWave),
          matching: find.byType(CustomPaint),
        ),
      );
      final List<Color> colors =
          (paint.painter! as dynamic).colors as List<Color>;

      expect(colors[1], scheme.primary);
      expect(
        HSLColor.fromColor(colors[0]).hue,
        closeTo(HSLColor.fromColor(scheme.primary).hue - spectrumHueSpread, 1),
      );
    });

    testWidgets('换主题后整排颜色跟着换', (WidgetTester tester) async {
      final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
        _bands(),
      );
      addTearDown(bands.dispose);

      Future<Color> midColor(ThemeData theme) async {
        late ColorScheme scheme;
        await tester.pumpWidget(
          MaterialApp(
            // 用内层 Theme 直接覆盖：MaterialApp 的 theme 走的是
            // AnimatedTheme，一次 pump 只到过渡中间，读到的还是旧配色
            home: Theme(
              data: theme,
              child: Builder(
                builder: (BuildContext context) {
                  scheme = Theme.of(context).colorScheme;
                  return Scaffold(body: SpectrumWave(bands: bands));
                },
              ),
            ),
          ),
        );
        await tester.pump();
        final CustomPaint paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(SpectrumWave),
            matching: find.byType(CustomPaint),
          ),
        );
        final List<Color> colors =
            (paint.painter! as dynamic).colors as List<Color>;
        expect(colors[1], scheme.primary);
        return colors[1];
      }

      final Color warm = await midColor(AppTheme.dark(AppTheme.defaultSeed));
      final Color blue = await midColor(AppTheme.dark(AppTheme.presetSeeds[7]));

      expect(warm, isNot(blue), reason: '换配色后中段色应当跟着变');
    });
  });
}

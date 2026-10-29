import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/lyrics_view.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

LyricLine _line({
  required int start,
  required int end,
  required String text,
  List<LyricWord> words = const <LyricWord>[],
  String translation = '',
}) {
  return LyricLine(
    timeMs: start,
    endMs: end,
    text: text,
    words: words,
    translation: translation,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<LyricLine> lines,
  required ValueNotifier<double> position,
  required ValueNotifier<bool> playing,
  ValueChanged<double>? onSeek,
  double band = 0,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: LyricsView(
          lines: lines,
          position: position,
          playing: playing,
          onSeek: (double seconds) async => onSeek?.call(seconds),
          edgeFadeBand: band,
        ),
      ),
    ),
  );
  // 逐字歌词会起 Ticker，不能用 pumpAndSettle（永远不收敛）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets('歌词固定白色并放大，当前行更实', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(1.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(start: 0, end: 5000, text: '当前行'),
        _line(start: 5000, end: 9000, text: '下一行'),
      ],
      position: position,
      playing: playing,
    );

    final Text active = tester.widget<Text>(find.text('当前行'));
    final Text inactive = tester.widget<Text>(find.text('下一行'));

    expect(active.style?.fontSize, 28);
    expect(inactive.style?.fontSize, 22);
    expect(active.style?.color?.r, 1);
    expect(active.style?.color?.g, 1);
    expect(active.style?.color?.b, 1);
    expect(active.style?.color?.a, closeTo(0.96, 0.01));
    expect(inactive.style?.color?.a, closeTo(0.42, 0.01));
  });

  testWidgets('逐字歌词随进度裁切高亮', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(1.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(
          start: 1000,
          end: 5000,
          text: '大人はずっと',
          words: const <LyricWord>[
            LyricWord(timeMs: 1000, text: '大'),
            LyricWord(timeMs: 2000, text: '人'),
            LyricWord(timeMs: 3000, text: 'は'),
            LyricWord(timeMs: 4000, text: 'ずっと'),
          ],
        ),
      ],
      position: position,
      playing: playing,
    );

    final Finder prefix = find.byWidgetPredicate(
      (Widget widget) =>
          widget is CustomPaint && widget.painter is KaraokePrefixPainter,
    );
    final Finder word = find.byWidgetPredicate(
      (Widget widget) =>
          widget is CustomPaint && widget.painter is KaraokeWordPainter,
    );
    expect(prefix, findsOneWidget, reason: '当前行要走逐字染色');
    expect(word, findsOneWidget, reason: '正在唱的那个字单独一层');

    /// 已唱区域的宽度 = 前缀层（整字填满）+ 当前字（按进度）
    Future<double> fillAt(double seconds) async {
      position.value = seconds;
      await tester.pump();
      final double done =
          (tester.widget<CustomPaint>(prefix).painter! as KaraokePrefixPainter)
              .fillPath
              .getBounds()
              .width;
      if (word.evaluate().isEmpty) {
        return done;
      }
      final double singing =
          (tester.widget<CustomPaint>(word).painter! as KaraokeWordPainter)
              .clipPath
              .getBounds()
              .width;
      return done + singing;
    }

    expect(await fillAt(1.0), 0, reason: '第一字起点还没开始唱');
    final double early = await fillAt(2.0);
    final double late = await fillAt(3.0);
    expect(early, greaterThan(0));
    expect(late, greaterThan(early), reason: '时间越往后染色越宽');
    // 染色区必须落在文字上：宽度不超过整行
    expect(await fillAt(4.9), lessThan(200));

    // 同一个字里推进进度只该重绘那一层，不该重建画笔（重建 = 前缀层跟着重画）
    position.value = 1.2;
    await tester.pump();
    final Object tickPainter = tester.widget<CustomPaint>(word).painter!;
    position.value = 1.4;
    await tester.pump();
    expect(
      identical(tickPainter, tester.widget<CustomPaint>(word).painter),
      isTrue,
      reason: '同一个字内推进进度不该重建画笔',
    );

    // 换到下一个字才重建（前缀层要把刚唱完的字并进去）
    final Object beforeWord = tester.widget<CustomPaint>(prefix).painter!;
    position.value = 2.4;
    await tester.pump();
    expect(
      identical(beforeWord, tester.widget<CustomPaint>(prefix).painter),
      isFalse,
      reason: '跨过一个字时前缀层要重建',
    );
  });

  testWidgets('翻译与罗马音显示在正文下方', (WidgetTester tester) async {
    // 定位在该行内，验证当前行的正文/译文比例
    final ValueNotifier<double> position = ValueNotifier<double>(2);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(
          start: 1000,
          end: 5000,
          text: '大人はずっと',
          translation: 'o to na wa zu tto\n大人一直说',
        ),
      ],
      position: position,
      playing: playing,
    );

    expect(find.text('大人はずっと'), findsOneWidget);
    expect(find.text('o to na wa zu tto'), findsOneWidget);
    expect(find.text('大人一直说'), findsOneWidget);

    // 译文只比正文略小，比例约 0.83，不能断层
    final double body = tester
        .widget<Text>(find.text('大人はずっと'))
        .style!
        .fontSize!;
    final double latin = tester
        .widget<Text>(find.text('o to na wa zu tto'))
        .style!
        .fontSize!;
    final double cjk = tester.widget<Text>(find.text('大人一直说')).style!.fontSize!;
    expect(body, 28);
    expect(latin / body, greaterThan(0.7), reason: '罗马音不能比正文小太多');
    expect(cjk / body, greaterThan(0.75), reason: '译文不能比正文小太多');
    expect(cjk, lessThan(body), reason: '译文仍需略小于正文');
  });

  testWidgets('点击歌词行按该行时间跳转', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    final List<double> seeks = <double>[];
    await _pump(
      tester,
      lines: <LyricLine>[
        _line(start: 1000, end: 5000, text: '第一行'),
        _line(start: 5000, end: 9000, text: '第二行'),
      ],
      position: position,
      playing: playing,
      onSeek: seeks.add,
    );

    await tester.tap(find.text('第二行'));
    await tester.pump();
    expect(seeks.single, closeTo(5.0, 0.001));
  });

  test('上下淡出的 stops：底部盖过丝带再留一段过渡', () {
    final List<double> stops = lyricFadeStops(height: 700, top: 44, band: 78);
    expect(stops.first, 0);
    expect(stops.last, 1);
    expect(stops[1] * 700, closeTo(44, 0.5), reason: '顶部只藏半行');
    final double bottom = (1 - stops[2]) * 700;
    expect(
      bottom,
      greaterThanOrEqualTo(78 + 40),
      reason: '盖住 78 高的频谱丝带之后还要有过渡段',
    );
    expect(bottom, lessThan(700 / 2), reason: '别把半个歌词区都吃掉');
  });

  test('歌词区很矮时过渡收缩到下限，不越过顶部淡出', () {
    final List<double> small = lyricFadeStops(height: 200, top: 44, band: 78);
    expect((1 - small[2]) * 200, closeTo(78 + 40, 0.5));
    for (int i = 1; i < small.length; i += 1) {
      expect(
        small[i],
        greaterThanOrEqualTo(small[i - 1]),
        reason: 'stops 不能反序',
      );
    }
    // 极端情况（比两段之和还矮）收成一条硬边，而不是让 stops 反序
    final List<double> tiny = lyricFadeStops(height: 60, top: 44, band: 78);
    expect(tiny[1], tiny[2]);
    for (int i = 1; i < tiny.length; i += 1) {
      expect(tiny[i], greaterThanOrEqualTo(tiny[i - 1]));
    }
  });

  testWidgets('整片歌词套 dstIn 遮罩做边界淡出', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(start: 0, end: 5000, text: '第一行'),
        _line(start: 5000, end: 9000, text: '第二行'),
      ],
      position: position,
      playing: playing,
      band: 78,
    );

    final Finder maskFinder = find.byKey(
      const ValueKey<String>('lyrics-edge-fade'),
    );
    final ShaderMask mask = tester.widget<ShaderMask>(maskFinder);
    expect(mask.blendMode, BlendMode.dstIn);
    final Rect rect = tester.getRect(maskFinder);
    expect(rect.height, greaterThan(0));
    expect(
      mask.shaderCallback(Offset.zero & rect.size),
      isNotNull,
      reason: '遮罩要按歌词区尺寸算出渐变',
    );
  });
}

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

    expect(active.style?.fontSize, 30);
    expect(inactive.style?.fontSize, 24);
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

    final Finder karaoke = find.byWidgetPredicate(
      (Widget widget) =>
          widget is CustomPaint && widget.painter is KaraokeTextPainter,
    );
    expect(karaoke, findsOneWidget, reason: '当前行要走逐字染色');

    Future<Rect> fillAt(double seconds) async {
      position.value = seconds;
      await tester.pump();
      final CustomPaint paint = tester.widget<CustomPaint>(karaoke);
      return (paint.painter! as KaraokeTextPainter).fillPath.getBounds();
    }

    expect((await fillAt(1.0)).width, 0, reason: '第一字起点还没开始唱');
    final double early = (await fillAt(2.0)).width;
    final double late = (await fillAt(3.0)).width;
    expect(early, greaterThan(0));
    expect(late, greaterThan(early), reason: '时间越往后染色越宽');
    // 染色区必须落在文字上：宽度不超过整行，左边界不为负
    expect((await fillAt(4.9)).width, lessThan(200));
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
    expect(body, 30);
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
}

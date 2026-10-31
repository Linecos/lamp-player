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
  double alignment = 0.5,
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
          revealAlignment: alignment,
        ),
      ),
    ),
  );
  // 逐字歌词会起 Ticker，不能用 pumpAndSettle（永远不收敛）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets('当前行停在 revealAlignment 指定的高度', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(12.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        for (int i = 0; i < 8; i += 1)
          _line(start: i * 5000, end: i * 5000 + 5000, text: '第$i行'),
      ],
      position: position,
      playing: playing,
      alignment: 0.3,
    );

    final Rect viewport = tester.getRect(
      find.byKey(const ValueKey<String>('lyrics-edge-fade')),
    );
    final Rect active = tester.getRect(
      find.byKey(const ValueKey<String>('lyric-2')),
    );
    expect(
      active.center.dy,
      closeTo(viewport.top + viewport.height * 0.3, 8),
      reason: '对齐线以上的空间按 revealAlignment 分配，不是永远居中',
    );
  });

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
    expect(inactive.style?.color?.a, closeTo(0.62, 0.01));
  });

  testWidgets('越远的行越模糊：从相邻行就开始，逐级递增', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        for (int i = 0; i < 6; i += 1)
          _line(start: i * 5000, end: (i + 1) * 5000, text: '第 $i 行'),
      ],
      position: position,
      playing: playing,
    );

    // 当前行之外的 5 行都带一点模糊：从相邻行就开始，一级一级往上加，
    // 不要「1 行全清、下一行直接糊掉」那种跳档
    expect(find.byType(ImageFiltered), findsNWidgets(5));
  });

  testWidgets('未播放行的译文与正文一起模糊', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(1.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(start: 0, end: 5000, text: '第 0 行', translation: '译文 0'),
        _line(start: 5000, end: 10000, text: '第 1 行', translation: '译文 1'),
      ],
      position: position,
      playing: playing,
    );

    // 当前行（第 0 行）正文与译文都清晰；第 1 行的正文和译文各套一层模糊，
    // 只糊正文时译文会孤零零地清楚着
    expect(find.byType(ImageFiltered), findsNWidgets(2));
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

  test('上下淡出的 stops：两端各留缓冲，底部盖过丝带再留一段过渡', () {
    final List<double> stops = lyricFadeStops(height: 700, top: 76, band: 78);
    expect(stops, hasLength(8), reason: '两端各三段缓冲，中间两段全不透明');
    expect(stops.first, 0);
    expect(stops.last, 1);
    expect(stops[1], greaterThan(0), reason: '顶部第一段缓冲要露出来，alpha 才是缓起');
    expect(stops[3] * 700, closeTo(76, 0.5), reason: '顶部过渡到 76 走完');
    final double bottom = (1 - stops[4]) * 700;
    expect(
      bottom,
      greaterThanOrEqualTo(78 + 56),
      reason: '盖住 78 高的频谱丝带之后还要有过渡段',
    );
    expect(bottom, lessThan(700 / 2), reason: '别把半个歌词区都吃掉');
  });

  test('歌词区很矮时过渡收缩到下限，不越过顶部淡出', () {
    final List<double> small = lyricFadeStops(height: 260, top: 76, band: 78);
    expect((1 - small[4]) * 260, closeTo(78 + 56, 0.5));
    for (int i = 1; i < small.length; i += 1) {
      expect(
        small[i],
        greaterThanOrEqualTo(small[i - 1]),
        reason: 'stops 不能反序',
      );
    }
    // 极端情况（比两段之和还矮）收成一条硬边，而不是让 stops 反序
    final List<double> tiny = lyricFadeStops(height: 60, top: 76, band: 78);
    expect(tiny[1], tiny[4]);
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

  group('弹性滚动', () {
    List<LyricLine> manyLines() => <LyricLine>[
      for (int i = 0; i < 24; i += 1)
        _line(start: i * 5000, end: (i + 1) * 5000, text: '第 $i 行的歌词'),
    ];

    /// 歌词区的滚动控制器（`SingleChildScrollView` 只有一个）
    ScrollController controllerOf(WidgetTester tester) => tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;

    testWidgets('拖到边界是橡皮筋回弹，不是贴住', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(0);
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(position.dispose);
      addTearDown(playing.dispose);

      await _pump(
        tester,
        lines: manyLines(),
        position: position,
        playing: playing,
      );

      final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(view.physics, isA<BouncingScrollPhysics>());
    });

    testWidgets('歌词区不再挂滚动条', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(0);
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(position.dispose);
      addTearDown(playing.dispose);

      await _pump(
        tester,
        lines: manyLines(),
        position: position,
        playing: playing,
      );

      final ScrollConfiguration config = tester.widget<ScrollConfiguration>(
        find.descendant(
          of: find.byType(LyricsView),
          matching: find.byType(ScrollConfiguration),
        ),
      );
      // `scrollbars: false` 的表现就是不再往子树外包一层滚动条
      const Widget probe = SizedBox(key: ValueKey<String>('probe'));
      final Widget built = config.behavior.buildScrollbar(
        tester.element(find.byType(LyricsView)),
        probe,
        const ScrollableDetails(direction: AxisDirection.down),
      );
      expect(identical(built, probe), isTrue, reason: '不该再包一层滚动条');
    });

    testWidgets('换行时整列瞬时归位，各行错峰弹回来', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(52);
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(position.dispose);
      addTearDown(playing.dispose);

      await _pump(
        tester,
        lines: manyLines(),
        position: position,
        playing: playing,
      );

      final ScrollController controller = controllerOf(tester);
      // 第 10 行（50~55s）居中
      final double before = controller.offset;

      /// 某一行自己的弹簧位移（`Transform` 的 Y 偏移）
      double shiftOf(int index) {
        final Finder spring = find.descendant(
          of: find.byKey(ValueKey<String>('lyric-$index')),
          matching: find.byType(Transform),
        );
        if (spring.evaluate().isEmpty) {
          return 0;
        }
        return tester
            .widget<Transform>(spring.first)
            .transform
            .getTranslation()
            .y;
      }

      playing.value = true;
      await tester.pump();

      // 跨过 55s 换到第 11 行：滚动位置这一帧就归位
      position.value = 57;
      await tester.pump();
      final double after = controller.offset;
      final double delta = after - before;
      expect(delta, greaterThan(20), reason: '换行那一帧整列直接归到新行');

      // 但每行被推回去同样多，所以画面上并没有跳
      expect(shiftOf(11), closeTo(delta, 1), reason: '新当前行先被推回原位');

      // 最上面那行先起步，下面的行还在等：一行一行接力，不是整块平移
      final int first = <int>[
        for (int i = 0; i < 24; i += 1)
          if (shiftOf(i).abs() > 0.5) i,
      ].first;
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        shiftOf(first).abs(),
        lessThan(delta.abs() - 2),
        reason: '最上面那行已经开始弹',
      );
      expect(shiftOf(first + 4), closeTo(delta, 0.01), reason: '下面的行还在错峰等待');
      expect(
        controller.offset,
        closeTo(after, 0.01),
        reason: '弹动靠每行的 Transform，滚动位置不再逐帧改',
      );

      // 1.5s 后全部归位
      for (int i = 0; i < 15; i += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (int i = first; i <= first + 6; i += 1) {
        expect(shiftOf(i).abs(), lessThan(0.6), reason: '第 $i 行要弹回排版位置');
      }

      // 关掉播放，别把时钟的 Timer 留到下一个用例
      playing.value = false;
      await tester.pump();
    });
  });
}

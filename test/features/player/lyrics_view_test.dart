import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/lyric_alignment.dart';
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
  LyricAlignment lyricAlign = LyricAlignment.center,
  bool showTranslation = true,
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
          alignment: lyricAlign,
          showTranslation: showTranslation,
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

  testWidgets('对齐方式把整行推到左 / 中 / 右', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(12.5);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    final List<LyricLine> lines = <LyricLine>[
      for (int i = 0; i < 8; i += 1)
        _line(start: i * 5000, end: i * 5000 + 5000, text: '第$i行'),
    ];

    Future<Rect> rectFor(LyricAlignment value) async {
      await _pump(
        tester,
        lines: lines,
        position: position,
        playing: playing,
        lyricAlign: value,
      );
      return tester.getRect(find.text('第2行'));
    }

    // 歌词区宽 900：外层左右各 16，留给文字的是 868；正文列固定 640 并居中，
    // 所以列的范围是 130~770，再各减去每行的 12 内边距 → 142 / 758
    final Rect left = await rectFor(LyricAlignment.left);
    final Rect center = await rectFor(LyricAlignment.center);
    final Rect right = await rectFor(LyricAlignment.right);

    expect(left.left, closeTo(142, 0.5), reason: '左对齐落在正文列的左边，不是贴住歌词区');
    expect(center.center.dx, closeTo(450, 0.5), reason: '默认居中');
    expect(right.right, closeTo(758, 0.5));
    expect(
      center.center.dx,
      closeTo((left.left + right.right) / 2, 0.5),
      reason: '三种对齐都绕同一个列中线，切换时整块不该往一侧跑',
    );
  });

  testWidgets('当前行放大后，与上下两行的间距仍然相等', (WidgetTester tester) async {
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
    );
    // 等缩放跑完（600ms）
    for (int i = 0; i < 45; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // getRect 会带上祖先那个放大变换，量到的是**看起来**的框
    final Rect previous = tester.getRect(find.text('第1行'));
    final Rect active = tester.getRect(find.text('第2行'));
    final Rect next = tester.getRect(find.text('第3行'));

    expect(
      active.height,
      greaterThan(previous.height * 1.2),
      reason: '当前行确实放大了',
    );
    expect(previous.bottom, lessThan(active.top), reason: '放大不该压到上一行');
    expect(next.top, greaterThan(active.bottom), reason: '放大不该压到下一行');
    expect(
      active.top - previous.bottom,
      closeTo(next.top - active.bottom, 0.5),
      reason: '上下各溢出一半，间距才一样；贴顶放大时上面会多出 8.7px',
    );

    // 视觉中心要和排版中心重合，居中滚动那套对齐线才不用改
    final Rect layout = tester.getRect(
      find.byKey(const ValueKey<String>('lyric-2')),
    );
    expect(active.center.dy, closeTo(layout.center.dy, 0.5));
  });

  testWidgets('超过列宽的一行折行，三种对齐的折法一致', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0.5);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    // 60 个汉字：22px 下约 1320 宽，必然要折成两行以上
    final String longLine = '长' * 60;
    final List<LyricLine> lines = <LyricLine>[
      _line(start: 0, end: 5000, text: longLine),
      _line(start: 5000, end: 9000, text: '短行'),
    ];

    // 量排版尺寸（`getSize` 拿的是自己的盒子，不含当前行那个放大变换），
    // 折行只跟排版宽度有关
    Future<Size> sizeFor(LyricAlignment value) async {
      await _pump(
        tester,
        lines: lines,
        position: position,
        playing: playing,
        lyricAlign: value,
      );
      return tester.getSize(find.text(longLine));
    }

    final Size center = await sizeFor(LyricAlignment.center);
    final Size left = await sizeFor(LyricAlignment.left);

    expect(center.width, closeTo(616, 0.5), reason: '折到列宽为止（640 - 两侧 12）');
    expect(center.height, greaterThan(60), reason: '这么长的行必须折行');
    expect(left.height, center.height, reason: '对齐方式不该改变折行结果');
  });

  testWidgets('逐字染色的当前行跟着一起对齐', (WidgetTester tester) async {
    expect(karaokeEnabled, isTrue, reason: '逐字染色默认是开的');
    final ValueNotifier<double> position = ValueNotifier<double>(6.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    final List<LyricLine> lines = <LyricLine>[
      _line(start: 0, end: 5000, text: '第一行'),
      _line(
        start: 5000,
        end: 10000,
        text: '逐字一行',
        words: const <LyricWord>[
          LyricWord(timeMs: 5000, text: '逐字'),
          LyricWord(timeMs: 7000, text: '一行'),
        ],
      ),
    ];

    // 逐字层用自绘，文字位置只能在画笔里看；量它的容器（Semantics 那一层）
    Future<Rect> blockFor(LyricAlignment value) async {
      await _pump(
        tester,
        lines: lines,
        position: position,
        playing: playing,
        lyricAlign: value,
      );
      return tester.getRect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics && widget.properties.label == '逐字一行',
        ),
      );
    }

    final Rect left = await blockFor(LyricAlignment.left);
    final Rect right = await blockFor(LyricAlignment.right);

    expect(left.left, closeTo(142, 0.5), reason: '逐字行也要贴着同一列，不能和别的行错位');
    expect(right.right, closeTo(758, 0.5));
  });

  testWidgets('当前行靠缩放放大，字号恒定不变', (WidgetTester tester) async {
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

    // 字号必须恒定：改字号会让长句重新折行（22 一行装得下、28 要折两行），
    // 整列高度重排，换行时那套统一的位移补偿就补不准了
    expect(active.style?.fontSize, 22, reason: '当前行不再改字号');
    expect(inactive.style?.fontSize, 22);
    expect(active.style?.color?.r, 1);
    expect(active.style?.color?.g, 1);
    expect(active.style?.color?.b, 1);
    expect(active.style?.color?.a, closeTo(0.96, 0.01));
    expect(inactive.style?.color?.a, closeTo(0.62, 0.01));

    /// 整行外层那个缩放的**目标**倍数；没挂缩放层时返回 null
    double? scaleOf(String text) {
      final Finder finder = find.ancestor(
        of: find.text(text),
        matching: find.byType(AnimatedScale),
      );
      if (finder.evaluate().isEmpty) {
        return null;
      }
      return tester.widget<AnimatedScale>(finder.first).scale;
    }

    expect(scaleOf('当前行'), closeTo(28 / 22, 1e-9), reason: '放大到 28 的视觉效果');
    // 其余行不挂：`AnimatedScale` 每行一层 `Transform`，叠在 `RepaintBoundary`
    // 上会让光栅缓存翻倍（release 实测 60 行多 42MB）
    expect(scaleOf('下一行'), isNull, reason: '非当前行不该有缩放层');
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

    // distance 1~5 各一行，全都带模糊：级别逐级递增，不能「1 行全清、下一行糊死」，
    // 也不能到某一档就突然变清楚（那样屏幕上会出现「糊 → 清楚 → 再淡」的断档）
    expect(find.byType(ImageFiltered), findsNWidgets(5));
  });

  testWidgets('拖动歌词时临时关掉模糊，松手 3 秒后恢复', (WidgetTester tester) async {
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
    expect(find.byType(ImageFiltered), findsNWidgets(5), reason: '静止时远处行是糊的');

    // 手指拖动：ScrollStartNotification 带 dragDetails，进入「用户接管滚动」状态
    await tester.drag(find.byType(LyricsView), const Offset(0, -140));
    await tester.pump();
    expect(
      find.byType(ImageFiltered),
      findsNothing,
      reason: '滚动中不该再糊：一行都看不清，还每帧多跑一遍模糊光栅',
    );

    // 停手 3 秒后才跟回当前行，这时模糊也一起回来
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNWidgets(5), reason: '恢复后照旧逐级模糊');
  });

  testWidgets('鼠标滚轮滚动时同样临时关掉模糊', (WidgetTester tester) async {
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
    expect(find.byType(ImageFiltered), findsNWidgets(5));

    // 滚轮产生的 ScrollStartNotification 不带 dragDetails，
    // 只靠滚动通知认不出「用户在滚」，得看指针信号
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(LyricsView)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 90)));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing, reason: '滚轮滚出来的行也要看得清');

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNWidgets(5), reason: '停手 3 秒后恢复');
  });

  testWidgets('自动跟随换行不算用户滚动，模糊不动', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(true);
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
    expect(find.byType(ImageFiltered), findsNWidgets(5));

    // 播放推进到下一行：程序自己 jumpTo，不该被当成「用户在滚」
    position.value = 5.2;
    for (int i = 0; i < 40; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      find.byType(ImageFiltered),
      findsNWidgets(5),
      reason:
          '自动跟随换行时模糊要保留，不然每换一行就闪一下清晰'
          '（换行后当前行在中间，distance 1 上下各一行，再往上一级级往上，共 5 层）',
    );
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

    // 译文只比正文略小，比例约 0.8，不能断层。正文恒为 22（当前行靠缩放放大，
    // 见 [_lyricFontSize]），译文跟着这个基准走
    final double body = tester
        .widget<Text>(find.text('大人はずっと'))
        .style!
        .fontSize!;
    final double latin = tester
        .widget<Text>(find.text('o to na wa zu tto'))
        .style!
        .fontSize!;
    final double cjk = tester.widget<Text>(find.text('大人一直说')).style!.fontSize!;
    expect(body, 22);
    expect(latin / body, greaterThan(0.7), reason: '罗马音不能比正文小太多');
    expect(cjk / body, greaterThan(0.75), reason: '译文不能比正文小太多');
    expect(cjk, lessThan(body), reason: '译文仍需略小于正文');
  });

  testWidgets('关掉译文时译文块不占高度', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0.5);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    /// 译文块外面那层裁切框：高度 0 就表示它没占位置
    double blockHeight(String text) => tester
        .getSize(
          find
              .ancestor(of: find.text(text), matching: find.byType(ClipRect))
              .first,
        )
        .height;

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(start: 0, end: 5000, text: '第一行', translation: 'first line'),
        _line(start: 5000, end: 9000, text: '第二行', translation: 'second line'),
      ],
      position: position,
      playing: playing,
      showTranslation: false,
    );

    expect(blockHeight('first line'), 0, reason: '收起时不该占任何高度');
    expect(blockHeight('second line'), 0);
    expect(find.text('第一行'), findsOneWidget, reason: '正文照旧');

    await _pump(
      tester,
      lines: <LyricLine>[
        _line(start: 0, end: 5000, text: '第一行', translation: 'first line'),
        _line(start: 5000, end: 9000, text: '第二行', translation: 'second line'),
      ],
      position: position,
      playing: playing,
    );
    for (int i = 0; i < 40; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(blockHeight('first line'), greaterThan(10), reason: '打开后要占回高度');
  });

  testWidgets('切换译文时译文块不重建（结构不随进度变化）', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(12.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    final List<LyricLine> lines = <LyricLine>[
      for (int i = 0; i < 6; i += 1)
        _line(
          start: i * 5000,
          end: i * 5000 + 5000,
          text: '第$i行',
          translation: 'line $i',
        ),
    ];

    await _pump(
      tester,
      lines: lines,
      position: position,
      playing: playing,
      showTranslation: false,
    );
    for (int i = 0; i < 30; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final Element before = tester.element(find.text('line 0'));

    await _pump(tester, lines: lines, position: position, playing: playing);
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      identical(tester.element(find.text('line 0')), before),
      isTrue,
      reason: '展开的第一帧就换掉控件结构的话，带 key 的子级会被重挂，看着闪一下',
    );
  });

  testWidgets('切换译文：整列缓出收放，当前行一帧都不动', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(12.0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    final List<LyricLine> lines = <LyricLine>[
      for (int i = 0; i < 6; i += 1)
        _line(
          start: i * 5000,
          end: i * 5000 + 5000,
          text: '第$i行',
          translation: 'line $i',
        ),
    ];

    await _pump(tester, lines: lines, position: position, playing: playing);
    final double activeBefore = tester.getRect(find.text('第2行')).center.dy;
    final double belowBefore = tester.getRect(find.text('第4行')).center.dy;

    // 同一棵树里换 prop，state 复用才会走 didUpdateWidget 的过渡
    await _pump(
      tester,
      lines: lines,
      position: position,
      playing: playing,
      showTranslation: false,
    );

    double maxDrift = 0;
    double belowMid = belowBefore;
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      maxDrift = math.max(
        maxDrift,
        (tester.getRect(find.text('第2行')).center.dy - activeBefore).abs(),
      );
      belowMid = tester.getRect(find.text('第4行')).center.dy;
    }

    // 收起过程中下面的行应该已经往上走，但还没到位
    expect(belowMid, lessThan(belowBefore), reason: '下面的行跟着往上收');
    expect(
      maxDrift,
      lessThan(1),
      reason: '补偿量按同一条曲线算，当前行一帧都不该动（旧实现会先跳 33px 再爬回来）',
    );

    // 逐帧走完动画（真实运行就是 16ms 一帧）
    for (int i = 0; i < 40; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump();

    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.text('line 0'),
                  matching: find.byType(ClipRect),
                )
                .first,
          )
          .height,
      0,
      reason: '收完之后译文不占高度',
    );
    expect(
      (tester.getRect(find.text('第2行')).center.dy - activeBefore).abs(),
      lessThan(1),
      reason: '收完仍停在原来的位置',
    );
    final double belowCollapsed = tester.getRect(find.text('第4行')).center.dy;
    expect(belowCollapsed, lessThan(belowBefore), reason: '整列确实变短了');

    // 再打开：译文长回来，下面的行被顶回去，当前行照样不动
    await _pump(tester, lines: lines, position: position, playing: playing);
    double maxDriftBack = 0;
    for (int i = 0; i < 40; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      maxDriftBack = math.max(
        maxDriftBack,
        (tester.getRect(find.text('第2行')).center.dy - activeBefore).abs(),
      );
    }
    await tester.pump();

    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.text('line 0'),
                  matching: find.byType(ClipRect),
                )
                .first,
          )
          .height,
      greaterThan(10),
      reason: '展开后译文回来',
    );
    expect(
      tester.getRect(find.text('第4行')).center.dy,
      greaterThan(belowCollapsed),
      reason: '展开把下面的行顶回去',
    );
    expect(maxDriftBack, lessThan(1), reason: '展开方向同样一帧都不动');
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
    // 死区由「视口内第一条完整行的顶边」决定，这里取一行的高度
    final List<double> stops = lyricFadeStops(
      height: 700,
      top: 120,
      band: 78,
      deadZone: 60,
    );
    expect(stops, hasLength(8), reason: '两端各三段缓冲，中间两段全不透明');
    expect(stops.first, 0);
    expect(stops.last, 1);
    expect(
      stops[1] * 700,
      closeTo(60, 0.5),
      reason: '死区边界落在行与行之间，死区内 alpha 恒为 0',
    );
    expect(stops[3] * 700, closeTo(120, 0.5), reason: '顶部过渡到 120 走完');
    expect(stops[2], greaterThan(stops[1]), reason: '死区结束后仍要有渐变段，不能变成硬切');
    // 死区比渐变还高时夹住，别让 stops 反序
    final List<double> clamped = lyricFadeStops(
      height: 700,
      top: 60,
      band: 78,
      deadZone: 200,
    );
    expect(clamped[1], closeTo(60 / 700, 1e-9));
    final double bottom = (1 - stops[4]) * 700;
    expect(
      bottom,
      greaterThanOrEqualTo(78 + 56),
      reason: '盖住 78 高的频谱丝带之后还要有过渡段',
    );
    expect(bottom, lessThan(700 / 2), reason: '别把半个歌词区都吃掉');
  });

  test('死区越过行框边界 2px：模糊底笔不会从渐显段漏出', () {
    // 行内下内边距 9px，最远行的模糊 σ=3.2 会外溢约 10px，正好越过行框 1px
    expect(deadZoneBoundary(20, 700), closeTo(22, 1e-9));
    expect(deadZoneBoundary(0, 700), closeTo(2, 1e-9));
    // 上限仍按歌词区高度的 42% 夹住
    expect(deadZoneBoundary(600, 700), closeTo(700 * 0.42, 1e-9));
  });

  test('模糊强度逐级递增，中间不许有空档', () {
    expect(lyricBlurSigma(0), 0, reason: '当前行必须清楚');
    // 每一档都比上一档更糊：中间某一档归零的话，屏幕上会出现
    // 「糊 → 清楚 → 再淡」的断档，看着像漏处理（排查内存时真这么干过）
    for (int d = 1; d <= 5; d += 1) {
      expect(
        lyricBlurSigma(d),
        greaterThan(lyricBlurSigma(d - 1)),
        reason: '第 $d 行要比第 ${d - 1} 行更糊',
      );
    }
    expect(lyricBlurSigma(1), closeTo(0.5, 1e-9), reason: '相邻行只给一点糊');
    expect(lyricBlurSigma(4), closeTo(2.5, 1e-9));
    expect(lyricBlurSigma(5), closeTo(3.2, 1e-9));
    expect(lyricBlurSigma(20), lyricBlurSigma(5), reason: '最远处封顶，别继续加厚');
  });

  test('歌词区很矮时过渡收缩到下限，不越过顶部淡出', () {
    final List<double> small = lyricFadeStops(
      height: 260,
      top: math.min(120, 260 * 0.38),
      band: 78,
    );
    expect((1 - small[4]) * 260, closeTo(78 + 56, 0.5));
    for (int i = 1; i < small.length; i += 1) {
      expect(
        small[i],
        greaterThanOrEqualTo(small[i - 1]),
        reason: 'stops 不能反序',
      );
    }
    // 极端情况（比两段之和还矮）收成一条硬边，而不是让 stops 反序
    final List<double> tiny = lyricFadeStops(
      height: 60,
      top: math.min(120, 60 * 0.38),
      band: 78,
    );
    expect(tiny[1], tiny[4]);
    for (int i = 1; i < tiny.length; i += 1) {
      expect(tiny[i], greaterThanOrEqualTo(tiny[i - 1]));
    }
  });

  test('边界渐隐曲线：顶部死区 0、中间 1、底部淡出', () {
    // 600 高的视口、顶部死区 45 + 淡入段到 90、底部丝带 78
    final List<double> stops = lyricFadeStops(
      height: 600,
      top: 90,
      band: 78,
      deadZone: 45,
    );
    expect(
      lyricRowOpacity(top: 0, bottom: 40, height: 600, stops: stops),
      0,
      reason: '死区里的行整行不可见',
    );
    expect(
      lyricRowOpacity(top: 260, bottom: 300, height: 600, stops: stops),
      1,
      reason: '中间区域原样',
    );
    expect(
      lyricRowOpacity(top: 560, bottom: 600, height: 600, stops: stops),
      lessThan(0.3),
      reason: '底部边界要淡到几乎看不见',
    );
  });

  testWidgets('边界淡出按行给 alpha，不再整片套 dstIn 遮罩', (WidgetTester tester) async {
    final ValueNotifier<double> position = ValueNotifier<double>(0);
    final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
    addTearDown(position.dispose);
    addTearDown(playing.dispose);

    await _pump(
      tester,
      lines: <LyricLine>[
        for (int i = 0; i < 24; i += 1)
          _line(start: i * 5000, end: (i + 1) * 5000, text: '第 $i 行的歌词'),
      ],
      position: position,
      playing: playing,
      band: 78,
    );

    // 遮罩是一张全宽的离屏图层：滚动和转场时每帧都要重新分配，这才是要拆掉的东西
    expect(find.byType(ShaderMask), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('lyrics-edge-fade')),
      findsOneWidget,
      reason: '视口本身还在，只是不再当遮罩用',
    );
    // 底部超出一屏，最后几行必须拿到小于 1 的 alpha（否则就是没生效）
    final Iterable<Text> texts = tester.widgetList<Text>(find.byType(Text));
    expect(
      texts.any((Text text) => (text.style?.color?.a ?? 1) < 0.2),
      isTrue,
      reason: '底部的行要淡到几乎看不见',
    );
  });

  group('弹性滚动', () {
    List<LyricLine> manyLines() => <LyricLine>[
      for (int i = 0; i < 24; i += 1)
        _line(start: i * 5000, end: (i + 1) * 5000, text: '第 $i 行的歌词'),
    ];

    /// 歌词区的滚动控制器（滚动列表只有一个）
    ScrollController controllerOf(WidgetTester tester) =>
        tester.widget<ListView>(find.byType(ListView)).controller!;

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

      final ListView view = tester.widget<ListView>(find.byType(ListView));
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

    testWidgets('换到会折行的长句，下面的行不被整列顶下去', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(52);
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(position.dispose);
      addTearDown(playing.dispose);

      // 第 11 行很长：22px 下一行装得下，28px 就要折成两行。
      // 以前当前行是改字号的，这一折行会把下面每一行瞬间顶下去 40 多像素，
      // 也就是「整列跳一下」的真身
      await _pump(
        tester,
        lines: <LyricLine>[
          for (int i = 0; i < 24; i += 1)
            _line(
              start: i * 5000,
              end: (i + 1) * 5000,
              text: i == 11 ? '这一句特别长' * 5 : '第 $i 行的歌词',
            ),
        ],
        position: position,
        playing: playing,
      );

      /// 行内的 RepaintBoundary 在弹簧 Transform 里面，画的位置带上了弹簧位移
      double paintedAt(int index) => tester
          .getRect(
            find
                .descendant(
                  of: find.byKey(ValueKey<String>('lyric-$index')),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          )
          .center
          .dy;

      playing.value = true;
      await tester.pump();

      final double activeBefore = paintedAt(11);
      final double belowBefore = paintedAt(15);

      position.value = 57; // 换到第 11 行
      await tester.pump();

      expect(
        paintedAt(15),
        closeTo(belowBefore, 1),
        reason: '折行不再重排整列：下面的行这一帧不该动',
      );
      expect(paintedAt(11), closeTo(activeBefore, 1), reason: '当前行自己也不该跳');

      playing.value = false;
      await tester.pump();
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

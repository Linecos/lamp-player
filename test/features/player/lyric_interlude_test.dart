import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/lyric_alignment.dart';
import 'package:lamp_player/src/features/player/lyrics_view.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 造一行：`end` 和 Rust 侧一样取下一句的起始时间，`sungEnd` 是最后一个字的时间；
/// 不传 `sungEnd` 就是没有逐字轴的行
LyricLine _line({
  required int start,
  required int end,
  required String text,
  int? sungEnd,
}) {
  return LyricLine(
    timeMs: start,
    endMs: end,
    text: text,
    words: sungEnd == null
        ? const <LyricWord>[]
        : <LyricWord>[
            LyricWord(timeMs: start, text: text),
            if (sungEnd != start) LyricWord(timeMs: sungEnd, text: text),
          ],
    translation: '',
  );
}

/// 前奏 8 秒 + 第三句唱完到下一句之间有 9.7 秒真空白
List<LyricLine> _song() => <LyricLine>[
  _line(start: 8000, end: 12000, text: '第一句', sungEnd: 9000),
  _line(start: 12000, end: 16000, text: '第二句', sungEnd: 13000),
  _line(start: 16000, end: 25900, text: '第三句', sungEnd: 16200),
  _line(start: 25900, end: 30000, text: '第四句', sungEnd: 27000),
];

void main() {
  group('lyricInterludeAt', () {
    test('前奏算间奏，进度从 0 走到 1', () {
      final LyricInterlude? at3 = lyricInterludeAt(_song(), 3);
      expect(at3, isNotNull);
      expect(at3!.afterLine, -1);
      expect(at3.start, 0);
      expect(at3.end, 8);
      expect(at3.progress, closeTo(0.375, 1e-9));

      expect(lyricInterludeAt(_song(), 6)!.progress, closeTo(0.75, 1e-9));
    });

    test('前奏超过一分钟不显示（多半是时间轴录错了）', () {
      final List<LyricLine> longIntro = <LyricLine>[
        _line(start: 61000, end: 65000, text: '第一句'),
      ];
      expect(lyricInterludeAt(longIntro, 10), isNull);
    });

    test('空白从最后一个字唱完算起（endMs 首尾相接，不能拿它算）', () {
      // 第三句 16.0 开口、16.2 收声，下一句 25.9 才起
      final LyricInterlude? at20 = lyricInterludeAt(_song(), 20);
      expect(at20, isNotNull);
      expect(at20!.afterLine, 2);
      expect(at20.start, closeTo(16.2, 1e-9));
      expect(at20.end, closeTo(25.9, 1e-9));
      expect(at20.progress, closeTo((20 - 16.2) / 9.7, 1e-9));
    });

    test('最后一个字还没唱完不显示', () {
      expect(lyricInterludeAt(_song(), 16.1), isNull);
    });

    test('空白短于 4 秒直接静着，不冒点', () {
      final List<LyricLine> tight = <LyricLine>[
        _line(start: 0, end: 2000, text: 'A', sungEnd: 1000),
        _line(start: 2000, end: 4000, text: 'B', sungEnd: 2500),
        _line(start: 4000, end: 6000, text: 'C', sungEnd: 5000),
      ];
      expect(lyricInterludeAt(tight, 3.0), isNull);
    });

    test('整段空白都保持显示（什么时候收起由界面按剩余时间决定）', () {
      final LyricInterlude? late = lyricInterludeAt(_song(), 25.5);
      expect(late, isNotNull, reason: '下一句还没开口');
      expect(late!.progress, greaterThan(0.8));
      // 下一句开了口就不算这段空白了
      expect(lyricInterludeAt(_song(), 26.2), isNull);
    });

    test('没有逐字轴的行不显示（分不清还在唱还是唱完了）', () {
      final List<LyricLine> plain = <LyricLine>[
        _line(start: 0, end: 10000, text: '第一句'),
        _line(start: 10000, end: 20000, text: '第二句'),
      ];
      expect(
        lyricInterludeAt(plain, 5),
        isNull,
        reason: 'endMs 就是下一句起点，没有逐字轴就没有真实的收声时刻',
      );
    });

    test('逐字高亮收到最后一个字就停，不吃后面的空白', () {
      // 第三句 16.0 开口、最后一个字 16.2 起，下一句 25.9 才来
      final LyricLine line = _song()[2];
      final int endMs = lineSungEndMs(line);
      expect(endMs, greaterThan(16200), reason: '最后一个字还要有个名目时长');
      expect(endMs, lessThan(25900), reason: '不能一路吃到下一句开口');
      expect(endMs - 16200, lessThanOrEqualTo(600), reason: '名目时长要收着');
      // 而在 20 秒时这一行早该收满，间奏期间不该还有字在跑
      expect(20000, greaterThan(endMs));
    });

    test('行末只有时间的空标签不算收声时刻', () {
      final LyricLine withMarker = LyricLine(
        timeMs: 16000,
        endMs: 25900,
        text: '第三句',
        words: const <LyricWord>[
          LyricWord(timeMs: 16000, text: '第'),
          LyricWord(timeMs: 16200, text: '三'),
          // LRC 行末常见的 `[00:25.90]`：只有时间没有字
          LyricWord(timeMs: 25900, text: ''),
        ],
        translation: '',
      );
      expect(lineSungEnd(withMarker), closeTo(16.2, 1e-9));
      expect(lineSungEndMs(withMarker), lessThan(25900));
    });

    test('间奏时整行已经填满：逐字不再跟着空白继续走', () {
      const List<List<Rect>> boxes = <List<Rect>>[
        <Rect>[Rect.fromLTWH(0, 0, 10, 10)],
        <Rect>[Rect.fromLTWH(10, 0, 10, 10)],
      ];
      const List<int> times = <int>[16000, 16200];
      final Path at20 = karaokeFillPath(
        boxes: boxes,
        times: times,
        lineEndMs: lineSungEndMs(_song()[2]),
        positionMs: 20000,
        from: 0,
        to: times.length,
      );
      expect(at20.getBounds().width, closeTo(20, 0.01), reason: '两个字都该填满');
      // 反证：拿 endMs（下一句起点）当收声的话，这个字只有一半亮
      final Path wrong = karaokeFillPath(
        boxes: boxes,
        times: times,
        lineEndMs: 25900,
        positionMs: 20000,
        from: 0,
        to: times.length,
      );
      expect(wrong.getBounds().width, lessThan(20), reason: '这就是之前看到的现象');
    });

    test('最后一句之后不算间奏', () {
      expect(lyricInterludeAt(_song(), 60), isNull);
    });

    test('没有歌词不显示', () {
      expect(lyricInterludeAt(const <LyricLine>[], 3), isNull);
    });

    test('相等性按四个字段比较（notifier 才不会白通知）', () {
      final LyricInterlude a = lyricInterludeAt(_song(), 20)!;
      final LyricInterlude b = lyricInterludeAt(_song(), 20)!;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(lyricInterludeAt(_song(), 21)));
    });
  });

  group('LyricsView 的间奏行', () {
    final Finder dots = find.byKey(const ValueKey<String>('lyric-interlude'));
    final Finder row = find.byKey(
      const ValueKey<String>('lyric-interlude-row-2'),
    );

    Future<void> pumpView(
      WidgetTester tester,
      ValueNotifier<double> position,
      ValueNotifier<bool> playing, {
      LyricAlignment alignment = LyricAlignment.center,
      List<LyricLine>? lines,
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
              lines: lines ?? _song(),
              position: position,
              playing: playing,
              alignment: alignment,
              onSeek: (double _) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('左对齐与右对齐时，三个点和正文的左右边齐平', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(20);
      addTearDown(position.dispose);
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(playing.dispose);

      await pumpView(tester, position, playing, alignment: LyricAlignment.left);
      await tester.pump(const Duration(milliseconds: 600));
      final Rect leftDots = tester.getRect(dots);
      final Rect leftText = tester.getRect(find.text('第四句'));
      expect(
        leftDots.left,
        closeTo(leftText.left, 0.5),
        reason: '左对齐时第一个点的左缘要压在正文左缘上',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpView(
        tester,
        position,
        playing,
        alignment: LyricAlignment.right,
      );
      await tester.pump(const Duration(milliseconds: 600));
      final Rect rightDots = tester.getRect(dots);
      final Rect rightText = tester.getRect(find.text('第四句'));
      expect(
        rightDots.right,
        closeTo(rightText.right, 0.5),
        reason: '右对齐时最后一个点的右缘要压在正文右缘上',
      );
    });

    testWidgets('长空白里长出占一行的三个点，把下一句推下去；唱起来再收回原位', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(16.1);
      addTearDown(position.dispose);
      // 暂停着（不呼吸）：只验「占位 / 让位」，呼吸那套留给真机看
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(playing.dispose);

      // 第四句故意不给逐字轴：它变成当前行后仍走普通 Text，能用 find.text 量位置
      // （逐字行是 CustomPaint 画的，找不到 Text）
      final List<LyricLine> song = <LyricLine>[
        ..._song().sublist(0, 3),
        _line(start: 25900, end: 30000, text: '第四句'),
      ];
      await pumpView(tester, position, playing, lines: song);
      // 最后一个字还没唱完：不占位
      expect(dots, findsNothing);
      final double nextLineY = tester.getTopLeft(find.text('第四句')).dy;

      // 走进空白：长出一行，下一句被推下去一行
      position.value = 20;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(row, findsOneWidget);
      expect(dots, findsOneWidget);
      final double pushedY = tester.getTopLeft(find.text('第四句')).dy;
      expect(
        pushedY - nextLineY,
        inInclusiveRange(20, 120),
        reason: '推下去的距离应该约等于一行歌词的高度',
      );

      // 空白快到头了也不能提前收：收起必须和「下一句进门」是同一段动画
      position.value = 25.4;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(row, findsOneWidget, reason: '还没到下一句开口，占位不能先收');
      expect(dots, findsOneWidget);

      // 下一句开口：收行与换行同时起步，整列一路往上，只该有一次排列
      position.value = 26.2;
      await tester.pump();
      final List<double> ys = <double>[tester.getTopLeft(find.text('第四句')).dy];
      for (int i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
        ys.add(tester.getTopLeft(find.text('第四句')).dy);
      }
      for (int i = 1; i < ys.length; i += 1) {
        expect(
          ys[i],
          lessThanOrEqualTo(ys[i - 1] + 0.01),
          reason: '换行只能一路往上：先被顶上来一次、再跳一次就是两次排列',
        );
      }
      expect(row, findsNothing);
      expect(dots, findsNothing);
      // 下一句停在对齐线上（默认 revealAlignment = 0.5）
      expect(
        tester.getCenter(find.text('第四句')).dy,
        closeTo(tester.getSize(find.byType(LyricsView)).height / 2, 24),
        reason: '收完要正好落在对齐线上，不能留下偏移',
      );
    });

    testWidgets('前奏也占一行：第一行被推下去', (WidgetTester tester) async {
      final ValueNotifier<double> position = ValueNotifier<double>(3);
      addTearDown(position.dispose);
      final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
      addTearDown(playing.dispose);

      await pumpView(tester, position, playing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(dots, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('lyric-interlude-row--1')),
        findsOneWidget,
      );

      // 第一句一开口，前奏那行收回去
      position.value = 8.5;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(dots, findsNothing);
    });
  });
}

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/audio/audio_quality.dart';
import 'package:lamp_player/src/features/library/widgets/quality_ring.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

/// 两首 HR（24bit/96k）、一首 SQ（16bit/44.1k）、一首 HQ（mp3 320k）、一首其他
List<Track> mixedQualityTracks() => <Track>[
  sampleTrack(title: '甲', bitDepth: 24, sampleRate: 96000),
  sampleTrack(title: '乙', bitDepth: 24, sampleRate: 96000),
  sampleTrack(title: '丙', bitDepth: 16, sampleRate: 44100),
  sampleTrack(title: '丁', path: '/music/丁.mp3', audioBitrate: 320),
  sampleTrack(title: '戊', path: '/music/戊.mp3', audioBitrate: 96),
];

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// 环上某个角度（0° 在 12 点、顺时针）上、半径 [radius] 处的落点
Offset pointAt(Rect rect, double degrees, double radius) {
  final double rad = (degrees - 90) * math.pi / 180;
  return Offset(
    rect.center.dx + radius * math.cos(rad),
    rect.center.dy + radius * math.sin(rad),
  );
}

void main() {
  group('QualityRing', () {
    testWidgets('点 3 点方向命中 HR 扇区', (WidgetTester tester) async {
      final List<AudioQuality> taps = <AudioQuality>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: QualityRing(
              breakdown: QualityBreakdown.of(mixedQualityTracks()),
              onSelect: taps.add,
              size: 200,
            ),
          ),
        ),
      );

      final Rect rect = tester.getRect(find.byType(QualityRing));
      // 从 12 点开始顺时针铺：HR 占前 2/5（144°），3 点方向（90°）落在里面
      await tester.tapAt(pointAt(rect, 90, rect.width * 0.4));
      await tester.pump();

      expect(taps, <AudioQuality>[AudioQuality.hiRes]);
    });

    testWidgets('点 7 点半方向命中 SQ 扇区', (WidgetTester tester) async {
      final List<AudioQuality> taps = <AudioQuality>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: QualityRing(
              breakdown: QualityBreakdown.of(mixedQualityTracks()),
              onSelect: taps.add,
              size: 200,
            ),
          ),
        ),
      );

      final Rect rect = tester.getRect(find.byType(QualityRing));
      // HR 144° → SQ 144°~216°，取 180°（正下方）
      await tester.tapAt(pointAt(rect, 180, rect.width * 0.4));
      await tester.pump();

      expect(taps, <AudioQuality>[AudioQuality.standard]);
    });

    testWidgets('空库点不动', (WidgetTester tester) async {
      final List<AudioQuality> taps = <AudioQuality>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: QualityRing(
              breakdown: QualityBreakdown.of(const <Track>[]),
              onSelect: taps.add,
              size: 200,
            ),
          ),
        ),
      );
      await tester.tapAt(tester.getCenter(find.byType(QualityRing)));
      await tester.pump();
      expect(taps, isEmpty);
    });

    testWidgets('中心读数跟着选中档走', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: QualityRing(
              breakdown: QualityBreakdown.of(mixedQualityTracks()),
              selected: AudioQuality.high,
              size: 200,
            ),
          ),
        ),
      );
      // 选中 HQ：1 首 / 20.0%
      expect(find.text('1'), findsOneWidget);
      expect(find.text('20.0%'), findsOneWidget);
    });

    // 曾经的 bug：扫过的角度也减了 90°，四档合起来只画了半圈，剩下半圈空白
    testWidgets('四档各占自己的角度，四段颜色互不相同', (WidgetTester tester) async {
      final QualityBreakdown breakdown = QualityBreakdown.of(
        mixedQualityTracks(),
      );
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: QualityRing(breakdown: breakdown, size: 200),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final RenderRepaintBoundary boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // 四档每档的中点角度：HR 2/5=144°、其余各 72°
      const List<double> angles = <double>[72, 180, 252, 324];
      final List<String> colors = <String>[];
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 1);
        final ByteData raw = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final Uint8List px = raw.buffer.asUint8List();
        final int w = image.width;
        final Offset center = Offset(w / 2, image.height / 2);
        for (final double deg in angles) {
          final double rad = (deg - 90) * math.pi / 180;
          final int x = (center.dx + math.cos(rad) * 81).round();
          final int y = (center.dy + math.sin(rad) * 81).round();
          final int i = (y * w + x) * 4;
          colors.add('${px[i]},${px[i + 1]},${px[i + 2]},${px[i + 3]}');
        }
      });

      for (final String color in colors) {
        expect(
          color.endsWith(',0'),
          isFalse,
          reason: '每个角度都该被画上颜色，实际采样 $colors',
        );
      }
      expect(colors.toSet(), hasLength(4), reason: '四档要能一眼分出来，实际采样 $colors');
    });

    testWidgets('拖动可以把环转起来，转了之后点击与配色都跟着转', (WidgetTester tester) async {
      final List<AudioQuality> taps = <AudioQuality>[];
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: QualityRing(
                breakdown: QualityBreakdown.of(mixedQualityTracks()),
                onSelect: taps.add,
                size: 200,
              ),
            ),
          ),
        ),
      );

      final Rect rect = tester.getRect(find.byType(QualityRing));

      Future<String> sampleAt90() async {
        final RenderRepaintBoundary boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final String color = (await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1);
          final ByteData raw = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final Uint8List px = raw.buffer.asUint8List();
          final int w = image.width;
          final int x = (w / 2 + 80).round();
          final int y = (image.height / 2).round();
          final int i = (y * w + x) * 4;
          return '${px[i]},${px[i + 1]},${px[i + 2]}';
        }))!;
        return color;
      }

      final String before = await sampleAt90();
      await tester.tapAt(pointAt(rect, 90, rect.width * 0.4));
      await tester.pump();
      expect(taps, <AudioQuality>[AudioQuality.hiRes], reason: '转之前 3 点是 HR');

      // 抓住环沿圆弧拖：从 3 点转到 330°（越过起点的那段被滑动阈值吃掉），
      // 最后一步只挪 2°/200ms，速度低于阈值，松手不会带惯性，断言才稳定
      const double radius = 80;
      final TestGesture gesture = await tester.startGesture(
        pointAt(rect, 90, radius),
      );
      await gesture.moveTo(
        pointAt(rect, 150, radius),
        timeStamp: const Duration(milliseconds: 20),
      );
      await tester.pump();
      await gesture.moveTo(
        pointAt(rect, 240, radius),
        timeStamp: const Duration(milliseconds: 120),
      );
      await tester.pump();
      await gesture.moveTo(
        pointAt(rect, 330, radius),
        timeStamp: const Duration(milliseconds: 220),
      );
      await tester.pump();
      await gesture.moveTo(
        pointAt(rect, 332, radius),
        timeStamp: const Duration(milliseconds: 420),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final String after = await sampleAt90();
      expect(after, isNot(before), reason: '画出来的扇区要跟着转');

      taps.clear();
      await tester.tapAt(pointAt(rect, 90, rect.width * 0.4));
      await tester.pump();
      // 转了约 180°：3 点位置应是原来的 9 点方向，落在 HQ（216°~288°）
      expect(taps, <AudioQuality>[AudioQuality.high], reason: '命中要按转过的角度算');
    });
  });

  group('点扇区打开音质子界面', () {
    testWidgets('点图例进入这一档的子界面，列表只剩这一档', (WidgetTester tester) async {
      await pumpLibrary(tester, tracks: mixedQualityTracks());
      await openLibrarySettings(tester);

      final Finder hqRow = find.textContaining('HQ · ');
      expect(hqRow, findsOneWidget);
      await tester.tap(hqRow);
      await tester.pumpAndSettle();

      // 不再切到音乐分区、也不再挂筛选胶囊
      expect(
        find.byKey(const ValueKey<String>('quality-filter-chip')),
        findsNothing,
      );
      expect(find.text('HQ · 有损高码率'), findsOneWidget);
      expect(find.text('1 首 · 占全库 20.0%'), findsOneWidget);
      // HQ 只有「丁」：其余四首不该出现
      expect(find.text('丁'), findsOneWidget);
      expect(find.text('甲'), findsNothing);
    });

    testWidgets('返回按钮回到音乐库首页', (WidgetTester tester) async {
      await pumpLibrary(tester, tracks: mixedQualityTracks());
      await openLibrarySettings(tester);
      await tester.tap(find.textContaining('HQ · '));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('quality-detail-back')),
      );
      await tester.pumpAndSettle();

      // 首页的环形图图例里也有「HQ · 有损高码率」，所以按返回按钮判断子页已关
      expect(
        find.byKey(const ValueKey<String>('quality-detail-back')),
        findsNothing,
      );
      expect(find.text('音乐目录'), findsOneWidget, reason: '回到音乐库首页');
    });

    testWidgets('Esc 从音质子界面退回音乐库首页', (WidgetTester tester) async {
      await pumpLibrary(tester, tracks: mixedQualityTracks());
      await openLibrarySettings(tester);
      await tester.tap(find.textContaining('HR · '));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('quality-detail-back')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('quality-detail-back')),
        findsNothing,
      );
      expect(find.text('音乐目录'), findsOneWidget);
    });

    testWidgets('子界面里搜索框提示是「搜索音乐」，输入只筛这一档', (WidgetTester tester) async {
      await pumpLibrary(tester, tracks: mixedQualityTracks());
      await openLibrarySettings(tester);
      await tester.tap(find.textContaining('HR · '));
      await tester.pumpAndSettle();

      expect(find.text('搜索音乐'), findsOneWidget);
      expect(find.text('搜索目录或隐藏歌曲'), findsNothing);

      await _search(tester, '甲');
      expect(find.text('找到 1 首'), findsOneWidget);
      // 「甲」在搜索框里也有一份（EditableText），所以只断言另一首被筛掉
      expect(find.text('乙'), findsNothing);
    });

    testWidgets('子界面里点播放全部只放这一档', (WidgetTester tester) async {
      final FakePlaybackService playback = FakePlaybackService(
        isAvailable: true,
        durationSecs: 180,
      );
      await pumpLibrary(
        tester,
        tracks: mixedQualityTracks(),
        playback: playback,
      );
      await openLibrarySettings(tester);
      await tester.tap(find.textContaining('HR · '));
      await tester.pumpAndSettle();

      await tester.tap(find.text('播放全部'));
      await tester.pumpAndSettle();

      // 播放全部 = 以这一档为队列、从第一首起播，只调一次 play
      expect(playback.playedPaths, <String>['/music/甲.mp3']);
      expect(find.text('2 首 · 占全库 40.0%'), findsOneWidget);
    });
  });
}

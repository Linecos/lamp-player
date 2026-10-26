import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/track_list_view.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

Future<void> _pump(WidgetTester tester, {double width = 1000}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: TrackListView(
          tracks: <Track>[
            sampleTrack(
              title: '夜航',
              artist: '林间电台',
              album: '夜之专辑',
              durationSecs: 185,
            ),
          ],
          onPlay: (Track _) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('列头加粗，列与列之间留 16px', (WidgetTester tester) async {
    await _pump(tester);

    final Text header = tester.widget<Text>(find.text('标题'));
    expect(header.style?.fontWeight, FontWeight.w600);

    double gap(String left, String right) =>
        tester.getRect(find.text(right)).left -
        tester.getRect(find.text(left)).right;

    expect(gap('标题', '艺术家'), 16);
    expect(gap('艺术家', '专辑'), 16);
    expect(gap('专辑', '时长'), 16);
  });

  testWidgets('时长与序号同档 13，且用等宽数字', (WidgetTester tester) async {
    await _pump(tester);

    final Text duration = tester.widget<Text>(find.text('03:05'));
    expect(duration.style?.fontSize, 13);
    expect(
      duration.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );

    final Text index = tester.widget<Text>(find.text('1'));
    expect(index.style?.fontSize, 13);
  });

  testWidgets('窄容器收起专辑列时不留多余间距', (WidgetTester tester) async {
    await _pump(tester, width: 800);

    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

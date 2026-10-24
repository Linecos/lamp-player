import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/now_playing_page.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

NowPlayingData _data({
  Track? track,
  bool isPlaying = true,
  double position = 0,
  double duration = 200,
}) {
  return NowPlayingData(
    track: track ?? sampleTrack(title: '夜航', artist: '林间电台', album: '夜之专辑'),
    isPlaying: isPlaying,
    position: position,
    duration: duration,
    isAvailable: true,
  );
}

TrackLyrics _timed() => const TrackLyrics(
  lines: <LyricLine>[
    LyricLine(timeMs: 1000, text: '第一行'),
    LyricLine(timeMs: 5000, text: '第二行'),
    LyricLine(timeMs: 9000, text: '第三行'),
  ],
  plain: '',
  source: 'sidecar',
);

Future<ValueNotifier<NowPlayingData>> _pump(
  WidgetTester tester, {
  required NowPlayingData data,
  TrackLyrics? lyrics,
  ValueChanged<double>? onSeek,
  VoidCallback? onTogglePlay,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final ValueNotifier<NowPlayingData> notifier = ValueNotifier<NowPlayingData>(
    data,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: NowPlayingPage(
        data: notifier,
        onTogglePlay: () async => onTogglePlay?.call(),
        onPrevious: () async {},
        onNext: () async {},
        onSeek: (double seconds) async => onSeek?.call(seconds),
        lyricsLoader: (String path) async =>
            lyrics ??
            const TrackLyrics(lines: <LyricLine>[], plain: '', source: 'none'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  testWidgets('展示曲目信息与无歌词提示', (WidgetTester tester) async {
    await _pump(tester, data: _data());

    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('林间电台'), findsOneWidget);
    expect(find.text('夜之专辑'), findsOneWidget);
    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.text('把同名 .lrc 放到歌曲旁边即可显示'), findsOneWidget);
  });

  testWidgets('有时间轴时高亮当前行，点歌词可跳转', (WidgetTester tester) async {
    final List<double> seeks = <double>[];
    final ValueNotifier<NowPlayingData> notifier = await _pump(
      tester,
      data: _data(position: 6),
      lyrics: _timed(),
      onSeek: seeks.add,
    );

    expect(find.text('第一行'), findsOneWidget);
    final Text second = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('lyric-1')),
        matching: find.byType(Text),
      ),
    );
    expect(second.style?.fontWeight, FontWeight.w600, reason: '6 秒时应高亮第二行');

    final Text first = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('lyric-0')),
        matching: find.byType(Text),
      ),
    );
    expect(first.style?.fontWeight, FontWeight.w400);

    await tester.tap(find.byKey(const ValueKey<String>('lyric-2')));
    await tester.pump();
    expect(seeks.single, closeTo(9.0, 0.001));

    // 进度推进到第三行后高亮跟随
    notifier.value = _data(position: 10);
    await tester.pumpAndSettle();
    final Text third = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('lyric-2')),
        matching: find.byType(Text),
      ),
    );
    expect(third.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('无时间轴的内嵌歌词按纯文本展示', (WidgetTester tester) async {
    await _pump(
      tester,
      data: _data(),
      lyrics: const TrackLyrics(
        lines: <LyricLine>[],
        plain: '第一段\n第二段',
        source: 'embedded',
      ),
    );

    expect(find.text('暂无歌词'), findsNothing);
    expect(find.text('第一段\n第二段'), findsOneWidget);
  });

  testWidgets('播放按钮反映状态并回调', (WidgetTester tester) async {
    int toggles = 0;
    await _pump(
      tester,
      data: _data(isPlaying: true),
      onTogglePlay: () => toggles += 1,
    );

    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '播放中应显示暂停图标');
    await tester.tap(find.byKey(const ValueKey<String>('now-playing-toggle')));
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('没有曲目时展示空态且控制按钮禁用', (WidgetTester tester) async {
    await _pump(tester, data: const NowPlayingData());

    expect(find.text('还没有在播放的曲目'), findsOneWidget);
    final IconButton toggle = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('now-playing-toggle')),
    );
    expect(toggle.onPressed, isNull);
  });
}

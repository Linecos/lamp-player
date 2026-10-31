@Tags(<String>['golden'])
library;

// 用 golden 锁住「播放条 + 正在播放页」的布局：这两个界面刚重排过，
// 靠断言数字容易漏掉整块错位，像素对比更直接。
//
// 只在本地跑（CI 用 `flutter test --exclude-tags golden`）：不同机器上的
// 字体回退与抗锯齿会让像素有细微差别，放进 CI 只会变成噪音。
// 改了这两个界面并确认无误后：
//     flutter test --update-goldens test/golden

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/window_controls.dart';
import 'package:lamp_player/src/features/player/now_playing_page.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../support/fake_library.dart';

NowPlayingData _data() => NowPlayingData(
  track: sampleTrack(title: '夜航', artist: '林间电台', album: '夜之专辑'),
  isPlaying: true,
  position: 42,
  duration: 214,
  isAvailable: true,
  volume: 0.7,
  repeat: LoopMode.all,
  shuffle: false,
);

/// 固定的一帧频谱：golden 不能依赖真实音频。
///
/// 形状按真实音乐走——低频整体更强、高频更弱，但每一段各自起伏，
/// 不是单调下滑的斜坡；用等幅锯齿又会变成一串重复的小丘，
/// 两种都对不上真实观感。
List<double> _bands() => <double>[
  for (int i = 0; i < 24; i += 1)
    (0.95 - i * 0.02) * (0.45 + 0.55 * ((i * 61) % 17) / 16),
];

const TrackLyrics _lyrics = TrackLyrics(
  lines: <LyricLine>[
    LyricLine(
      timeMs: 0,
      endMs: 5000,
      text: '第一行',
      words: <LyricWord>[],
      translation: '',
    ),
    LyricLine(
      timeMs: 5000,
      endMs: 9000,
      text: '第二行',
      words: <LyricWord>[],
      translation: '译文',
    ),
    LyricLine(
      timeMs: 9000,
      endMs: 200000,
      text: '第三行',
      words: <LyricWord>[],
      translation: '',
    ),
  ],
  plain: '',
  source: 'sidecar',
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

/// 播放页自己画窗口按钮，golden 里也要把它们带上，否则截图和真实界面差一截
class _FakeWindowControls implements WindowControls {
  const _FakeWindowControls();

  @override
  Stream<bool> get maximizeChanges => const Stream<bool>.empty();

  @override
  Future<bool> isMaximized() async => false;

  @override
  Future<void> minimize() async {}

  @override
  Future<bool> toggleMaximize() async => false;

  @override
  Future<void> close() async {}

  @override
  Future<void> startDragging() async {}
}

Widget _nowPlaying(ValueListenable<List<double>> spectrum) {
  final ValueNotifier<NowPlayingData> data = ValueNotifier<NowPlayingData>(
    _data(),
  );
  addTearDown(data.dispose);
  return NowPlayingPage(
    data: data,
    onTogglePlay: () async {},
    onPrevious: () async {},
    onNext: () async {},
    onSeek: (double seconds) async {},
    onVolumeChanged: (_) {},
    onToggleMute: () {},
    onShowQueue: () {},
    onCyclePlayMode: () {},
    spectrum: spectrum,
    windowControls: const _FakeWindowControls(),
    lyricsLoader: (String path) async => _lyrics,
  );
}

void main() {
  late ValueNotifier<List<double>> spectrum;

  setUp(() => spectrum = ValueNotifier<List<double>>(_bands()));
  tearDown(() => spectrum.dispose());

  for (final (String name, Size size) in <(String, Size)>[
    ('now_playing_1280x900', Size(1280, 900)),
    ('now_playing_900x560', Size(900, 560)),
    ('now_playing_700x900', Size(700, 900)),
  ]) {
    testWidgets('正在播放页 $name', (WidgetTester tester) async {
      await _pump(tester, _nowPlaying(spectrum), size: size);
      await expectLater(
        find.byType(NowPlayingPage),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }

  for (final (String name, double width) in <(String, double)>[
    ('player_bar_1280', 1280),
    ('player_bar_900', 900),
  ]) {
    testWidgets('播放条 $name', (WidgetTester tester) async {
      await _pump(
        tester,
        Center(
          child: SizedBox(
            width: width,
            child: PlayerBar(
              track: _data().track,
              isPlaying: true,
              isAvailable: true,
              position: 42,
              duration: 214,
              volume: 0.7,
              repeat: LoopMode.all,
              spectrum: spectrum,
              lyricsLoader: (String path) async => _lyrics,
              onPlayPause: () {},
              onPrevious: () {},
              onNext: () {},
              onSeekStart: (_) {},
              onSeekChanged: (_) {},
              onSeekEnd: (_) {},
              onVolumeChanged: (_) {},
              onToggleMute: () {},
              onShowQueue: () {},
              onCyclePlayMode: () {},
              onOpenNowPlaying: () {},
            ),
          ),
        ),
        size: Size(width, 200),
      );
      await expectLater(
        find.byType(PlayerBar),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}

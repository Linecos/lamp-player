import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

const ValueKey<String> _progressKey = ValueKey<String>('player-progress');
const ValueKey<String> _volumeKey = ValueKey<String>('player-volume');

Slider _sliderOf(WidgetTester tester, Key key) {
  return tester.widget<Slider>(
    find.descendant(of: find.byKey(key), matching: find.byType(Slider)),
  );
}

Future<void> _pumpBar(
  WidgetTester tester, {
  bool isAvailable = true,
  bool isPlaying = false,
  bool canSeek = true,
  Track? track,
  double position = 0,
  double duration = 200,
  double volume = 1,
  ValueChanged<double>? onSeekStart,
  ValueChanged<double>? onSeekChanged,
  ValueChanged<double>? onSeekEnd,
  ValueChanged<double>? onVolumeChanged,
  VoidCallback? onToggleMute,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onShowQueue,
  VoidCallback? onToggleRepeat,
  VoidCallback? onToggleShuffle,
  LoopMode repeat = LoopMode.off,
  bool shuffle = false,
  VoidCallback? onOpenNowPlaying,
}) async {
  tester.view.physicalSize = const Size(1280, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: PlayerBar(
            track: track,
            isPlaying: isPlaying,
            isAvailable: isAvailable,
            canSeek: canSeek,
            position: position,
            duration: duration,
            volume: volume,
            onSeekStart: onSeekStart,
            onSeekChanged: onSeekChanged,
            onSeekEnd: onSeekEnd,
            onVolumeChanged: onVolumeChanged,
            onToggleMute: onToggleMute,
            onPrevious: onPrevious,
            onNext: onNext,
            onShowQueue: onShowQueue,
            onToggleRepeat: onToggleRepeat,
            onToggleShuffle: onToggleShuffle,
            repeat: repeat,
            shuffle: shuffle,
            onOpenNowPlaying: onOpenNowPlaying,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('拖动进度条：开始、预览、松手各回调一次', (WidgetTester tester) async {
    final List<double> starts = <double>[];
    final List<double> previews = <double>[];
    final List<double> ends = <double>[];

    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      duration: 200,
      onSeekStart: starts.add,
      onSeekChanged: previews.add,
      onSeekEnd: ends.add,
    );

    await tester.drag(find.byKey(_progressKey), const Offset(140, 0));
    await tester.pump();

    expect(starts, hasLength(1));
    expect(previews, isNotEmpty);
    expect(ends, hasLength(1));
    expect(ends.single, greaterThan(0));
    expect(ends.single, lessThanOrEqualTo(200));
  });

  testWidgets('拖动过程中时间标签跟随预览位置', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      position: 0,
      duration: 200,
    );

    expect(find.text('00:00'), findsOneWidget);

    // 父级把预览位置回灌给 position 后，标签应立刻更新
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      position: 100,
      duration: 200,
    );

    expect(find.text('01:40'), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
  });

  testWidgets('音量滑块变化会回调 0~1 的值', (WidgetTester tester) async {
    final List<double> volumes = <double>[];

    await _pumpBar(tester, volume: 0.5, onVolumeChanged: volumes.add);

    await tester.drag(find.byKey(_volumeKey), const Offset(30, 0));
    await tester.pump();

    expect(volumes, isNotEmpty);
    expect(volumes.last, inInclusiveRange(0.0, 1.0));
    expect(volumes.last, greaterThan(0.5));
  });

  testWidgets('引擎不可用时进度与音量滑块都禁用', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      isAvailable: false,
      track: sampleTrack(title: '夜航'),
      onSeekEnd: (_) {},
      onVolumeChanged: (_) {},
    );

    expect(_sliderOf(tester, _progressKey).onChanged, isNull);
    expect(_sliderOf(tester, _volumeKey).onChanged, isNull);
  });

  testWidgets('没有当前曲目时进度滑块禁用但音量可调', (WidgetTester tester) async {
    await _pumpBar(tester, onVolumeChanged: (_) {});

    expect(_sliderOf(tester, _progressKey).onChanged, isNull);
    expect(_sliderOf(tester, _volumeKey).onChanged, isNotNull);
  });

  testWidgets('音量图标随音量变化，点击触发静音回调', (WidgetTester tester) async {
    await _pumpBar(tester, volume: 0);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await _pumpBar(tester, volume: 0.2);
    expect(find.byIcon(Icons.volume_down), findsOneWidget);

    int toggles = 0;
    await _pumpBar(tester, volume: 0.9, onToggleMute: () => toggles += 1);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('静音状态下的按钮提示为取消静音', (WidgetTester tester) async {
    await _pumpBar(tester, volume: 0, onToggleMute: () {});

    expect(find.byTooltip('取消静音'), findsOneWidget);
    expect(find.byTooltip('静音'), findsNothing);
  });

  testWidgets('停止态（canSeek=false）禁用进度拖动', (WidgetTester tester) async {
    final List<double> ends = <double>[];
    await _pumpBar(
      tester,
      isPlaying: false,
      canSeek: false,
      track: sampleTrack(title: '夜航'),
      position: 30,
      duration: 180,
      onSeekEnd: ends.add,
    );

    expect(_sliderOf(tester, _progressKey).onChanged, isNull);
    await tester.drag(find.byKey(_progressKey), const Offset(120, 0));
    await tester.pump();
    expect(ends, isEmpty, reason: '停止态不应触发 seek');
  });

  testWidgets('上一首 / 下一首 / 队列 / 随机循环按钮转发回调', (WidgetTester tester) async {
    int previous = 0;
    int next = 0;
    int queue = 0;
    int repeat = 0;
    int shuffle = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      repeat: LoopMode.all,
      shuffle: true,
      onPrevious: () => previous += 1,
      onNext: () => next += 1,
      onShowQueue: () => queue += 1,
      onToggleRepeat: () => repeat += 1,
      onToggleShuffle: () => shuffle += 1,
    );

    await tester.tap(find.byTooltip('上一首 (Ctrl+←)'));
    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.tap(find.byTooltip('播放队列'));
    await tester.tap(find.byTooltip('循环播放：列表'));
    await tester.tap(find.byTooltip('关闭随机播放'));
    await tester.pump();

    expect(previous, 1);
    expect(next, 1);
    expect(queue, 1);
    expect(repeat, 1);
    expect(shuffle, 1);
    expect(find.byType(Badge), findsNothing, reason: '队列按钮不再显示数量角标');
  });

  testWidgets('播放条用 AlbumCover 渲染当前曲目封面', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航', coverPath: '/missing/cover.jpg'),
    );

    expect(find.byType(AlbumCover), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget, reason: '文件不存在时回退');
  });

  testWidgets('没有当前曲目时上一首 / 下一首 / 暂停都禁用', (WidgetTester tester) async {
    await _pumpBar(tester, onPrevious: () {}, onNext: () {});

    IconButton buttonWithIcon(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    expect(buttonWithIcon(Icons.skip_previous).onPressed, isNull);
    expect(buttonWithIcon(Icons.skip_next).onPressed, isNull);
    expect(buttonWithIcon(Icons.play_arrow).onPressed, isNull);
  });

  testWidgets('封面可点打开正在播放页，墨水层不被底色遮住', (WidgetTester tester) async {
    int opens = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      onOpenNowPlaying: () => opens += 1,
    );

    final Finder cover = find.byKey(
      const ValueKey<String>('player-bar-open-now-playing'),
    );
    expect(tester.widget<InkWell>(cover).hoverColor, isNotNull);

    final Material surface = tester.widget<Material>(
      find.ancestor(of: cover, matching: find.byType(Material)).first,
    );
    expect(
      surface.type,
      MaterialType.transparency,
      reason: '播放条底色画在 Container 上，需要一个透明 Material 托住墨水',
    );

    await tester.tap(cover);
    await tester.pump();
    expect(opens, 1);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
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
  double width = 1280,
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
  TrackLyricsLoader? lyricsLoader,
}) async {
  tester.view.physicalSize = Size(width, 600);
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
            lyricsLoader: lyricsLoader,
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

  testWidgets('曲名区域也可点打开正在播放页', (WidgetTester tester) async {
    int opens = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      onOpenNowPlaying: () => opens += 1,
    );

    final Finder titleArea = find.byKey(
      const ValueKey<String>('player-bar-open-now-playing-title'),
    );
    expect(tester.widget<InkWell>(titleArea).hoverColor, isNotNull);

    await tester.tap(find.descendant(of: titleArea, matching: find.text('夜航')));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('三键落在播放条中轴上', (WidgetTester tester) async {
    // 宽窗口和最小窗口（900 + 侧栏展开 → 618）都要居中
    for (final double width in <double>[1280, 618]) {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        width: width,
      );

      // 左段与右段等宽，播放键就落在整条播放条的中轴上
      final double center = tester.getCenter(find.byType(PlayerBar)).dx;
      final double play = tester
          .getCenter(find.widgetWithIcon(IconButton, Icons.play_arrow))
          .dx;
      expect(play, closeTo(center, 1), reason: '宽度 $width 下三键偏了');
    }
  });

  testWidgets('窄窗口不挤爆：模式与队列收进菜单、音量只留静音', (WidgetTester tester) async {
    // 900 宽窗口 + 侧栏展开时，播放条可用宽度就是 618
    await _pumpBar(tester, track: sampleTrack(title: '夜航'), width: 618);

    expect(tester.takeException(), isNull, reason: '窄窗口不允许溢出');
    expect(find.byTooltip('播放选项'), findsOneWidget);
    expect(find.byTooltip('随机播放'), findsNothing, reason: '随机 / 循环已收进菜单');
    expect(find.byTooltip('播放队列'), findsNothing, reason: '队列也收进菜单');
    expect(find.byTooltip('静音'), findsOneWidget);
    expect(find.byKey(_volumeKey), findsNothing, reason: '窄窗口音量只留静音按钮');
    // 测试字体每个字符都按字号宽度渲染，时间标签比真实字体宽近一倍，所以只卡
    // 下限；真实窗口（900 + 侧栏展开）下进度条约 97px。
    expect(
      tester.getSize(find.byKey(_progressKey)).width,
      greaterThan(60),
      reason: '进度条在窄窗口也要有可用宽度',
    );
  });

  testWidgets('中等宽度：模式收进菜单但仍保留音量滑块', (WidgetTester tester) async {
    await _pumpBar(tester, track: sampleTrack(title: '夜航'), width: 800);

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('播放选项'), findsOneWidget);
    expect(find.byKey(_volumeKey), findsOneWidget);
  });

  testWidgets('窄窗口下从溢出菜单里仍能切模式与打开队列', (WidgetTester tester) async {
    int shuffles = 0;
    int repeats = 0;
    int queues = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      width: 618,
      onToggleShuffle: () => shuffles += 1,
      onToggleRepeat: () => repeats += 1,
      onShowQueue: () => queues += 1,
    );

    // 点菜单项本身：文字被 ListTile 包着，直接点 Text 会命中测试失败告警
    Finder item(int index) =>
        find.byType(CheckedPopupMenuItem<String>).at(index);

    await tester.tap(find.byTooltip('播放选项'));
    await tester.pumpAndSettle();
    await tester.tap(item(0));
    await tester.pumpAndSettle();
    expect(shuffles, 1);
    expect(repeats, 0);

    await tester.tap(find.byTooltip('播放选项'));
    await tester.pumpAndSettle();
    await tester.tap(item(1));
    await tester.pumpAndSettle();
    expect(repeats, 1);

    await tester.tap(find.byTooltip('播放选项'));
    await tester.pumpAndSettle();
    // CheckedPopupMenuItem 是 PopupMenuItem 的子类，byType 只按精确类型匹配
    await tester.tap(find.byType(PopupMenuItem<String>));
    await tester.pumpAndSettle();
    expect(queues, 1);
  });

  testWidgets('宽窗口下三个模式按钮全部显示', (WidgetTester tester) async {
    await _pumpBar(tester, track: sampleTrack(title: '夜航'));

    expect(find.byTooltip('播放选项'), findsNothing);
    expect(find.byTooltip('随机播放'), findsOneWidget);
    expect(find.byTooltip('循环播放：关'), findsOneWidget);
    expect(find.byTooltip('播放队列'), findsOneWidget);
    expect(tester.getSize(find.byKey(_volumeKey)).width, 120);
    expect(
      tester.getSize(find.byKey(_progressKey)).width,
      greaterThan(120),
      reason: '默认窗口下进度条要够长',
    );
  });

  testWidgets('比窗口下限还窄时也不溢出（兜底）', (WidgetTester tester) async {
    // 真实窗口最小 900（侧栏展开时播放条 618），这里只验证布局算式在更窄的
    // 宽度下也不会让 Row 溢出
    await _pumpBar(tester, track: sampleTrack(title: '夜航'), width: 420);

    expect(tester.takeException(), isNull);
  });

  group('播放条歌词', () {
    // 左段在 1280 窗口约 444、900 + 侧栏展开时约 223：前者放得下歌词，
    // 后者只够曲名
    testWidgets('宽窗口在曲名右侧显示当前歌词行', (WidgetTester tester) async {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        position: 12,
        lyricsLoader: (String path) async =>
            _lyrics(<(int, String)>[(0, '第一句'), (10000, '第二句')]),
      );
      await tester.pump();

      expect(find.byKey(_lyricKey), findsOneWidget);
      expect(find.text('第二句'), findsOneWidget);
      expect(find.text('第一句'), findsNothing, reason: '只显示当前行');
      // 与展开页一致：歌词在曲名右侧那一块里居中
      final Rect area = tester.getRect(find.byKey(_lyricKey));
      final Rect line = tester.getRect(find.text('第二句'));
      expect(area.width, greaterThan(line.width), reason: '歌词区域应比文字宽');
      expect(line.center.dx, closeTo(area.center.dx, 1), reason: '歌词要居中，不能左对齐');
    });

    testWidgets('播放位置推进时切到下一行', (WidgetTester tester) async {
      Future<TrackLyrics> loader(String path) async =>
          _lyrics(<(int, String)>[(0, '第一句'), (10000, '第二句')]);
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        lyricsLoader: loader,
      );
      await tester.pump();
      expect(find.text('第一句'), findsOneWidget);

      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        position: 30,
        lyricsLoader: loader,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('第二句'), findsOneWidget);
      expect(find.text('第一句'), findsNothing, reason: '旧行淡出后应被移除');
    });

    testWidgets('间奏空行沿用上一句，不闪成空白', (WidgetTester tester) async {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        position: 14,
        lyricsLoader: (String path) async =>
            _lyrics(<(int, String)>[(0, '有词的一句'), (10000, '   ')]),
      );
      await tester.pump();

      expect(find.text('有词的一句'), findsOneWidget);
    });

    testWidgets('窄窗口不占位：曲名独占整段', (WidgetTester tester) async {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        width: 618,
        lyricsLoader: (String path) async =>
            _lyrics(<(int, String)>[(0, '第一句')]),
      );
      await tester.pump();

      expect(find.byKey(_lyricKey), findsNothing);
      expect(find.text('第一句'), findsNothing);
    });

    testWidgets('没有歌词时不占位，也不抛异常', (WidgetTester tester) async {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        lyricsLoader: (String path) async =>
            const TrackLyrics(lines: <LyricLine>[], plain: '', source: 'none'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_lyricKey), findsNothing);
    });

    testWidgets('歌词读取失败按没有歌词处理', (WidgetTester tester) async {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        lyricsLoader: (String path) async => throw StateError('读不到'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_lyricKey), findsNothing);
    });

    testWidgets('清空当前曲目后不残留上一首的歌词', (WidgetTester tester) async {
      Future<TrackLyrics> loader(String path) async =>
          _lyrics(<(int, String)>[(0, '第一句')]);
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        lyricsLoader: loader,
      );
      await tester.pump();
      expect(find.byKey(_lyricKey), findsOneWidget);

      // 播放队列清空 / 停止后 track 变 null，歌词不能留在播放条上
      await _pumpBar(tester, lyricsLoader: loader);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(_lyricKey), findsNothing);
      expect(find.text('第一句'), findsNothing);
    });

    testWidgets('切歌重新读歌词，切回来命中缓存', (WidgetTester tester) async {
      final List<String> calls = <String>[];
      Future<TrackLyrics> loader(String path) async {
        calls.add(path);
        return _lyrics(<(int, String)>[
          (0, path.contains('夜航') ? '夜航的词' : '归途的词'),
        ]);
      }

      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        lyricsLoader: loader,
      );
      await tester.pump();
      expect(find.text('夜航的词'), findsOneWidget);

      await _pumpBar(
        tester,
        track: sampleTrack(title: '归途'),
        lyricsLoader: loader,
      );
      await tester.pump();
      expect(find.text('归途的词'), findsOneWidget);
      expect(calls, <String>['/music/夜航.mp3', '/music/归途.mp3']);

      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        lyricsLoader: loader,
      );
      await tester.pump();
      expect(find.text('夜航的词'), findsOneWidget);
      expect(calls, hasLength(2), reason: '第二遍走缓存，不再读文件');
    });
  });
}

const ValueKey<String> _lyricKey = ValueKey<String>('player-bar-lyric');

/// 造一份行级歌词；每行给 1 秒时长，够 `lyricIndexAt` 定位
TrackLyrics _lyrics(List<(int, String)> entries) {
  return TrackLyrics(
    lines: <LyricLine>[
      for (final (int ms, String text) in entries)
        LyricLine(
          timeMs: ms,
          endMs: ms + 1000,
          text: text,
          words: const <LyricWord>[],
          translation: '',
        ),
    ],
    plain: '',
    source: 'sidecar',
  );
}

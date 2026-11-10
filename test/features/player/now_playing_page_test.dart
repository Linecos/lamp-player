import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/formatters/duration.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/common/widgets/marquee_title.dart';
import 'package:lamp_player/src/app/immersive_chrome.dart';
import 'package:lamp_player/src/app/title_bar.dart';
import 'package:lamp_player/src/app/window_controls.dart';
import 'package:lamp_player/src/common/widgets/cover_shape.dart';
import 'package:lamp_player/src/features/player/lyric_alignment.dart';
import 'package:lamp_player/src/features/player/lyrics_view.dart';
import 'package:lamp_player/src/features/player/now_playing_page.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/sleep_timer.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/rust/api/player.dart' as rust;
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

NowPlayingData _data({
  Track? track,
  bool isPlaying = true,
  double position = 0,
  double duration = 200,
  double volume = 1,
  LoopMode repeat = LoopMode.off,
  bool shuffle = false,
  bool desktopLyrics = false,
  bool desktopLyricLocked = false,
}) {
  return NowPlayingData(
    track: track ?? sampleTrack(title: '夜航', artist: '林间电台', album: '夜之专辑'),
    isPlaying: isPlaying,
    position: position,
    duration: duration,
    isAvailable: true,
    volume: volume,
    repeat: repeat,
    shuffle: shuffle,
    desktopLyrics: desktopLyrics,
    desktopLyricLocked: desktopLyricLocked,
  );
}

TrackLyrics _timed() => const TrackLyrics(
  lines: <LyricLine>[
    LyricLine(
      timeMs: 1000,
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
      translation: '',
    ),
    LyricLine(
      timeMs: 9000,
      endMs: 12000,
      text: '第三行',
      words: <LyricWord>[],
      translation: '',
    ),
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
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  ValueChanged<double>? onVolumeChanged,
  VoidCallback? onToggleMute,
  VoidCallback? onShowQueue,
  VoidCallback? onCyclePlayMode,
  ValueListenable<List<rust.PlayerDevice>>? devices,
  ValueListenable<int>? selectedDevice,
  ValueChanged<int>? onSelectDevice,
  VoidCallback? onOpenEqualizer,
  VoidCallback? onToggleDesktopLyrics,
  VoidCallback? onToggleDesktopLyricLock,
  void Function(Track track, String artist)? onOpenArtist,
  ValueChanged<Track>? onOpenAlbum,
  ValueListenable<List<double>>? spectrum,
  WindowControls? windowControls,
  ValueListenable<LyricAlignment>? lyricAlignment,
  VoidCallback? onCycleLyricAlignment,
  ValueListenable<bool>? showTranslation,
  VoidCallback? onToggleTranslation,
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final ValueNotifier<NowPlayingData> notifier = ValueNotifier<NowPlayingData>(
    data,
  );
  // 睡眠定时在真实应用里由曲库页持有；这里跟着页面一起造一个，
  // 到点动作仍走同一个 onTogglePlay，断言不受影响
  final SleepTimer sleepTimer = SleepTimer(
    isPlaying: () => notifier.value.isPlaying,
    position: () => notifier.value.position,
    duration: () => notifier.value.duration,
    pause: () async => onTogglePlay?.call(),
  );
  addTearDown(sleepTimer.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: NowPlayingPage(
        data: notifier,
        onTogglePlay: () async => onTogglePlay?.call(),
        onPrevious: () async => onPrevious?.call(),
        onNext: () async => onNext?.call(),
        onSeek: (double seconds) async => onSeek?.call(seconds),
        onVolumeChanged: onVolumeChanged,
        onToggleMute: onToggleMute,
        onShowQueue: onShowQueue,
        onCyclePlayMode: onCyclePlayMode,
        devices: devices,
        selectedDevice: selectedDevice,
        onSelectDevice: onSelectDevice,
        onOpenEqualizer: onOpenEqualizer,
        onToggleDesktopLyrics: onToggleDesktopLyrics,
        onToggleDesktopLyricLock: onToggleDesktopLyricLock,
        onOpenArtist: onOpenArtist,
        onOpenAlbum: onOpenAlbum,
        spectrum: spectrum,
        windowControls: windowControls,
        lyricAlignment: lyricAlignment,
        onCycleLyricAlignment: onCycleLyricAlignment,
        showTranslation: showTranslation,
        onToggleTranslation: onToggleTranslation,
        sleepTimer: sleepTimer,
        lyricsLoader: (String path) async =>
            lyrics ??
            const TrackLyrics(lines: <LyricLine>[], plain: '', source: 'none'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return notifier;
}

/// 让「沉浸模式」提示走完（停留 1100ms + 淡出 180ms）。
///
/// 不推完的话，测试结束时还挂着定时器，flutter_test 会判失败。
Future<void> _settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('歌名长短不影响封面位置（标题只占一行）', (WidgetTester tester) async {
    final ValueNotifier<NowPlayingData> notifier = await _pump(
      tester,
      data: _data(track: sampleTrack(title: '夜航')),
      size: const Size(1280, 720),
    );

    Finder titleOf(String title) => find.descendant(
      of: find.byType(MarqueeTitle),
      matching: find.text(title),
    );

    // 长标题会画两份文字来接缝，取第一份就够
    expect(
      tester.widget<Text>(titleOf('夜航').first).maxLines,
      1,
      reason: '标题固定一行，多了会换行把封面顶下去',
    );
    final Rect short = tester.getRect(find.byType(AlbumCover).first);

    // 换成长歌名：真实场景就是切歌
    notifier.value = _data(
      track: sampleTrack(title: '这是一首名字特别长的歌曲用来验证换行之后的布局表现究竟如何再多写一些字让它超出去'),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            titleOf('这是一首名字特别长的歌曲用来验证换行之后的布局表现究竟如何再多写一些字让它超出去').first,
          )
          .maxLines,
      1,
    );
    final Rect long = tester.getRect(find.byType(AlbumCover).first);

    expect(
      long.top,
      closeTo(short.top, 0.5),
      reason: '短歌名 / 长歌名的封面必须在同一高度，否则换歌时封面跳一下',
    );
    expect(long.height, closeTo(short.height, 0.5));
  });

  testWidgets('展示曲目信息与无歌词提示', (WidgetTester tester) async {
    await _pump(tester, data: _data());

    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('林间电台'), findsOneWidget);
    expect(find.text('夜之专辑'), findsOneWidget);
    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.text('把同名 .lrc 放到歌曲旁边即可显示'), findsOneWidget);
  });

  testWidgets('曲目信息字号跟着封面一起缩放', (WidgetTester tester) async {
    Future<(double cover, double title, double meta, double gap)> measure(
      Size size,
    ) async {
      await _pump(tester, data: _data(), size: size);
      final AlbumCover cover = tester.widget<AlbumCover>(
        find.byType(AlbumCover),
      );
      return (
        cover.size,
        tester.getSize(find.text('夜航')).height,
        tester.getSize(find.text('林间电台')).height,
        // 信息块底边到封面顶边的那道缝
        tester.getRect(find.byType(AlbumCover)).top -
            tester
                .getRect(find.byKey(const ValueKey<String>('now-playing-info')))
                .bottom,
      );
    }

    final (double bigCover, double bigTitle, double bigMeta, double bigGap) =
        await measure(const Size(1440, 900));
    final (double midCover, double midTitle, double midMeta, double midGap) =
        await measure(const Size(1280, 900));

    expect(midCover, lessThan(bigCover), reason: '窗口变小封面也变小');
    // 文字与封面同比例缩放（而不是固定字号）
    final double coverRatio = midCover / bigCover;
    expect(midTitle / bigTitle, closeTo(coverRatio, 0.06));
    expect(midMeta / bigMeta, closeTo(coverRatio, 0.06));
    // 字与封面之间的间距也跟着缩，否则大窗口里字会像贴在封面上
    expect(bigGap, greaterThan(midGap));
    expect(midGap / bigGap, closeTo(coverRatio, 0.06));

    // 最小窗口：缩放下限兜底，但一定比 1280 时小
    final (_, double smallTitle, double smallMeta, double smallGap) =
        await measure(const Size(900, 560));
    expect(smallTitle, lessThan(midTitle));
    expect(smallMeta, lessThan(midMeta));
    expect(smallGap, lessThan(midGap));
  });

  testWidgets('点歌手 / 专辑分别回调跳转', (WidgetTester tester) async {
    final List<String> artists = <String>[];
    final List<String> albums = <String>[];
    await _pump(
      tester,
      data: _data(),
      onOpenArtist: (Track track, String artist) =>
          artists.add('${track.title}/$artist'),
      onOpenAlbum: (Track track) => albums.add(track.title),
    );

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-artist')));
    await tester.pump();
    expect(artists, <String>['夜航/林间电台']);
    expect(albums, isEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-album')));
    await tester.pump();
    expect(albums, <String>['夜航']);
  });

  testWidgets('单艺术家点歌手直接跳，不弹窗', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await _pump(
      tester,
      data: _data(),
      onOpenArtist: (Track track, String artist) => opened.add(artist),
    );

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-artist')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('artist-picker-dialog')),
      findsNothing,
    );
    expect(opened, <String>['林间电台']);
  });

  testWidgets('多艺术家时点歌手先弹窗选一位，再跳选中的那位', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await _pump(
      tester,
      data: _data(
        track: sampleTrack(
          title: 'Love Me Not',
          artist: 'Bao The Whale/Overspace',
          album: '夜之专辑',
        ),
      ),
      onOpenArtist: (Track track, String artist) => opened.add(artist),
    );

    // 整串照旧显示，让人看得出这里不止一位
    expect(find.text('Bao The Whale/Overspace'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-artist')));
    await tester.pumpAndSettle();

    final Finder dialog = find.byKey(
      const ValueKey<String>('artist-picker-dialog'),
    );
    expect(dialog, findsOneWidget);
    expect(opened, isEmpty, reason: '还没选就不该跳走');

    // 每条都带自己的首字母头像：以前一律是那个人形占位，认不出谁是谁
    expect(
      find.descendant(of: dialog, matching: find.byIcon(Icons.person)),
      findsNothing,
      reason: '不该再是统一的人形占位',
    );
    expect(
      find.descendant(of: dialog, matching: find.text('B')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('O')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('artist-picker-Overspace')),
    );
    await tester.pumpAndSettle();

    expect(opened, <String>['Overspace']);
    expect(
      find.byKey(const ValueKey<String>('artist-picker-dialog')),
      findsNothing,
      reason: '选完要关窗',
    );
  });

  testWidgets('多艺术家弹窗直接关掉时不跳转', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await _pump(
      tester,
      data: _data(
        track: sampleTrack(
          title: 'Love Me Not',
          artist: 'Bao The Whale/Overspace',
        ),
      ),
      onOpenArtist: (Track track, String artist) => opened.add(artist),
    );

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-artist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
  });

  testWidgets('没有专辑标签时只显示歌手，不渲染专辑链接', (WidgetTester tester) async {
    await _pump(
      tester,
      data: _data(
        track: sampleTrack(title: '夜航', artist: '林间电台', album: null),
      ),
      onOpenArtist: (Track track, String artist) {},
      onOpenAlbum: (Track track) {},
    );

    expect(find.text('林间电台'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('now-playing-album')),
      findsNothing,
    );
  });

  testWidgets('底部控制区包含音量、播放模式与队列，封面与文字左对齐', (WidgetTester tester) async {
    int modes = 0;
    int queues = 0;
    double? volume;
    final ValueNotifier<NowPlayingData> notifier = await _pump(
      tester,
      data: _data(volume: 0.5, repeat: LoopMode.all),
      onVolumeChanged: (double value) => volume = value,
      onShowQueue: () => queues += 1,
      onCyclePlayMode: () => modes += 1,
    );

    expect(
      find.byKey(const ValueKey<String>('now-playing-volume')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-queue')),
      findsOneWidget,
    );
    expect(find.byTooltip('播放模式：列表循环'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-mode')));
    await tester.tap(find.byKey(const ValueKey<String>('now-playing-queue')));
    await tester.pump();
    expect(modes, 1);
    expect(queues, 1);

    final Slider slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('now-playing-volume')),
    );
    slider.onChanged!(0.3);
    expect(volume, closeTo(0.3, 0.001));
    expect(notifier.value.volume, 0.5, reason: '数据由上游刷新');

    final Rect cover = tester.getRect(find.byType(AlbumCover));
    final Rect title = tester.getRect(find.text('夜航'));
    expect(cover.left, greaterThan(40), reason: '封面不再贴左');
    expect(title.left, closeTo(cover.left, 1), reason: '文字与封面对齐');
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
    expect(
      second.style?.fontSize,
      22,
      reason: '字号恒定，放大交给外层缩放（改字号会让长句重新折行，换行时整列会跳）',
    );
    expect(second.style?.color?.a, closeTo(0.96, 0.01), reason: '当前行固定白色');

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

  testWidgets('频谱丝带的高度交给歌词做底部淡出', (WidgetTester tester) async {
    final ValueNotifier<List<double>> spectrum = ValueNotifier<List<double>>(
      List<double>.filled(24, 0.6),
    );
    addTearDown(spectrum.dispose);
    await _pump(tester, data: _data(), lyrics: _timed(), spectrum: spectrum);

    final Rect bars = tester.getRect(
      find.byKey(const ValueKey<String>('now-playing-spectrum')),
    );
    final LyricsView view = tester.widget<LyricsView>(find.byType(LyricsView));
    expect(bars.height, 72, reason: '丝带高度是淡出高度的来源');
    expect(
      view.edgeFadeBand,
      bars.height + 6,
      reason: '底部淡出要盖过整条丝带（含贴底的那 6px）',
    );
    expect(
      find.byKey(const ValueKey<String>('lyrics-edge-fade')),
      findsOneWidget,
    );
  });

  testWidgets('没有频谱时不必为丝带留出淡出高度', (WidgetTester tester) async {
    await _pump(tester, data: _data(), lyrics: _timed());
    final LyricsView view = tester.widget<LyricsView>(find.byType(LyricsView));
    expect(view.edgeFadeBand, 0);
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

  testWidgets('传了 onOpenEqualizer 才显示均衡器按钮', (WidgetTester tester) async {
    int opens = 0;
    await _pump(tester, data: _data(), onOpenEqualizer: () => opens += 1);

    final Finder button = find.byKey(
      const ValueKey<String>('now-playing-equalizer'),
    );
    expect(button, findsOneWidget);
    expect(find.byTooltip('均衡器'), findsOneWidget);

    await tester.tap(button);
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('桌面歌词按钮按状态显隐并可切换', (WidgetTester tester) async {
    int taps = 0;
    await _pump(tester, data: _data(), onToggleDesktopLyrics: () => taps += 1);

    final Finder button = find.byKey(
      const ValueKey<String>('now-playing-desktop-lyrics'),
    );
    expect(button, findsOneWidget);
    expect(find.byTooltip('桌面歌词'), findsOneWidget);

    await tester.tap(button);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('歌词对齐按钮画当前对齐，点一下回调切换', (WidgetTester tester) async {
    int cycles = 0;
    final ValueNotifier<LyricAlignment> alignment =
        ValueNotifier<LyricAlignment>(LyricAlignment.center);
    addTearDown(alignment.dispose);
    await _pump(
      tester,
      data: _data(),
      lyrics: _timed(),
      lyricAlignment: alignment,
      onCycleLyricAlignment: () => cycles += 1,
    );

    final Finder button = find.byKey(
      const ValueKey<String>('now-playing-lyric-align'),
    );
    expect(button, findsOneWidget);
    expect(
      find.descendant(
        of: button,
        matching: find.byIcon(Icons.format_align_center),
      ),
      findsOneWidget,
    );

    alignment.value = LyricAlignment.right;
    await tester.pump();
    expect(
      find.descendant(
        of: button,
        matching: find.byIcon(Icons.format_align_right),
      ),
      findsOneWidget,
      reason: '按钮要跟着当前对齐换图标',
    );
    expect(find.byTooltip('歌词对齐：右对齐（点击切换）'), findsOneWidget);
    expect(
      tester.widget<LyricsView>(find.byType(LyricsView)).alignment,
      LyricAlignment.right,
      reason: '对齐要真的传到歌词视图，否则按钮只是换了个图标',
    );

    await tester.tap(button);
    await tester.pump();
    expect(cycles, 1);
  });

  testWidgets('译文按钮按当前状态换提示，点一下回调切换', (WidgetTester tester) async {
    int toggles = 0;
    final ValueNotifier<bool> shown = ValueNotifier<bool>(true);
    addTearDown(shown.dispose);
    await _pump(
      tester,
      data: _data(),
      lyrics: _timed(),
      showTranslation: shown,
      onToggleTranslation: () => toggles += 1,
    );

    final Finder button = find.byKey(
      const ValueKey<String>('now-playing-translation'),
    );
    expect(button, findsOneWidget);
    expect(find.byTooltip('隐藏译文'), findsOneWidget);
    expect(
      tester.widget<LyricsView>(find.byType(LyricsView)).showTranslation,
      isTrue,
    );

    shown.value = false;
    await tester.pump();
    expect(find.byTooltip('显示译文'), findsOneWidget);
    expect(
      tester.widget<LyricsView>(find.byType(LyricsView)).showTranslation,
      isFalse,
      reason: '开关要真的传到歌词，否则按钮只是换了个提示',
    );

    await tester.tap(button);
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('锁定开关只在桌面歌词打开时出现，锁定后是实心锁', (WidgetTester tester) async {
    int locks = 0;
    final ValueNotifier<NowPlayingData> notifier = await _pump(
      tester,
      data: _data(),
      onToggleDesktopLyrics: () {},
      onToggleDesktopLyricLock: () => locks += 1,
    );

    final Finder lock = find.byKey(
      const ValueKey<String>('now-playing-desktop-lyrics-lock'),
    );
    expect(lock, findsNothing, reason: '歌词没打开时没有可锁的东西');

    notifier.value = _data(desktopLyrics: true, desktopLyricLocked: true);
    await tester.pump();
    expect(lock, findsOneWidget);
    expect(find.byTooltip('解锁桌面歌词'), findsOneWidget);
    expect(
      find.descendant(of: lock, matching: find.byIcon(Icons.lock)),
      findsOneWidget,
      reason: '锁定状态要看得出来，否则用户不知道点哪里解锁',
    );

    await tester.tap(lock);
    await tester.pump();
    expect(locks, 1);

    notifier.value = _data(desktopLyrics: true);
    await tester.pump();
    expect(find.byTooltip('锁定桌面歌词（鼠标穿透）'), findsOneWidget);
    expect(
      find.descendant(of: lock, matching: find.byIcon(Icons.lock_open)),
      findsOneWidget,
    );
  });

  testWidgets('没有曲目时展示空态且控制按钮禁用', (WidgetTester tester) async {
    await _pump(tester, data: const NowPlayingData());

    expect(find.text('还没有在播放的曲目'), findsOneWidget);
    final IconButton toggle = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('now-playing-toggle')),
    );
    expect(toggle.onPressed, isNull);
  });

  testWidgets('收起热区只覆盖箭头一圈，且不被标题条遮住', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<NowPlayingData> notifier =
        ValueNotifier<NowPlayingData>(_data());
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NowPlayingPage(
                      data: notifier,
                      onTogglePlay: () async {},
                      onPrevious: () async {},
                      onNext: () async {},
                      onSeek: (_) async {},
                      lyricsLoader: (String path) async => const TrackLyrics(
                        lines: <LyricLine>[],
                        plain: '',
                        source: 'none',
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final Rect target = tester.getRect(
      find.byKey(const ValueKey<String>('now-playing-collapse')),
    );
    expect(
      target.width,
      inInclusiveRange(48, 80),
      reason: '热区只该覆盖箭头周围一圈，不应扩散到整行',
    );
    expect(target.height, inInclusiveRange(48, 80));
    expect(target.top, lessThanOrEqualTo(8), reason: 'header 贴住窗口顶端，与右侧窗口按钮齐平');

    // 点标题留白（拖动区）不应收起
    await tester.tap(
      find.byKey(const ValueKey<String>('now-playing-window-drag')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsOneWidget,
    );

    // 点箭头周围能收起
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsNothing,
    );
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('长按进入沉浸模式：进度条与两侧控件收起，只留三个键', (WidgetTester tester) async {
    int toggles = 0;
    await _pump(tester, data: _data(), onTogglePlay: () => toggles += 1);

    AnimatedOpacity chrome(String key) => tester.widget<AnimatedOpacity>(
      find
          .descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>('now-playing-toggle'),
    );

    expect(chrome('now-playing-chrome-volume').opacity, 1);
    expect(chrome('now-playing-chrome-extra').opacity, 1);
    expect(
      find.byKey(const ValueKey<String>('now-playing-progress')),
      findsOneWidget,
    );

    await tester.longPress(toggle);
    await tester.pumpAndSettle();

    expect(find.text('沉浸模式'), findsOneWidget, reason: '进入时给一次轻提示');

    // 提示弹在刚长按的播放键附近，而不是页面顶部
    final Rect toastRect = tester.getRect(find.text('沉浸模式'));
    final Rect toggleRect = tester.getRect(toggle);
    expect(
      toastRect.center.dx,
      closeTo(toggleRect.center.dx, 2),
      reason: '提示与播放键水平对齐',
    );
    expect(toastRect.bottom, lessThan(toggleRect.top), reason: '提示应弹在按钮上方');
    expect(
      find.byKey(const ValueKey<String>('now-playing-progress')),
      findsNothing,
      reason: '进度条属于多余元素',
    );
    expect(chrome('now-playing-chrome-volume').opacity, 0);
    expect(chrome('now-playing-chrome-extra').opacity, 0);
    expect(toggles, 0, reason: '长按不该顺带触发播放 / 暂停');
    for (final String key in <String>[
      'now-playing-previous',
      'now-playing-toggle',
      'now-playing-next',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget);
    }
    expect(
      find
          .byKey(const ValueKey<String>('now-playing-chrome-extra'))
          .hitTestable(),
      findsNothing,
      reason: '淡出的控件不该还能点',
    );

    await _settleToast(tester);
  });

  testWidgets('沉浸模式淡出曲目信息，封面与歌词都不挪位', (WidgetTester tester) async {
    // 有歌词才建得出 LyricsView，才能顺带确认歌词区没被带着动
    await _pump(
      tester,
      data: _data(),
      lyrics: const TrackLyrics(
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
            translation: '',
          ),
        ],
        plain: '',
        source: 'sidecar',
      ),
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>('now-playing-toggle'),
    );
    double infoOpacity() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey<String>('now-playing-info-fade')),
        )
        .opacity;

    expect(infoOpacity(), 1);
    final Rect coverBefore = tester.getRect(find.byType(AlbumCover));
    final Rect lyricBefore = tester.getRect(find.byType(LyricsView));

    await tester.longPress(toggle);
    await tester.pumpAndSettle();
    expect(infoOpacity(), 0, reason: '沉浸模式把曲目信息淡出');
    // 沉浸模式本来就会摘掉进度条，可用高度变了一点点，封面会跟着挪个十来像素；
    // 关键是不能因为信息块收起而上移近百像素
    final Rect coverAfter = tester.getRect(find.byType(AlbumCover));
    expect(
      coverAfter.top,
      closeTo(coverBefore.top, 16),
      reason: '信息块保留占位，封面不该被顶上去',
    );
    expect(coverAfter.width, closeTo(coverBefore.width, 1), reason: '封面尺寸也不该变');
    final Rect lyricAfter = tester.getRect(find.byType(LyricsView));
    expect(
      lyricAfter.top,
      closeTo(lyricBefore.top, 16),
      reason: '歌词区同样只挪一点，两边才不会一个上一个下',
    );

    await tester.longPress(toggle);
    await tester.pumpAndSettle();
    expect(infoOpacity(), 1, reason: '退出沉浸把曲目信息淡回来');
    await _settleToast(tester);
  });

  testWidgets('沉浸模式下三个键位置不变，退出不弹提示', (WidgetTester tester) async {
    await _pump(tester, data: _data());
    final Finder toggle = find.byKey(
      const ValueKey<String>('now-playing-toggle'),
    );
    final Offset before = tester.getCenter(toggle);

    await tester.longPress(toggle);
    await tester.pumpAndSettle();
    await _settleToast(tester);

    expect(tester.getCenter(toggle), before, reason: '收起控件不该挪动这三个键');

    await tester.longPress(toggle);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('now-playing-progress')),
      findsOneWidget,
    );
    expect(find.text('沉浸模式'), findsNothing, reason: '退出不需要提示');
  });

  testWidgets('沉浸模式下返回键靠鼠标靠近顶端才显', (WidgetTester tester) async {
    await _pump(tester, data: _data());
    final Finder toggle = find.byKey(
      const ValueKey<String>('now-playing-toggle'),
    );

    double headerOpacity() => tester
        .widget<AnimatedOpacity>(
          find
              .descendant(
                of: find.byKey(const ValueKey<String>('now-playing-header')),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    expect(headerOpacity(), 1, reason: '普通模式下返回键常显');

    await tester.longPress(toggle);
    await tester.pumpAndSettle();
    await _settleToast(tester);
    expect(headerOpacity(), 0, reason: '沉浸模式下鼠标不在顶部就隐藏');

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(600, 500));
    addTearDown(mouse.removePointer);

    await mouse.moveTo(const Offset(600, 12));
    await tester.pumpAndSettle();
    expect(headerOpacity(), 1, reason: '指针靠近顶端应渐显');

    await mouse.moveTo(const Offset(600, 500));
    await tester.pumpAndSettle();
    expect(headerOpacity(), 0);
  });
  testWidgets('睡眠定时到点先听完当前曲目再暂停', (WidgetTester tester) async {
    int toggles = 0;
    // 歌曲还剩 5 秒（200 - 195）
    await _pump(
      tester,
      data: _data(position: 195, duration: 200),
      onTogglePlay: () => toggles += 1,
    );

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-sleep')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('sleep-dial')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('sleep-preset-15')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();
    expect(toggles, 0, reason: '刚设定时不该立刻暂停');

    await tester.pump(const Duration(minutes: 15));
    expect(toggles, 0, reason: '本曲还没播完，顺延而不是立刻暂停');

    // 顺延 5 秒 + 200ms 余量后再暂停
    await tester.pump(const Duration(seconds: 6));
    // 到点会弹轻提示：把淡入 / 停留 / 淡出走完，别留 pending timer
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(toggles, 1, reason: '曲目播完后应暂停');
  });

  testWidgets('关掉顺延开关后到点立即暂停', (WidgetTester tester) async {
    int toggles = 0;
    await _pump(
      tester,
      data: _data(position: 195, duration: 200),
      onTogglePlay: () => toggles += 1,
    );

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-preset-15')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-extend-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(minutes: 15));
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(toggles, 1, reason: '关掉顺延就到点即停');
  });

  testWidgets('睡眠定时可取消', (WidgetTester tester) async {
    int toggles = 0;
    await _pump(tester, data: _data(), onTogglePlay: () => toggles += 1);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-preset-15')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-confirm')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-clear')));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(minutes: 16));
    expect(toggles, 0, reason: '取消后不该再暂停');
  });

  testWidgets('睡眠定时弹窗右上角的叉号能直接关掉，不改动现有定时', (WidgetTester tester) async {
    int toggles = 0;
    await _pump(tester, data: _data(), onTogglePlay: () => toggles += 1);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-sleep')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('sleep-close')), findsOneWidget);

    // 先把轮盘拨到 15 分再关窗：关窗不该保存这个值
    await tester.tap(find.byKey(const ValueKey<String>('sleep-preset-15')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('sleep-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('sleep-dial')), findsNothing);
    await tester.pump(const Duration(minutes: 16));
    expect(toggles, 0, reason: '叉号只是关窗，不该开始倒计时');
  });

  testWidgets('播放页可切换输出设备', (WidgetTester tester) async {
    final ValueNotifier<List<rust.PlayerDevice>> devices =
        ValueNotifier<List<rust.PlayerDevice>>(const <rust.PlayerDevice>[
          rust.PlayerDevice(index: 1, name: '扬声器', isDefault: true),
          rust.PlayerDevice(index: 2, name: '耳机', isDefault: false),
        ]);
    final ValueNotifier<int> selected = ValueNotifier<int>(-1);
    final List<int> picks = <int>[];
    addTearDown(devices.dispose);
    addTearDown(selected.dispose);

    await _pump(
      tester,
      data: _data(),
      devices: devices,
      selectedDevice: selected,
      onSelectDevice: picks.add,
    );

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-output')));
    await tester.pumpAndSettle();
    expect(find.text('系统默认'), findsOneWidget);
    await tester.tap(find.text('耳机'));
    await tester.pumpAndSettle();

    expect(picks, <int>[2], reason: '选中设备要回调给页面');

    // 提示统一弹在播放 / 暂停键上方（与沉浸模式提示同一位置）
    final Rect toast = tester.getRect(find.text('输出设备：耳机'));
    final Rect toggle = tester.getRect(
      find.byKey(const ValueKey<String>('now-playing-toggle')),
    );
    expect(toast.bottom, lessThanOrEqualTo(toggle.top));
    expect(toast.center.dx, closeTo(toggle.center.dx, 1));
    await _settleToast(tester);
  });

  testWidgets('封面随窗口放大，但有上限', (WidgetTester tester) async {
    await _pump(tester, data: _data());

    expect(tester.takeException(), isNull);
    final double at1280 = tester.getSize(find.byType(AlbumCover).first).width;
    expect(at1280, closeTo(341, 8), reason: '默认窗口与原来的 336 基本一致');

    // 全屏 / 大窗口：封面跟着变大，但整块内容限宽，封面不能被无限放大
    await _pump(tester, data: _data(), size: const Size(1920, 1080));
    final double at1920 = tester.getSize(find.byType(AlbumCover).first).width;
    expect(at1920, greaterThan(at1280), reason: '窗口变大封面要跟上');
    expect(at1920, lessThanOrEqualTo(480), reason: '留出歌词与阴影的空间');
  });

  testWidgets('封面挂着 Hero，与播放条配对飞入 / 飞出', (WidgetTester tester) async {
    await _pump(tester, data: _data());

    final Hero hero = tester.widget<Hero>(
      find.ancestor(of: find.byType(AlbumCover), matching: find.byType(Hero)),
    );
    expect(hero.tag, coverHeroTag);

    // 两个方向都返回裸 shuttle：交接进度按目标页动画算，pop 时目标页停在
    // 最后一帧，套上淡出就是 1% 透明（整段飞行消失）；而任何 `Opacity` 都会让
    // Impeller 下推透明度给带模糊的阴影、断言后逐帧退回 saveLayer
    final BuildContext context = tester.element(find.byType(AlbumCover));
    final Widget pushed = hero.flightShuttleBuilder!(
      context,
      const AlwaysStoppedAnimation<double>(0.5),
      HeroFlightDirection.push,
      context,
      context,
    );
    final Widget popped = hero.flightShuttleBuilder!(
      context,
      const AlwaysStoppedAnimation<double>(0.5),
      HeroFlightDirection.pop,
      context,
      context,
    );
    expect(pushed, isNot(isA<FadeTransition>()), reason: '不要额外的透明度层');
    expect(popped, isNot(isA<FadeTransition>()));
    // 占位要挂着原封面（图片订阅不断，落地不空帧），但不能包 `Opacity`
    // —— 透明度会被下推到那圈模糊阴影上，每帧退回 saveLayer
    expect(hero.placeholderBuilder, isNotNull);
    const Widget probe = SizedBox(width: 8, height: 8);
    final Widget placeholder = hero.placeholderBuilder!(
      context,
      const Size(340, 340),
      probe,
    );
    expect(placeholder, isNot(isA<Opacity>()));
    expect((placeholder as SizedBox).child, isA<Offstage>());
    expect((placeholder.child! as Offstage).child, same(probe));

    // Hero 外面必须有一层绘制边界，而且边界要比封面大一圈（包住阴影外溢）：
    // 落地把占位换回子树时 markNeedsPaint 会爬到最近的边界，没有边界就等于
    // 整页重画（全屏流光背景 + 歌词全在里面），窗口越大越卡
    final double coverSide = tester.getSize(find.byType(AlbumCover)).width;
    // 取离 Hero 最近的那层（外层可能还有框架自己的边界）
    final RenderBox heroBox = tester
        .renderObjectList<RenderBox>(
          find.ancestor(
            of: find.byType(Hero),
            matching: find.byType(RepaintBoundary),
          ),
        )
        .first;
    expect(
      heroBox.size.width,
      closeTo(coverSide + CoverShadow.spread * 2, 0.5),
      reason: '边界要包住阴影外溢，否则阴影被裁掉一圈',
    );
  });

  testWidgets('曲目信息压在封面上方，左对齐且随窗口内缩', (WidgetTester tester) async {
    for (final Size size in <Size>[
      const Size(1080, 720),
      const Size(1280, 900),
      const Size(1920, 1080),
      const Size(2560, 1440),
    ]) {
      await _pump(tester, data: _data(), size: size);
      final Rect page = tester.getRect(find.byType(NowPlayingPage));
      final Rect info = tester.getRect(
        find.byKey(const ValueKey<String>('now-playing-info')),
      );
      final Rect cover = tester.getRect(find.byType(AlbumCover).first);
      expect(
        info.left - page.left,
        closeTo(cover.left - page.left, 2),
        reason: '$size 下信息块和封面左边要对齐',
      );
      expect(
        info.bottom,
        lessThanOrEqualTo(cover.top),
        reason: '$size 下信息块要压在封面上方',
      );
      expect(
        cover.left - page.left,
        greaterThan(80),
        reason: '$size 下整列不能挤在角落',
      );
      // 间距按封面高度取 1/7：窗口一大一小，比例都得一样
      expect(
        (cover.top - info.bottom) / cover.height,
        closeTo(1 / 7, 0.02),
        reason: '$size 下信息块与封面的距离应当是封面高度的 1/7',
      );
    }
  });

  testWidgets('歌词当前行与封面中心线对齐', (WidgetTester tester) async {
    await _pump(tester, data: _data(position: 10), lyrics: _timed());

    final Rect cover = tester.getRect(find.byType(AlbumCover).first);
    final Rect active = tester.getRect(
      find.byKey(const ValueKey<String>('lyric-2')),
    );
    expect(
      active.center.dy,
      closeTo(cover.center.dy, 8),
      reason: '当前行要落在封面中心线上，而不是歌词区正中',
    );
  });

  testWidgets('打开圆形封面后阴影容器也跟着变圆', (WidgetTester tester) async {
    addTearDown(() => circularCovers.value = false);
    await _pump(tester, data: _data());

    BoxDecoration shadowDecoration() {
      // 阴影现在是独立一层的 DecoratedBox（和封面分开，落地那帧不用重做模糊）
      final Finder box = find.byWidgetPredicate(
        (Widget widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).boxShadow != null,
      );
      return tester.widget<DecoratedBox>(box.first).decoration as BoxDecoration;
    }

    expect(shadowDecoration().shape, BoxShape.rectangle);

    circularCovers.value = true;
    await tester.pump();

    // 矩形阴影会在圆形封面四角露出一圈方形光晕
    expect(shadowDecoration().shape, BoxShape.circle);
    expect(shadowDecoration().borderRadius, isNull);
  });

  testWidgets('圆形封面 25 秒转一圈，暂停就停住', (WidgetTester tester) async {
    addTearDown(() => circularCovers.value = false);
    final ValueNotifier<NowPlayingData> notifier = await _pump(
      tester,
      data: _data(),
    );

    double turns() {
      // 旋转由 UiClock 的 60fps 档每 16ms 推进一次，不跟显示器刷新率走；
      // 角度读自 Transform 的矩阵
      final Transform spin = tester.widget<Transform>(
        find.byKey(const ValueKey<String>('now-playing-cover-spin')),
      );
      final List<double> m = spin.transform.storage;
      return math.atan2(m[1], m[0]) / (2 * math.pi);
    }

    expect(turns(), 0, reason: '默认方形封面不转');

    circularCovers.value = true;
    await tester.pump();
    expect(turns(), 0);

    // 6 秒 = 6/25 圈
    await tester.pump(const Duration(seconds: 6));
    expect(turns(), closeTo(6 / 25, 0.01));

    // 暂停：停在当前角度，不会跳回正面
    final NowPlayingData playing = notifier.value;
    notifier.value = NowPlayingData(
      track: playing.track,
      isPlaying: false,
      position: playing.position,
      duration: playing.duration,
      isAvailable: playing.isAvailable,
      volume: playing.volume,
    );
    await tester.pump();
    final double frozen = turns();
    await tester.pump(const Duration(seconds: 5));
    expect(turns(), frozen);
  });

  testWidgets('默认 1280×720 窗口：封面往里挪，且不把歌名压到频谱上', (WidgetTester tester) async {
    final ValueNotifier<List<double>> spectrum = ValueNotifier<List<double>>(
      List<double>.filled(24, 0.6),
    );
    addTearDown(spectrum.dispose);
    await _pump(
      tester,
      data: _data(),
      size: const Size(1280, 720),
      spectrum: spectrum,
    );

    final Rect cover = tester.getRect(find.byType(AlbumCover).first);
    final Rect bars = tester.getRect(
      find.byKey(const ValueKey<String>('now-playing-spectrum')),
    );
    final Rect info = tester.getRect(
      find.byKey(const ValueKey<String>('now-playing-info')),
    );

    expect(info.left, closeTo(cover.left, 2), reason: '信息块与封面左对齐');
    expect(info.bottom, lessThanOrEqualTo(cover.top), reason: '信息块在封面上方');
    expect(cover.left, greaterThan(100), reason: '不能还挤在角落（旧值 74）');
    expect(cover.bottom, lessThan(bars.top), reason: '往下挪之后，封面不能压在频谱丝带上');
  });

  testWidgets('最小窗口下开满底部按钮也不溢出', (WidgetTester tester) async {
    // 底部左侧那一串图标一字排开，900 宽是最挤的情况：设备、均衡器、桌面歌词、
    // 锁定、歌词对齐全都亮着，两侧各占一半宽度
    final ValueNotifier<List<rust.PlayerDevice>> devices =
        ValueNotifier<List<rust.PlayerDevice>>(const <rust.PlayerDevice>[
          rust.PlayerDevice(index: 1, name: '扬声器', isDefault: true),
        ]);
    final ValueNotifier<int> selected = ValueNotifier<int>(-1);
    final ValueNotifier<LyricAlignment> alignment =
        ValueNotifier<LyricAlignment>(LyricAlignment.center);
    final ValueNotifier<bool> shown = ValueNotifier<bool>(true);
    addTearDown(devices.dispose);
    addTearDown(selected.dispose);
    addTearDown(alignment.dispose);
    addTearDown(shown.dispose);

    await _pump(
      tester,
      data: _data(desktopLyrics: true),
      devices: devices,
      selectedDevice: selected,
      onSelectDevice: (_) {},
      onOpenEqualizer: () {},
      onToggleDesktopLyrics: () {},
      onToggleDesktopLyricLock: () {},
      lyricAlignment: alignment,
      onCycleLyricAlignment: () {},
      showTranslation: shown,
      onToggleTranslation: () {},
      size: const Size(900, 560),
    );

    expect(tester.takeException(), isNull, reason: '最小窗口下按钮不该挤到溢出');
    expect(
      find.byKey(const ValueKey<String>('now-playing-lyric-align')),
      findsOneWidget,
    );
  });

  testWidgets('窗口压到最小高度时封面自动缩小，不溢出', (WidgetTester tester) async {
    // 900×560 是 main.dart 里 windowManager 允许的最小窗口
    await _pump(tester, data: _data(), size: const Size(900, 560));

    expect(tester.takeException(), isNull, reason: '最小窗口下不该溢出');
    final double cover = tester.getSize(find.byType(AlbumCover).first).width;
    expect(cover, lessThan(336), reason: '高度不够时封面要让位');
    expect(cover, greaterThanOrEqualTo(200), reason: '也不该缩到看不出封面');
  });

  testWidgets('空格 / 方向键 / 媒体键在本页生效', (WidgetTester tester) async {
    int toggles = 0;
    int previous = 0;
    int next = 0;
    final List<double> seeks = <double>[];
    await _pump(
      tester,
      data: _data(position: 30, duration: 200),
      onTogglePlay: () => toggles += 1,
      onPrevious: () => previous += 1,
      onNext: () => next += 1,
      onSeek: seeks.add,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggles, 1, reason: '空格播放 / 暂停');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.last, 35, reason: '→ 快进 5 秒');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(seeks.last, 30, reason: '← 快退 5 秒');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(next, 1, reason: 'Ctrl+→ 下一首');
    expect(previous, 1, reason: 'Ctrl+← 上一首');

    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(toggles, 2, reason: '媒体键与空格同一条路径');
  });

  testWidgets('方向键快退到头夹在 0，不发出负位置', (WidgetTester tester) async {
    final List<double> seeks = <double>[];
    await _pump(
      tester,
      data: _data(position: 2, duration: 200),
      onSeek: seeks.add,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(seeks.single, 0);
  });

  testWidgets('没有曲目时长时方向键不 seek', (WidgetTester tester) async {
    final List<double> seeks = <double>[];
    await _pump(
      tester,
      data: _data(position: 0, duration: 0),
      onSeek: seeks.add,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(seeks, isEmpty, reason: '时长未知时不该盲跳');
  });

  testWidgets('按住头部能拖动窗口，双击可最大化', (WidgetTester tester) async {
    // 正在播放页是整窗路由，把外壳标题栏连同拖动区一起盖住了：
    // 这一页必须自带拖动区，否则用户按不住窗口（曾经如此）
    final _FakeWindowControls controls = _FakeWindowControls();
    await _pump(tester, data: _data(), windowControls: controls);

    await tester.drag(
      find.byKey(const ValueKey<String>('now-playing-window-drag')),
      const Offset(0, 80),
    );
    await tester.pump();
    expect(controls.drags, 1, reason: '头部按下拖动要交给窗口管理器');

    await tester.tap(
      find.byKey(const ValueKey<String>('now-playing-window-drag')),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(
      find.byKey(const ValueKey<String>('now-playing-window-drag')),
    );
    await tester.pumpAndSettle();
    expect(controls.maximizes, 1, reason: '双击头部最大化，与外壳标题栏一致');
  });

  testWidgets('头部拖动区不吃「收起」按钮', (WidgetTester tester) async {
    final _FakeWindowControls controls = _FakeWindowControls();
    await _pump(tester, data: _data(), windowControls: controls);

    await tester.tap(
      find.byKey(const ValueKey<String>('now-playing-collapse')),
    );
    await tester.pumpAndSettle();
    expect(controls.drags, 0);
    expect(controls.maximizes, 0);
  });

  testWidgets('收起一开始就把窗口按钮交还全局，不等页面销毁', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => pageOwnsWindowControls.value = false);

    final ValueNotifier<NowPlayingData> notifier =
        ValueNotifier<NowPlayingData>(_data());
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NowPlayingPage(
                      data: notifier,
                      onTogglePlay: () async {},
                      onPrevious: () async {},
                      onNext: () async {},
                      onSeek: (_) async {},
                      windowControls: _FakeWindowControls(),
                      lyricsLoader: (String path) async => const TrackLyrics(
                        lines: <LyricLine>[],
                        plain: '',
                        source: 'none',
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(pageOwnsWindowControls.value, isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('now-playing-collapse')),
    );
    await tester.pump();

    // 关键：页面还在滑，但按钮已经交还给全局那层——等 dispose 才交还的话，
    // 右上角会在整段收起动画里空着
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(pageOwnsWindowControls.value, isFalse, reason: '收起一开始就要交还，不能等页面销毁');

    await tester.pumpAndSettle();
  });

  testWidgets('播放页自带窗口按钮：固定白色 + 描影，并让全局那层让位', (WidgetTester tester) async {
    addTearDown(() => pageOwnsWindowControls.value = false);
    final _FakeWindowControls controls = _FakeWindowControls();
    await _pump(tester, data: _data(), windowControls: controls);

    final WindowButtons buttons = tester.widget<WindowButtons>(
      find.byType(WindowButtons),
    );
    expect(buttons.foreground, Colors.white, reason: '取色背景上固定白色');
    expect(buttons.castShadow, isTrue, reason: '渐变底需要描影兜底');
    expect(pageOwnsWindowControls.value, isTrue, reason: '全局那层要让位');

    // 按钮在页面里，跟着页面一起滑：和顶部的收起键同一条 48 高的横线
    final Rect close = tester.getRect(
      find.byKey(const ValueKey<String>('window-close')),
    );
    final Rect collapse = tester.getRect(
      find.byKey(const ValueKey<String>('now-playing-collapse')),
    );
    expect(close.center.dy, closeTo(collapse.center.dy, 1));
    expect(
      close.right,
      closeTo(tester.view.physicalSize.width / tester.view.devicePixelRatio, 1),
    );
  });

  testWidgets('拖动时才出取值气泡：进度给时间、音量给整数', (WidgetTester tester) async {
    await _pump(tester, data: _data(position: 60, duration: 249, volume: 0.62));

    // 底部两行文字只有「当前位置 / 总时长」，拖动时看不出正要跳到哪儿，
    // 所以滑块自己带一条 label，由取值气泡在拖动期间显示
    final Slider progress = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('now-playing-progress')),
    );
    expect(progress.label, formatDuration(60));

    final Slider volume = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('now-playing-volume')),
    );
    expect(volume.label, '62', reason: '音量给整数百分比，0.62 读起来不直观');

    for (final String key in <String>[
      'now-playing-progress',
      'now-playing-volume',
    ]) {
      final SliderTheme theme = tester.widget<SliderTheme>(
        find
            .ancestor(
              of: find.byKey(ValueKey<String>(key)),
              matching: find.byType(SliderTheme),
            )
            .first,
      );
      expect(
        theme.data.showValueIndicator,
        ShowValueIndicator.onDrag,
        reason: '常驻会一直挡住上方的控制区',
      );
      expect(theme.data.valueIndicatorTextStyle?.fontSize, 12);
    }
  });
}

/// 只记录调用次数的窗口控制假实现
class _FakeWindowControls implements WindowControls {
  int drags = 0;
  int maximizes = 0;

  @override
  Future<void> startDragging() async => drags += 1;

  @override
  Future<bool> toggleMaximize() async {
    maximizes += 1;
    return true;
  }

  @override
  Future<void> minimize() async {}

  @override
  Future<void> close() async {}

  @override
  Future<bool> isMaximized() async => false;

  @override
  Stream<bool> get maximizeChanges => const Stream<bool>.empty();
}

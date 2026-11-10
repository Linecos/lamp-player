// 一次性诊断脚本：量「正在播放页」各部分占多少进程内存。
//
//   PROBE_MODE=full|lyrics|artists|stress|blank flutter run -d windows --no-pub -t tool/mem_probe.dart
//
// stress = full 页 + 每 400ms 把歌词定位来回跳 + 每 800ms 跑一次带遮挡的
// 封面飞行（今天的改动），跑 60 秒看 RSS 是否单调涨。
//
// 每 5 秒打一行 RSS；数字只用于比较同一台机器上不同模式之间的差额。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lamp_player/src/features/player/lyric_alignment.dart';
import 'package:lamp_player/src/features/player/lyrics_view.dart';
import 'package:lamp_player/src/features/player/now_playing_page.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart' as lyrics_api;
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/collection_grids.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/common/widgets/cover_shape.dart';
import 'package:lamp_player/src/features/library/widgets/cover_flight.dart';
import 'package:lamp_player/src/theme/app_theme.dart';
import 'package:window_manager/window_manager.dart';

int _mb(int bytes) => bytes ~/ (1024 * 1024);

/// 两套代码的 onSelect 参数个数不一样（旧版 2 参、新版 3 参），
/// 用可选位置参数让探针在两个提交上都能编译
void _ignoreSelect(Object _, [Object? coverRect, Object? viewport]) {}

final String _mode = Platform.environment['PROBE_MODE'] ?? 'full';

/// MaterialApp 之下的 context：飞行要往根 Overlay 上插层
BuildContext? _overlayContext;

void _report(String tag) {
  final ImageCache cache = PaintingBinding.instance.imageCache;
  debugPrint(
    '[probe:$_mode] $tag RSS=${_mb(ProcessInfo.currentRss)}MB'
    ' peak=${_mb(ProcessInfo.maxRss)}MB'
    ' 图片缓存 ${cache.currentSize} 张/${_mb(cache.currentSizeBytes)}MB'
    ' live=${cache.liveImageCount}',
  );
}

List<lyrics_api.LyricLine> _lines() => <lyrics_api.LyricLine>[
  for (int i = 0; i < 120; i += 1)
    lyrics_api.LyricLine(
      timeMs: i * 5000,
      endMs: (i + 1) * 5000,
      text: i == 12 ? '这一句特别长，长到必须折行才能放得下，用来触发重排' : '第 $i 行歌词，写长一点让它有几十个像素',
      words: const <lyrics_api.LyricWord>[],
      translation: i.isEven ? 'a translation line for $i' : '',
    ),
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1600, 1000),
      center: true,
      title: 'lamp mem probe',
    ),
    () async {
      await windowManager.show();
      // 量的时候必须在前台：被遮住 / 最小化的窗口会被系统裁工作集，
      // 数字偏低（见 docs/PERF.md 与 memory_log 的同一个坑）
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
    },
  );

  final ValueNotifier<double> position = ValueNotifier<double>(0);
  final ValueNotifier<bool> showPage = ValueNotifier<bool>(false);
  final ValueNotifier<bool> playing = ValueNotifier<bool>(true);

  // 圆形封面开（与用户实测场景一致）：封面 60fps 旋转
  circularCovers.value = Platform.environment['LAMP_PROBE_SQUARE'] != '1';
  final List<File> covers = Directory(
    '${Platform.environment['APPDATA']}\\Lamp Player\\Lamp Player\\covers',
  ).listSync().whereType<File>().toList();
  final Track track = Track(
    path: '/music/probe.mp3',
    coverPath: covers.isEmpty ? null : covers.first.path,
    title: "I'm the One Who's Always Searching",
    artist: '林间电台',
    album: '夜之专辑',
    durationSecs: 600,
    addedAt: 0,
    replayGain: 0,
  );
  final ValueNotifier<NowPlayingData> data = ValueNotifier<NowPlayingData>(
    NowPlayingData(
      track: track,
      isPlaying: true,
      duration: 600,
      isAvailable: true,
    ),
  );

  // LAMP_PROBE_STATIC=1：暂停进度，只剩封面在转 —— 拆「旋转」和「歌词逐帧」
  final bool staticPosition = Platform.environment['LAMP_PROBE_STATIC'] == '1';
  Timer.periodic(const Duration(milliseconds: 33), (Timer timer) {
    if (staticPosition) {
      return;
    }
    position.value += 0.033;
    data.value = NowPlayingData(
      track: track,
      isPlaying: true,
      position: position.value,
      duration: 600,
      isAvailable: true,
      volume: 1,
    );
  });

  runApp(
    ValueListenableBuilder<bool>(
      valueListenable: showPage,
      builder: (BuildContext context, bool page, Widget? _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(AppTheme.defaultSeed),
          home: Builder(
            builder: (BuildContext context) {
              _overlayContext = context;
              return page ? _page(data, position, playing) : const Scaffold();
            },
          ),
        );
      },
    ),
  );

  Future<void>.delayed(const Duration(seconds: 4), () {
    _report('空页面');
    showPage.value = true;
  });

  if (_mode == 'stress') {
    // 歌词来回大跳：触发滚动动画 + 错峰弹簧 + 逐行模糊重画
    Timer.periodic(const Duration(milliseconds: 400), (Timer timer) {
      position.value = timer.tick.isEven ? 0 : 120;
      data.value = NowPlayingData(
        track: track,
        isPlaying: true,
        position: position.value,
        duration: 600,
        isAvailable: true,
      );
    });
  }
  final List<int> marks = _mode == 'stress'
      ? <int>[
          9,
          12,
          15,
          18,
          21,
          24,
          27,
          30,
          33,
          36,
          39,
          42,
          45,
          48,
          51,
          54,
          57,
          60,
          63,
          66,
        ]
      : <int>[9, 12, 15, 18, 21, 24];
  for (final int seconds in marks) {
    Future<void>.delayed(Duration(seconds: seconds), () {
      _report('页面 ${seconds}s');
      if (seconds == marks.last) {
        unawaited(windowManager.setAlwaysOnTop(false));
        exit(0);
      }
    });
  }
  _report('起点');
}

Widget _page(
  ValueNotifier<NowPlayingData> data,
  ValueNotifier<double> position,
  ValueNotifier<bool> playing,
) {
  if (_mode == 'blank') {
    // LAMP_PROBE_60FPS=1：用一个 60fps 的小 Text 强迫引擎跑满帧率，
    // 拆「帧率高」和「转的东西大」这两个变量
    if (Platform.environment['LAMP_PROBE_60FPS'] == '1') {
      final ValueNotifier<int> fps = ValueNotifier<int>(0);
      Timer.periodic(const Duration(milliseconds: 16), (Timer t) => fps.value = t.tick);
      return Scaffold(
        body: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: fps,
            builder: (BuildContext context, int v, Widget? _) =>
                Text('帧 $v', style: const TextStyle(fontSize: 14)),
          ),
        ),
      );
    }
    return const Scaffold();
  }
  if (_mode == 'flight') {
    // 反复做「带真封面的飞行」：每次飞完 Overlay 撤掉、缓存条目变成死条目，
    // 看 RSS 是否随使用次数爬升（40MB 上限的 ImageCache 被死条目填满）
    final List<File> covers = Directory(
      '${Platform.environment['APPDATA']}\\Lamp Player\\Lamp Player\\covers',
    ).listSync().whereType<File>().toList();
    final String cover = covers.first.path;
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    Timer.periodic(const Duration(milliseconds: 600), (Timer timer) {
      tick.value = timer.tick;
      if (timer.tick < 2) {
        return; // 等首帧布局
      }
      final BuildContext? ctx = _overlayContext;
      if (ctx == null) {
        return;
      }
      flyCover(
        ctx,
        from: const Rect.fromLTWH(60, 40, 180, 180),
        to: const Rect.fromLTWH(700, 90, 340, 340),
        fromRadius: 20,
        toRadius: 32,
        buildCover: (double size, double radius, double decodeScale) =>
            AlbumCover(
              path: cover,
              size: size,
              radius: radius,
              decodeScale: decodeScale,
            ),
        onDone: () {},
        duration: const Duration(milliseconds: 300),
      );
    });
    return Scaffold(
      body: ValueListenableBuilder<int>(
        valueListenable: tick,
        builder: (BuildContext context, int value, Widget? _) => Column(
          children: <Widget>[
            const SizedBox(height: 40, width: double.infinity),
            Text('飞行次数 $value', style: const TextStyle(fontSize: 18)),
          ],
        ),
      ),
    );
  }
  if (_mode == 'artists') {
    // 模拟艺术家分区：每位艺术家一张真实封面（与曲库缓存同源），
    // 并模拟「使用」——每秒点一次导航条跳段
    final List<File> covers = Directory(
      '${Platform.environment['APPDATA']}\\Lamp Player\\Lamp Player\\covers',
    ).listSync().whereType<File>().toList();
    final List<ArtistGroup> artists = <ArtistGroup>[
      for (int i = 0; i < 30; i += 1)
        ArtistGroup(
          name: '艺术家 ${String.fromCharCode(0x41 + i % 26)}$i',
          tracks: <Track>[
            Track(
              path: '/music/p$i.mp3',
              title: '曲目 $i',
              artist: '艺术家 $i',
              album: '专辑 $i',
              durationSecs: 200,
              addedAt: 0,
              replayGain: 0,
              // LAMP_PROBE_NO_COVER=1：头像回退首字母，用来把「图片本身」
              // 和「网格结构」的内存拆开
              coverPath: Platform.environment['LAMP_PROBE_NO_COVER'] == '1'
                  ? null
                  : (covers.isEmpty ? null : covers[i % covers.length].path),
            ),
          ],
        ),
    ];
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.only(top: 40),
        child: ArtistGridView(artists: artists, onSelect: _ignoreSelect),
      ),
    );
  }
  if (_mode.startsWith('lyrics')) {
    return Scaffold(
      body: LyricsView(
        lines: _lines(),
        position: position,
        playing: playing,
        onSeek: (double seconds) async {},
      ),
    );
  }
  return NowPlayingPage(
    data: data,
    onTogglePlay: () async {},
    onPrevious: () async {},
    onNext: () async {},
    onSeek: (double seconds) async {},
    lyricAlignment: ValueNotifier<LyricAlignment>(LyricAlignment.center),
    showTranslation: ValueNotifier<bool>(true),
    lyricsLoader: (String path) async =>
        lyrics_api.TrackLyrics(lines: _lines(), plain: '', source: 'probe'),
  );
}

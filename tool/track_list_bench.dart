// 一次性压测脚本：10k 曲目列表在 release 下的构建 + 滚动帧耗时。
//
//   flutter run -d windows --release -t tool/track_list_bench.dart
//
// 只用假曲目，不碰曲库。窗口必须在前台，否则 Windows 不合成、raster 会是假的 0.x ms。
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/track_list_view.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:window_manager/window_manager.dart';

const int _count = 10000;
const double _w = 1280;
const double _h = 800;

List<Track> _tracks() {
  const List<String> words = <String>[
    '城市低语',
    '夜航',
    '天台',
    '归途',
    '风起',
    '潮汐',
    '山谷',
    '回声',
    '灯火',
    '长街',
  ];
  const List<String> artists = <String>['林间电台', '夜航计划', '远山乐队', 'Lily', 'Kite'];
  return <Track>[
    for (int i = 0; i < _count; i++)
      Track(
        path:
            'D:\\lamp-perf-library\\专辑 ${(i ~/ 20).toString().padLeft(4, '0')}'
            '\\曲目 ${i.toString().padLeft(5, '0')}.flac',
        title: '${words[i % words.length]} ${i.toString().padLeft(5, '0')}',
        artist: artists[i % artists.length],
        album: '专辑 ${(i ~/ 20).toString().padLeft(4, '0')}',
        durationSecs: 120 + (i % 300).toDouble(),
        trackNum: i % 20 + 1,
        addedAt: i,
        coverPath: 'covers/bdfa45a60e2409d9.png',
        replayGain: 0,
        fileSize: 15000,
        audioBitrate: 900,
        sampleRate: 44100,
        bitDepth: 16,
        loudnessLufs: 0,
        samplePeak: 0,
        truePeak: 0,
      ),
  ];
}

class _Rec {
  final List<FrameTiming> frames = <FrameTiming>[];
  bool _on = false;

  void start() {
    frames.clear();
    if (_on) {
      return;
    }
    _on = true;
    SchedulerBinding.instance.addTimingsCallback(frames.addAll);
  }

  void stop() {
    if (!_on) {
      return;
    }
    _on = false;
    SchedulerBinding.instance.removeTimingsCallback(frames.addAll);
  }

  String report(String label) {
    if (frames.isEmpty) {
      return 'BENCH $label 无采样';
    }
    double mean(List<int> v) => v.reduce((int a, int b) => a + b) / v.length;
    int p(List<int> v, double q) =>
        v[(v.length * q).floor().clamp(0, v.length - 1)];
    String ms(num us) => (us / 1000).toStringAsFixed(2);

    final List<int> builds = <int>[
      for (final FrameTiming t in frames) t.buildDuration.inMicroseconds,
    ]..sort();
    final List<int> rasters = <int>[
      for (final FrameTiming t in frames) t.rasterDuration.inMicroseconds,
    ]..sort();
    final List<int> totals = <int>[
      for (final FrameTiming t in frames) t.totalSpan.inMicroseconds,
    ]..sort();
    final int over17 = frames
        .where((FrameTiming t) => t.totalSpan.inMicroseconds > 16700)
        .length;
    return 'BENCH $label 帧 ${frames.length}｜'
        'build 均 ${ms(mean(builds))}/P95 ${ms(p(builds, 0.95))}｜'
        'raster 均 ${ms(mean(rasters))}/P95 ${ms(p(rasters, 0.95))}｜'
        '合计 均 ${ms(mean(totals))}/P50 ${ms(p(totals, 0.5))}/'
        'P95 ${ms(p(totals, 0.95))}/最大 ${ms(totals.last)}｜'
        '超 16.7ms $over17 帧';
  }
}

class _Bench extends StatefulWidget {
  const _Bench();

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final _Rec _rec = _Rec();
  final ScrollController _controller = ScrollController();
  final Stopwatch _clock = Stopwatch();
  List<Track> _list = const <Track>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 1));

    _clock.start();
    final List<Track> sorted = sortTracks(_tracks(), LibrarySort.title);
    debugPrint(
      'BENCH sort 10k title ${(_clock.elapsedMicroseconds / 1000.0).toStringAsFixed(1)} ms',
    );
    _clock.reset();
    _clock.start();
    setState(() => _list = sorted);
    await Future<void>.delayed(const Duration(seconds: 1));
    debugPrint(
      'BENCH first frame after setState ${(_clock.elapsedMicroseconds / 1000.0).toStringAsFixed(1)} ms',
    );

    // 逐帧往下滚：每帧 300px，约 15 万像素，够覆盖 10k 行的中段
    _rec.start();
    for (int i = 0; i < 180; i++) {
      final double max = _controller.position.maxScrollExtent;
      final double target = ((i + 1) * 300.0).clamp(0.0, max);
      _controller.jumpTo(target);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    _rec.stop();
    debugPrint(_rec.report('scroll 10k'));
    exit(0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF15151C),
        body: SizedBox(
          width: _w,
          height: _h,
          child: _list.isEmpty
              ? Center(
                  child: Text(
                    '准备中',
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              : TrackListView(
                  tracks: _list,
                  controller: _controller,
                  onPlay: (Track track) {},
                ),
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const WindowOptions options = WindowOptions(
    size: Size(_w, _h),
    center: true,
    title: 'track-list-bench',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(true);
  });
  runApp(const _Bench());
}

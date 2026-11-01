// 一次性诊断脚本：量「封面 Hero 飞行时带阴影」的每帧代价。
//
//   flutter run -d windows --release -t tool/hero_flight_bench.dart
//
// 同一页面、同一转场，只换 shuttle（带阴影 / 只有封面本体），各跑 5 个来回，
// 读 FrameTiming 的 raster 分项。数字只用于比较两组之间的差额，绝对值随机器。
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:window_manager/window_manager.dart';

const Widget _cover = ColoredBox(color: Color(0xFFCC2233));

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

  String report() {
    if (frames.isEmpty) {
      return '无采样';
    }
    final List<int> rasters = <int>[
      for (final FrameTiming t in frames) t.rasterDuration.inMicroseconds,
    ]..sort();
    final List<int> totals = <int>[
      for (final FrameTiming t in frames)
        t.rasterDuration.inMicroseconds + t.buildDuration.inMicroseconds,
    ]..sort();
    double mean(List<int> v) => v.reduce((int a, int b) => a + b) / v.length;
    int p(List<int> v, double q) =>
        v[(v.length * q).floor().clamp(0, v.length - 1)];
    String ms(num us) => (us / 1000).toStringAsFixed(1);
    final int jank = totals.where((int t) => t >= 4167).length;
    return '帧 ${frames.length}｜raster 均 ${ms(mean(rasters))} '
        'P50 ${ms(p(rasters, 0.5))} P95 ${ms(p(rasters, 0.95))} '
        '最大 ${ms(rasters.last)}｜整帧 P95 ${ms(p(totals, 0.95))}'
        '｜>4.17ms $jank 帧';
  }
}

Widget _sourcePage() => Scaffold(
  backgroundColor: const Color(0xFF15151C),
  body: Center(
    child: Hero(
      tag: coverHeroTag,
      createRectTween: (Rect? b, Rect? e) => RectTween(begin: b, end: e),
      child: const SizedBox(width: 56, height: 56, child: _cover),
    ),
  ),
);

Widget _detailPage({required bool shadowInShuttle}) {
  final Widget cover = const SizedBox(width: 336, height: 336, child: _cover);
  return Scaffold(
    backgroundColor: const Color(0xFF15151C),
    body: Center(
      child: Hero(
        tag: coverHeroTag,
        createRectTween: (Rect? b, Rect? e) => RectTween(begin: b, end: e),
        flightShuttleBuilder: (_, _, _, _, _) => shadowInShuttle
            ? coverFlightShuttle(size: 336, cover: cover)
            : FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: 336,
                  height: 336,
                  child: RepaintBoundary(child: cover),
                ),
              ),
        child: CoverShadow(radius: 28, child: cover),
      ),
    ),
  );
}

class _Bench extends StatefulWidget {
  const _Bench();

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  final _Rec _rec = _Rec();

  Route<void> _route({required bool shadow}) => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => _detailPage(shadowInShuttle: shadow),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    // 预热：第一轮包含着色器/图片首次上屏，不计
    for (int i = 0; i < 2; i += 1) {
      unawaited(_nav.currentState!.push(_route(shadow: false)));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _nav.currentState!.pop();
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    for (final bool shadow in <bool>[false, true, false, true]) {
      _rec.start();
      for (int i = 0; i < 5; i += 1) {
        unawaited(_nav.currentState!.push(_route(shadow: shadow)));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _nav.currentState!.pop();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _rec.stop();
      debugPrint('BENCH ${shadow ? 'B 带阴影' : 'A 只有封面'}: ${_rec.report()}');
    }
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _nav,
      home: _sourcePage(),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 必须自己抢前台：窗口在后台时 DWM 不合成，FrameTiming 会给出
  // 0.3ms 这种「好看但没意义」的数字
  await windowManager.ensureInitialized();
  const WindowOptions options = WindowOptions(
    size: Size(900, 700),
    center: true,
    title: 'hero-flight-bench',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(true);
  });
  runApp(const _Bench());
}

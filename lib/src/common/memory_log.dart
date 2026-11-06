import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:window_manager/window_manager.dart';

import '../features/player/cover_palette.dart';
import '../features/player/cover_spin.dart';

/// 内存日志：默认关闭，`--dart-define=LAMP_MEM_LOG=true` 才打印。
///
/// 只打**可归因**的那几项：图片缓存持有多少张解码后的位图、共多少字节，
/// 配色 LRU 有多少条。进程工作集要用外部工具看（Windows 上
/// `Get-Process lamp_player` 的 `WorkingSet64`），这里不做 FFI。
///
/// 判断口径：如果「图片缓存」这一项随时间涨到接近上限（见
/// `image_cache_config.dart` 的 40MB）并稳定在那里，那涨的内存就是它；
/// 如果它一直很小而工作集还在涨，那要去查 Rust / GPU 侧。
const bool memoryLogEnabled =
    String.fromEnvironment('LAMP_MEM_LOG') == 'true' ||
    String.fromEnvironment('LAMP_MEM_LOG') == '1';

/// 每隔多久打一行
const Duration _interval = Duration(seconds: 5);

Timer? _timer;

/// 启动内存日志（已启动则不重复）
void startMemoryLog() {
  if (!memoryLogEnabled || _timer != null) {
    return;
  }
  // 量的时候窗口必须在前台：被遮住 / 最小化的窗口会被系统裁工作集，
  // 数字偏低，据此下结论会跑偏（跟 `tool/hero_flight_bench.dart` 同一个坑）
  unawaited(_keepForeground());
  _timer = Timer.periodic(_interval, (_) => printMemory('定期'));
}

Future<void> _keepForeground() async {
  try {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(true);
  } catch (error) {
    debugPrint('内存日志：拉前台失败（$error）');
  }
}

void stopMemoryLog() {
  _timer?.cancel();
  _timer = null;
  unawaited(windowManager.setAlwaysOnTop(false));
}

/// 打一行；[tag] 用来说明「什么时候」量的
void printMemory(String tag) {
  if (!memoryLogEnabled) {
    return;
  }
  final ImageCache cache = PaintingBinding.instance.imageCache;
  final double mb = cache.currentSizeBytes / (1024 * 1024);
  // 进程 RSS：跟任务管理器看到的是同一个数（工作集），省得再开外部工具
  final double rss = ProcessInfo.currentRss / (1024 * 1024);
  debugPrint(
    '[mem] $tag｜RSS ${rss.toStringAsFixed(1)}MB'
    '｜图片缓存 ${cache.currentSize} 张 / ${mb.toStringAsFixed(1)}MB'
    '（上限 ${cache.maximumSize} 张 / '
    '${(cache.maximumSizeBytes / (1024 * 1024)).toStringAsFixed(0)}MB，'
    '活在用 ${cache.liveImageCount} 张）'
    '｜配色 ${CoverPaletteCache.length} 条'
    // 转场 / 开关页面之后 CPU 下不去时先看这一项：还在「60fps」说明
    // 有个来源没被撤掉，时钟一直以 16ms 跑
    '｜旋转 ${CoverSpin.debugTicking ? '60fps' : '停'}（来源 ${CoverSpin.debugOwners}）',
  );
}

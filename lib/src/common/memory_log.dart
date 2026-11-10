import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../features/player/cover_palette.dart';
import '../features/player/cover_spin.dart';

/// 内存日志：默认关闭。两种打开方式：
///
/// - 编译时：`--dart-define=LAMP_MEM_LOG=true`
/// - **运行时**：环境变量 `LAMP_MEM_LOG=1`（release 包也能用）
///
/// 打出来的内容只挑**可归因**的那几项：进程 RSS、图片缓存持有多少张 / 多少
/// 字节 / 其中多少张是「活着」的（live image 不占缓存上限，也不会被淘汰）、
/// 配色 LRU 条数，以及各类「要开离屏图层」的 widget 有多少个。
///
/// 判断口径：
/// - 图片缓存到顶（40MB，见 `image_cache_config.dart`）但 RSS 还在涨 →
///   涨的是 live image 或引擎侧的东西；
/// - `图片缓存` 很小、图层数却很多 → 涨的是离屏图层 / 光栅缓存；
/// - 两者都很小 RSS 还是高 → 去查 Rust / GPU 驱动侧。
///
/// 运行时打开还会额外写一份 `%TEMP%\lamp-player-mem.log`：Windows 的 GUI 程序
/// 没有控制台，release 下 `debugPrint` 是看不见的，只有落文件才能事后翻。
final bool memoryLogEnabled = _memoryLogRequested();

bool _memoryLogRequested() {
  const String compiled = String.fromEnvironment('LAMP_MEM_LOG');
  if (compiled == 'true' || compiled == '1') {
    return true;
  }
  final String? runtime = Platform.environment['LAMP_MEM_LOG'];
  return runtime == 'true' || runtime == '1';
}

/// 日志落盘的位置；只在 [memoryLogEnabled] 时用到
String get memoryLogPath => _logPath;
final String _logPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}lamp-player-mem.log';

void _emit(String line) {
  debugPrint(line);
  try {
    File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append);
  } catch (_) {
    // 临时目录不可写：只留控制台输出，不影响功能
  }
}

/// 采样间隔。
///
/// 5 秒一次的采样抓不到几百毫秒的尖刺（上一轮就是这样漏掉的），改成 1 秒：
/// 读一次 `ProcessInfo.currentRss` 只是一次 syscall，开销可以忽略。为避免刷屏，
/// 正常情况仍然每 5 秒才打一行，突增则立刻单独打一条。
const Duration _interval = Duration(seconds: 1);

/// 每几拍打一行常规日志
const int _printEvery = 5;

/// 一次采样涨这么多就算「突增」：正常波动是几十 MB 级
const int _spikeBytes = 300 << 20;

Timer? _timer;
int _ticks = 0;
int _lastRssBytes = 0;

/// 启动内存日志（已启动则不重复）
void startMemoryLog() {
  if (!memoryLogEnabled || _timer != null) {
    return;
  }
  // 量的时候窗口必须在前台：被遮住 / 最小化的窗口会被系统裁工作集，
  // 数字偏低，据此下结论会跑偏（跟 `tool/hero_flight_bench.dart` 同一个坑）
  unawaited(_keepForeground());
  _lastRssBytes = ProcessInfo.currentRss;
  // 每次启动重写：只留这一次会话，免得旧日志越攒越大、翻的时候还得找
  try {
    File(_logPath).writeAsStringSync('');
  } catch (_) {
    // 写不了就算了，下面每行也会再试一次
  }
  _emit('[mem] 开始记录，落盘到 $_logPath');
  _timer = Timer.periodic(_interval, (_) => _tick());
}

void _tick() {
  final int rss = ProcessInfo.currentRss;
  final int jump = rss - _lastRssBytes;
  _lastRssBytes = rss;
  if (jump >= _spikeBytes) {
    _emit(
      '[mem] 突增 +${(jump / (1024 * 1024)).toStringAsFixed(0)}MB'
      '（现在 ${(rss / (1024 * 1024)).toStringAsFixed(0)}MB）',
    );
  }
  _ticks += 1;
  if (_ticks % _printEvery == 0) {
    printMemory('定期');
  }
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
  _emit(
    '[mem] $tag｜RSS ${rss.toStringAsFixed(1)}MB'
    '｜图片缓存 ${cache.currentSize} 张 / ${mb.toStringAsFixed(1)}MB'
    '（上限 ${cache.maximumSize} 张 / '
    '${(cache.maximumSizeBytes / (1024 * 1024)).toStringAsFixed(0)}MB，'
    '活在用 ${cache.liveImageCount} 张）'
    '｜配色 ${CoverPaletteCache.length} 条'
    // 转场 / 开关页面之后 CPU 下不去时先看这一项：还在「60fps」说明
    // 有个来源没被撤掉，时钟一直以 16ms 跑
    '｜旋转 ${CoverSpin.debugTicking ? '60fps' : '停'}（来源 ${CoverSpin.debugOwners}）'
    '｜${_widgetStats()}',
  );
}

/// 数一数那些「要开离屏图层 / 要逐帧重绘」的 widget 有多少个。
///
/// 只看数量就够定位了：内存涨而 `图片缓存` 不动时，先看是不是图层类的
/// widget 变多了（每个 [ImageFiltered] / [ShaderMask] 都是一次 saveLayer，
/// 每个 [Opacity] 不到 1 时也是）。
String _widgetStats() {
  int blur = 0;
  int mask = 0;
  int fade = 0;
  int transform = 0;
  int boundary = 0;

  void walk(Element element) {
    final Widget widget = element.widget;
    if (widget is ImageFiltered) {
      blur += 1;
    } else if (widget is ShaderMask) {
      mask += 1;
    } else if (widget is Opacity) {
      fade += 1;
    } else if (widget is Transform) {
      transform += 1;
    } else if (widget is RepaintBoundary) {
      boundary += 1;
    }
    element.visitChildren(walk);
  }

  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return '控件 树未建';
  }
  walk(root);
  return '控件 模糊 $blur / 遮罩 $mask / 半透明 $fade / 变换 $transform / 边界 $boundary';
}

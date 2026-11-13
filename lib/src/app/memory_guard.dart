import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:window_manager/window_manager.dart';

import '../common/memory_log.dart';
import '../common/paint_cache.dart';
import 'image_cache_config.dart';
import 'memory_trim.dart';

/// 常驻内存看门：RSS 超过阈值就把「用不着的那部分」交还系统。
///
/// 为什么需要它：换歌、进出播放页、翻曲库都会让堆的高水位一段段抬上去
/// （实测每次换歌 +5~15MB，其中大头是封面解码和那一次整页重绘的瞬时峰值），
/// 而 Windows 不会因为「这些页已经没人碰了」就自动把它们从工作集里收走，
/// 于是任务管理器里就一路涨到 300MB+。这跟「对象泄漏」是两件事——
/// 该回收的都回收了，只是进程没把空页还回去。
///
/// 做法：每 [interval] 看一次 RSS，超阈值就
/// 1. 清掉图片缓存里「没人用但留着下次快」的那部分（`clear()`，不动正在显示的）；
/// 2. 清掉模糊用的 ImageFilter 缓存；
/// 3. `SetProcessWorkingSetSize(-1,-1)` 让系统把空闲页换出。
///
/// 阈值取「前台 230MB / 不可见 150MB」：前台太激进会让
/// 刚清掉的封面立刻又被解回来，反而多一轮磁盘 IO；不可见时没人看画面，
/// 可以连 live image 一起放掉（[trimImageCache] 就是这么做的）。
///
/// 只在 Windows 桌面有意义；其它平台 `trimWorkingSet()` 自己是空操作。
class MemoryGuard {
  MemoryGuard._();

  /// 检查间隔。
  ///
  /// 太短会频繁换页（每换一次都要重新读盘），太长则阈值形同虚设：换歌那一刻
  /// 抬上去的 5~15MB 得等满一个周期才被按回去。60 秒是折中——正常使用时
  /// 峰值撑不到阈值，超了也能在半分钟内收掉。
  static const Duration interval = Duration(seconds: 60);

  /// 前台阈值：超过就修剪
  static const int visibleLimitBytes = 230 << 20;

  /// 不可见（最小化 / 在托盘）阈值：更低，因为重新读页的代价没人感知
  static const int hiddenLimitBytes = 150 << 20;

  static Timer? _timer;

  /// 额外的一次性检查（换歌、退出播放页之后用）
  static Timer? _soon;

  /// 启动看门（重复调用无副作用）
  static void start() {
    if (_timer != null) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  /// 停止看门（测试与退出时用）
  static void stop() {
    _timer?.cancel();
    _timer = null;
    _soon?.cancel();
    _soon = null;
  }

  /// 在 [delay] 之后补查一次。
  ///
  /// 常规检查是每 [interval] 一次，抓不住「换歌那一刻」的峰值：新封面刚解完、
  /// 整页刚画完，RSS 正好在这几百毫秒里跳到最高，然后要等下一个周期才被处理。
  /// 这个接口就是给这种**有明确结束时点**的操作补一刀。连发多次只保留最后一次。
  ///
  /// 看门没启动时直接返回：那说明这个进程里根本不需要修剪（widget 测试、
  /// 非桌面平台），排一个没人收的定时器只会让测试报
  /// 「A Timer is still pending even after the widget tree was disposed」。
  static void checkSoon({Duration delay = const Duration(seconds: 3)}) {
    if (_timer == null) {
      return;
    }
    _soon?.cancel();
    _soon = Timer(delay, () {
      _soon = null;
      unawaited(_tick());
    });
  }

  /// 当前 RSS 是否已经超过该状态下的阈值
  @visibleForTesting
  static bool overLimit(int rssBytes, {required bool visible}) =>
      rssBytes >= (visible ? visibleLimitBytes : hiddenLimitBytes);

  static Future<void> _tick() async {
    try {
      final bool visible = await _isVisible();
      final int rss = ProcessInfo.currentRss;
      if (!overLimit(rss, visible: visible)) {
        return;
      }
      final int before = rss;
      trimCaches(keepLiveImages: visible);
      trimWorkingSet();
      if (memoryLogEnabled) {
        final ImageCache cache = PaintingBinding.instance.imageCache;
        printMemory(
          '修剪（${visible ? '前台' : '不可见'}，触发 '
          '${(before / (1024 * 1024)).toStringAsFixed(0)}MB，'
          '图片缓存剩 ${(cache.currentSizeBytes / (1024 * 1024)).toStringAsFixed(1)}MB）',
        );
      }
    } catch (error) {
      // 看门本身不能影响任何正常流程
      debugPrint('内存看门失败：$error');
    }
  }

  /// 清缓存；[keepLiveImages] 为 false 时连正在显示的图片一起放掉
  @visibleForTesting
  static void trimCaches({required bool keepLiveImages}) {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    if (keepLiveImages) {
      // 只清「没人用、留着下次快」的那部分。可见时清 live image 会让正在
      // 显示的封面在下一帧重新解码，用户能感觉到一次轻微卡顿
      cache.clear();
    } else {
      trimImageCache();
    }
    ImageFilterCache.clear();
  }

  static Future<bool> _isVisible() async {
    try {
      final bool minimized = await windowManager.isMinimized();
      if (minimized) {
        return false;
      }
      // 关到托盘时 isMinimized 仍是 false，必须再看 isVisible
      return await windowManager.isVisible();
    } catch (_) {
      // 查不到就当可见：宁可少修剪，也不要误判成「没人看」而清 live image
      return true;
    }
  }
}

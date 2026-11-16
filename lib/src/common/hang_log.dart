import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 「用一会儿就无响应 / 闪退」的现场记录。
///
/// 这类故障事后什么都没留下：Windows 的事件日志里没有 lamp_player 的崩溃记录，
/// `%TEMP%` 里也没有 dmp，于是每轮只能靠猜。这个日志的作用就是让下一次复现
/// **自己留下证据**：
///
/// - 每个动作前打一行 `[do]`，卡在哪个动作里一目了然（最后一行就是它）；
/// - 每秒一次心跳，UI 线程被同步调用 / 死循环占住时心跳会断，恢复后补一条
///   `[gap]`，把「卡了多久」写成数字；
/// - 每 10 秒一条 `[tick]`（带 RSS），用来判断「是界面卡了」还是「进程一直在跑」；
/// - Dart 侧未捕获异常、超长帧也各记一条，闪退前若抛过异常就能对上。
///
/// 落盘到 `%TEMP%\lamp-player-hang.log`（每次启动把上一轮改名成
/// `lamp-player-hang.prev.log`，所以崩溃后重启仍能看到上一轮的尾巴）。
/// 一次会话大约 1KB/分钟，长期开着没有负担。
String get hangLogPath =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}lamp-player-hang.log';

String get _prevLogPath =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'lamp-player-hang.prev.log';

Timer? _heartbeat;
DateTime? _lastBeat;
String? _lastMark;
DateTime? _lastMarkAt;
int _ticks = 0;
bool _started = false;
bool _rotated = false;

/// 上一帧到现在超过这个间隔就算「UI 线程被占住了」
const Duration _blockThreshold = Duration(seconds: 2);

/// 超过这么长的单帧单独记一条
const Duration _longFrame = Duration(milliseconds: 300);

/// 同样的动作在这个窗口内只记一次（滚动 / 拖动会按帧调进来）
const Duration _dedupe = Duration(milliseconds: 500);

/// 启动现场日志（已启动则跳过）。要在 `runApp` 之前调用。
void startHangLog() {
  if (_started) {
    return;
  }
  _started = true;
  _rotate();
  _installErrorHooks();
  _write('boot', '记录开始 pid=$pid');
  _lastBeat = DateTime.now();
  _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => _beat());
}

/// 退出前收尾（进程要没了，留着定时器没有意义）
void stopHangLog() {
  _heartbeat?.cancel();
  _heartbeat = null;
  if (_started) {
    _write('boot', '记录结束');
  }
  _started = false;
  try {
    _sink?.closeSync();
  } catch (_) {
    // 已经关掉 / 没打开过：忽略
  }
  _sink = null;
}

/// 记一条「正要做什么」。卡死之后看最后一行即知卡在哪一步。
///
/// 未调用 [startHangLog] 时是空操作：widget 测试里不会往用户的临时目录写东西。
void hangMark(String what) {
  if (!_started) {
    return;
  }
  final DateTime now = DateTime.now();
  final DateTime? lastAt = _lastMarkAt;
  if (_lastMark == what && lastAt != null && now.difference(lastAt) < _dedupe) {
    return;
  }
  _lastMark = what;
  _lastMarkAt = now;
  _write('do', what);
}

void _beat() {
  final DateTime now = DateTime.now();
  final DateTime? last = _lastBeat;
  _lastBeat = now;
  if (last != null) {
    final Duration gap = now.difference(last);
    if (gap > _blockThreshold) {
      _write(
        'gap',
        'UI 线程被占住 ${(gap.inMilliseconds / 1000).toStringAsFixed(1)}s，'
            '期间最后动作：${_lastMark ?? '无'}',
      );
    }
  }
  _ticks += 1;
  if (_ticks % 10 == 0) {
    final double rss = ProcessInfo.currentRss / (1024 * 1024);
    _write('tick', 'RSS ${rss.toStringAsFixed(0)}MB｜最后动作：${_lastMark ?? '无'}');
  }
}

void _installErrorHooks() {
  // 帧耗时：长帧说明 UI 线程在被算力吃掉（不是同步阻塞），两者要能区分开
  try {
    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
      for (final FrameTiming timing in timings) {
        final Duration total = timing.totalSpan;
        if (total > _longFrame) {
          _write(
            'frame',
            '长帧 ${total.inMilliseconds}ms'
                '（build ${timing.buildDuration.inMilliseconds}ms / '
                'raster ${timing.rasterDuration.inMilliseconds}ms）',
          );
        }
      }
    });
  } catch (error) {
    _write('boot', '帧耗时的回调没装上：$error');
  }

  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _write('err', '${details.exceptionAsString()}\n${details.stack}');
    previous?.call(details);
  };
  // 异步未捕获异常：debug 下会打到控制台，release 下本来没人看，落到文件里
  //
  // 链到已有的 handler 而不是直接吞掉：`PlatformDispatcher.onError` 是全局单槽，
  // 覆盖掉别人装的钩子会让那边的错误上报静默失效。
  final ErrorCallback? previousAsync = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _write('err', '未捕获 $error\n$stack');
    return previousAsync?.call(error, stack) ?? true;
  };
}

void _rotate() {
  if (_rotated) {
    return;
  }
  _rotated = true;
  try {
    final File log = File(hangLogPath);
    if (log.existsSync()) {
      log.copySync(_prevLogPath);
      log.writeAsStringSync('');
    }
  } catch (_) {
    // 临时目录不可写：只是没有现场记录，功能照旧
  }
}

/// 常开的追加句柄：每秒一次心跳若每次开 / 关文件，Defender 实时扫描下会偶发
/// 毫秒级阻塞，直接掉一帧。句柄泄漏没有风险——进程退出由系统回收。
RandomAccessFile? _sink;

void _write(String tag, String message) {
  final DateTime now = DateTime.now();
  final String stamp =
      '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}.'
      '${now.millisecond.toString().padLeft(3, '0')}';
  final String line = '$stamp [$tag] $message\n';
  try {
    // 同步写：卡死前那一行必须先落盘，异步缓冲正好会丢掉最关键的尾巴
    final RandomAccessFile sink = _sink ??= File(hangLogPath)
        .openSync(mode: FileMode.append);
    sink.writeStringSync(line);
    sink.flushSync();
  } catch (_) {
    // 写不进去就只留控制台
    debugPrint(line);
  }
}

@visibleForTesting
bool get hangLogStarted => _started;

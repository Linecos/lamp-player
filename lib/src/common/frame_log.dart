import 'dart:developer' as developer;
import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

/// 掉帧日志：默认关闭，`--dart-define=LAMP_FRAME_LOG=true` 才打印。
///
/// 每个超过阈值的长帧打一行，把 build / raster 分开报：这两个数的含义完全
/// 不同——build 高是「这一帧要重建的 widget 太多」，raster 高是「GPU 要画的
/// 像素 / 图层太多」。转场、滚动这类"看起来卡一下"的问题，先看这一行就能知道
/// 该往哪边修，不用猜。
///
/// 只打长帧：正常帧一律不输出，免得把控制台刷满。
const bool frameLogEnabled =
    String.fromEnvironment('LAMP_FRAME_LOG') == 'true' ||
    String.fromEnvironment('LAMP_FRAME_LOG') == '1';

/// 超过这个时长就算"掉了一帧"。桌面 60Hz 的一帧预算 16.7ms，留一点余量
const Duration _longFrameThreshold = Duration(milliseconds: 20);

/// 连续长帧之间最多打多少条（按时间窗去重，避免一次卡顿刷几十行）
const int _maxPerBurst = 12;

Duration _lastReport = Duration.zero;
int _burstCount = 0;

bool _started = false;

/// 启动掉帧日志（重复调用无副作用）
void startFrameLog() {
  if (!frameLogEnabled || _started) {
    return;
  }
  _started = true;
  SchedulerBinding.instance.addTimingsCallback(_onTimings);
}

void _onTimings(List<FrameTiming> timings) {
  for (final FrameTiming timing in timings) {
    final Duration total = timing.totalSpan;
    if (total < _longFrameThreshold) {
      _burstCount = 0;
      continue;
    }
    // 一次卡顿往往连着好几帧都长，只报前几条
    final bool sameBurst =
        timing.timestampInMicroseconds(FramePhase.vsyncStart) -
            _lastReport.inMicroseconds <
        300000;
    if (sameBurst && _burstCount >= _maxPerBurst) {
      continue;
    }
    _burstCount = sameBurst ? _burstCount + 1 : 1;
    _lastReport = Duration(
      microseconds: timing.timestampInMicroseconds(FramePhase.vsyncStart),
    );

    final Duration build = timing.buildDuration;
    final Duration raster = timing.rasterDuration;
    final String hint = build > raster ? '构建' : '渲染';
    developer.log(
      '长帧 ${total.inMicroseconds / 1000} ms'
      '（build ${build.inMicroseconds / 1000}'
      ' / raster ${raster.inMicroseconds / 1000}）→ 偏向$hint',
      name: 'lamp.frame',
    );
  }
}

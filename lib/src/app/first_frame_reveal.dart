import 'dart:async';

import 'package:flutter/foundation.dart';

/// 等首帧光栅化以后再显示窗口。
///
/// 窗口在首帧之前是可画的：`show()` 一调，DWM 就会把还没上屏的交换链 / 系统底色
/// 铺出来，也就是启动时那一下白。所以显示动作必须挂在
/// `WidgetsBinding.waitUntilFirstFrameRasterized` 后面。
///
/// 超时兜底：窗口不可见时引擎不保证照常出帧（没有呈现目标、vsync 也可能不投递），
/// 一直等下去就成了「程序启动了但窗口不出现」。宁可早一点露出来，也要有一个上限。
Future<void> revealOnFirstFrame(
  Future<void> firstFrameRasterized, {
  required Future<void> Function() onRasterized,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  try {
    await firstFrameRasterized.timeout(timeout);
  } catch (error) {
    // 超时或引擎侧异常都继续往下走：显示窗口比「等一个完美的首帧」重要
    debugPrint('等待首帧光栅化未完成（继续显示窗口）：$error');
  }
  try {
    await onRasterized();
  } catch (error) {
    debugPrint('显示窗口失败：$error');
  }
}

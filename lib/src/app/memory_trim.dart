import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 把进程的物理内存尽量交还系统（Windows `SetProcessWorkingSetSize(-1,-1)`）。
///
/// 它不释放任何东西，只是让系统把「最近没人碰」的页换出到页面文件——任务管理器
/// 里的内存数字会立刻降下来，真正访问时再换回来。所以调用时机必须是
/// **界面不可见且会持续一阵子**（关到托盘 / 最小化）：可见时调它只会让下一帧
/// 把刚换出的页又读回来，白白多一轮磁盘 IO。
///
/// 失败（非 Windows、kernel32 里没有这个函数）时静默跳过——这只是锦上添花的
/// 优化，不能影响任何正常流程。
void trimWorkingSet() {
  final _SetProcessWorkingSetSizeDart? setWorkingSet =
      _setProcessWorkingSetSize;
  if (setWorkingSet == null) {
    return;
  }
  try {
    // 两个 SIZE_T 都传 -1：让系统自己决定把工作集收到多小
    if (setWorkingSet(_currentProcess, -1, -1) == 0) {
      debugPrint('交还工作集失败（SetProcessWorkingSetSize 返回 0）');
    }
  } catch (error) {
    debugPrint('交还工作集失败：$error');
  }
}

/// `GetCurrentProcess()` 的伪句柄恒为 -1，不必真的跨 FFI 去取
const int _currentProcess = -1;

typedef _SetProcessWorkingSetSizeNative = Int32 Function(
  IntPtr process,
  IntPtr minBytes,
  IntPtr maxBytes,
);
typedef _SetProcessWorkingSetSizeDart = int Function(
  int process,
  int minBytes,
  int maxBytes,
);

_SetProcessWorkingSetSizeDart? _lookup() {
  if (!Platform.isWindows) {
    return null;
  }
  try {
    return DynamicLibrary.open('kernel32.dll').lookupFunction<
      _SetProcessWorkingSetSizeNative,
      _SetProcessWorkingSetSizeDart
    >('SetProcessWorkingSetSize');
  } catch (error) {
    debugPrint('找不到 SetProcessWorkingSetSize：$error');
    return null;
  }
}

/// 首次用到时才去查符号（顶层 final 是惰性求值，测试环境也不会白开 DLL）
final _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize = _lookup();

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Offset, Rect;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 判断主窗口是不是「整个被别的窗口盖住」。
///
/// 为什么需要它：窗口失焦不等于看不见。最常见的用法是把正在播放页当**全屏
/// 背景**铺在底下，前面开个小窗口干活——这时封面该转、频谱该跳，一点没少。
/// 只看焦点就停动画，画面会僵在那里，很难看。真正该省电的是「放大一个别的
/// 窗口把播放器整个盖住」，那会儿没人看得见，却照样在出帧、照样把页读回
/// 工作集。
///
/// Windows 没有遮挡通知，只能自己数：`EnumWindows` 按 Z 序从顶到底给窗口，
/// 走到自己这个窗口为止，上面那些可见、没最小化、不是工具/透明图层的矩形就是
/// 遮挡物；再在窗口里撒一层采样点，全部落在遮挡物里才算盖死。
///
/// 非 Windows、查不到符号、任何异常：一律当作「没被盖住」——宁可多转几帧，
/// 也不能因为一个判断失误把画面冻在用户眼前。
bool isWindowFullyCovered() => probeOcclusion().covered;

/// 一次探测的完整结果，排查用（`LAMP_MEM_LOG` 会打出来）。
///
/// 只看 `covered` 分不清「没被盖住」和「根本没查出结果」：符号没找到、没找到
/// 自己的主窗口、枚举到一半失败都会是 false。带上这几项就能一眼定位。
class OcclusionProbe {
  const OcclusionProbe({
    required this.covered,
    required this.above,
    required this.foundSelf,
    required this.failed,
  });

  /// 是否判定为被盖住
  final bool covered;

  /// 自己上面（Z 序更高）收集到几个遮挡矩形
  final int above;

  /// 是否找到了自己的主窗口
  final bool foundSelf;

  /// 探测本身有没有出错（非 Windows / 符号缺失 / 异常）
  final bool failed;

  String get debugLabel =>
      '${covered ? '是' : '否'}（上 $above 个、自己 ${foundSelf ? '找到' : '没找到'}'
      '${failed ? '、探测失败' : ''}）';
}

OcclusionProbe probeOcclusion() {
  final _Win32? api = _win32;
  if (api == null) {
    return const OcclusionProbe(
      covered: false,
      above: 0,
      foundSelf: false,
      failed: true,
    );
  }
  try {
    return api.covered();
  } catch (error) {
    debugPrint('遮挡检测失败：$error');
    return const OcclusionProbe(
      covered: false,
      above: 0,
      foundSelf: false,
      failed: true,
    );
  }
}

/// 采样网格（每边几个点）：25 个点足够判断「盖没盖死」，又不用做并集几何。
///
/// 用采样而不是精确的面积并集：遮挡物最多十来个矩形，精确算法要扫描线，
/// 收益是把「漏掉一条 1px 缝」也算出来——那种情况用户本来就几乎看不出来。
@visibleForTesting
const int occlusionGrid = 5;

/// [target] 是否被 [covers] 完全盖住（全部采样点都落在某个遮挡矩形里）。
@visibleForTesting
bool isRectCovered(Rect target, List<Rect> covers) {
  if (target.isEmpty) {
    return false;
  }
  for (int i = 0; i < occlusionGrid; i += 1) {
    final double x = target.left + (i + 0.5) * target.width / occlusionGrid;
    for (int j = 0; j < occlusionGrid; j += 1) {
      final Offset point = Offset(
        x,
        target.top + (j + 0.5) * target.height / occlusionGrid,
      );
      bool covered = false;
      for (final Rect cover in covers) {
        if (cover.contains(point)) {
          covered = true;
          break;
        }
      }
      if (!covered) {
        return false;
      }
    }
  }
  return true;
}

final _Win32? _win32 = _Win32.lookup();

/// 用到的那几个 user32 符号；非 Windows 或查找失败时为 null
class _Win32 {
  _Win32._(
    this._enumWindows,
    this._isWindowVisible,
    this._isIconic,
    this._getWindowRect,
    this._windowPid,
    this._currentPid,
    this._windowStyle,
  );

  static _Win32? lookup() {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      return _Win32._(
        user32.lookupFunction<_EnumWindowsNative, _EnumWindowsDart>(
          'EnumWindows',
        ),
        user32.lookupFunction<_BoolIntPtrNative, _BoolIntPtrDart>(
          'IsWindowVisible',
        ),
        user32.lookupFunction<_BoolIntPtrNative, _BoolIntPtrDart>('IsIconic'),
        user32.lookupFunction<_GetWindowRectNative, _GetWindowRectDart>(
          'GetWindowRect',
        ),
        user32.lookupFunction<_WindowPidNative, _WindowPidDart>(
          'GetWindowThreadProcessId',
        ),
        kernel32.lookupFunction<_VoidUintNative, _VoidUintDart>(
          'GetCurrentProcessId',
        ),
        user32.lookupFunction<_WindowStyleNative, _WindowStyleDart>(
          'GetWindowLongPtrW',
        ),
      );
    } catch (error) {
      debugPrint('遮挡检测：找不到 user32 符号（$error）');
      return null;
    }
  }

  final _EnumWindowsDart _enumWindows;
  final _BoolIntPtrDart _isWindowVisible;
  final _BoolIntPtrDart _isIconic;
  final _GetWindowRectDart _getWindowRect;
  final _WindowPidDart _windowPid;
  final _VoidUintDart _currentPid;
  final _WindowStyleDart _windowStyle;

  /// 从 Z 序顶部往下收集遮挡物，遇到自己的主窗口就停
  OcclusionProbe covered() {
    final List<Rect> above = <Rect>[];
    Rect? self;
    final int pid = _currentPid();
    // isolateLocal：回调跑在同一个 isolate 里，可以直接碰 Dart 对象
    final NativeCallable<_EnumWindowsProcNative> callback =
        NativeCallable<_EnumWindowsProcNative>.isolateLocal((int hwnd, int _) {
          final bool mine = _pidOf(hwnd) == pid;
          if (mine) {
            // 自己的辅助窗口（宿主、托盘隐藏窗）跳过，主窗口取第一个可见的
            if (_isWindowVisible(hwnd) != 0 && _isIconic(hwnd) == 0) {
              self = _rectOf(hwnd);
              return 0; // 下面（更靠后）的窗口都不可能盖住自己
            }
            return 1;
          }
          if (_isWindowVisible(hwnd) == 0 || _isIconic(hwnd) != 0) {
            return 1;
          }
          // 工具窗（提示框 / 输入法候选）与点击穿透层不算遮挡
          final int style = _windowStyle(hwnd, _gwlExStyle);
          if (style & _wsExToolWindow != 0 || style & _wsExTransparent != 0) {
            return 1;
          }
          final Rect? rect = _rectOf(hwnd);
          if (rect != null && rect.width > 1 && rect.height > 1) {
            above.add(rect);
          }
          return 1;
        }, exceptionalReturn: 0);
    try {
      // lParam 不传值：回调里直接闭包捕获取要的东西
      _enumWindows(callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    final Rect? target = self;
    if (target == null) {
      return OcclusionProbe(
        covered: false,
        above: above.length,
        foundSelf: false,
        failed: false,
      );
    }
    return OcclusionProbe(
      covered: isRectCovered(target, above),
      above: above.length,
      foundSelf: true,
      failed: false,
    );
  }

  int _pidOf(int hwnd) {
    final Pointer<Uint32> pid = calloc<Uint32>();
    try {
      _windowPid(hwnd, pid);
      return pid.value;
    } finally {
      calloc.free(pid);
    }
  }

  Rect? _rectOf(int hwnd) {
    final Pointer<_Rect> rect = calloc<_Rect>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) {
        return null;
      }
      final int left = rect.ref.left;
      final int top = rect.ref.top;
      final int right = rect.ref.right;
      final int bottom = rect.ref.bottom;
      if (right <= left || bottom <= top) {
        return null;
      }
      return Rect.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        right.toDouble(),
        bottom.toDouble(),
      );
    } finally {
      calloc.free(rect);
    }
  }
}

/// `GWL_EXSTYLE`
const int _gwlExStyle = -20;

/// 工具窗（不参与遮挡）
const int _wsExToolWindow = 0x00000080;

/// 点击穿透（覆盖层 / 水印）
const int _wsExTransparent = 0x00000020;

final class _Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lParam);

typedef _EnumWindowsNative = Int32 Function(
  Pointer<NativeFunction<_EnumWindowsProcNative>> callback,
  IntPtr lParam,
);
typedef _EnumWindowsDart = int Function(
  Pointer<NativeFunction<_EnumWindowsProcNative>> callback,
  int lParam,
);

typedef _BoolIntPtrNative = Int32 Function(IntPtr hwnd);
typedef _BoolIntPtrDart = int Function(int hwnd);

typedef _GetWindowRectNative = Int32 Function(IntPtr hwnd, Pointer<_Rect> rect);
typedef _GetWindowRectDart = int Function(int hwnd, Pointer<_Rect> rect);

typedef _WindowPidNative = Uint32 Function(IntPtr hwnd, Pointer<Uint32> pid);
typedef _WindowPidDart = int Function(int hwnd, Pointer<Uint32> pid);

typedef _VoidUintNative = Uint32 Function();
typedef _VoidUintDart = int Function();

typedef _WindowStyleNative = IntPtr Function(IntPtr hwnd, Int32 index);
typedef _WindowStyleDart = int Function(int hwnd, int index);

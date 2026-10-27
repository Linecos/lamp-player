import 'package:flutter/widgets.dart';

/// 沉浸模式开关。
///
/// 窗口按钮画在 `MaterialApp.builder` 里的 `WindowChrome` 中、位于路由之上，
/// 页面拿不到它，只能靠这个开关联动：进入沉浸时置 `true`，退出或页面销毁时复位。
final ValueNotifier<bool> immersiveMode = ValueNotifier<bool>(false);

/// 指针是否停在窗口顶部。
///
/// 沉浸模式下，窗口按钮与页面顶部的返回键都靠它「鼠标靠近才渐显」。
final ValueNotifier<bool> pointerNearTop = ValueNotifier<bool>(false);

/// 顶部感应带的高度：指针进入这条带子就算「靠近」。
const double chromeRevealBand = 72;

/// 按指针位置刷新 [pointerNearTop]；值没变就不通知，避免每帧重建浮层。
void trackPointerNearTop(Offset localPosition) {
  final bool near = localPosition.dy < chromeRevealBand;
  if (pointerNearTop.value != near) {
    pointerNearTop.value = near;
  }
}

/// 当前页面是否强制使用深色内容（例如正在播放页的固定封面背景）。
///
/// 窗口按钮画在页面之外，浅色模式下需要据此改用浅色图标。
final ValueNotifier<bool> forceLightWindowControls = ValueNotifier<bool>(false);

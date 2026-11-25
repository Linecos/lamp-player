import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 任务栏缩略图工具栏上的三枚按钮
enum TaskbarButtonAction { prev, toggle, next }

/// 任务栏缩略图工具栏：鼠标悬停任务栏图标时浮出的 上一首 / 播放暂停 / 下一首。
///
/// 原生侧（`windows/runner/taskbar_manager.cpp`）走 `ITaskbarList3` 注册按钮，
/// 点击经 MethodChannel 回来；[setButtons] 把播放状态推回去换字形。
///
/// 非 Windows、或原生侧还没接上（单元测试跑在测试宿主里）时一律退化为空操作：
/// 任务栏上有没有这几枚按钮，绝不能影响播放本身。
class TaskbarThumbnail {
  TaskbarThumbnail._();

  static const MethodChannel _channel = MethodChannel('lamp_player/taskbar');

  /// 是否已经注册过回调。没注册时连调用都不发，免得测试里每次都去撞
  /// `MissingPluginException`
  static bool _installed = false;

  /// 注册点击回调；重复调用无副作用（后注册的覆盖前一个）。
  static void init({
    required void Function(TaskbarButtonAction action) onButtonClick,
  }) {
    if (!Platform.isWindows) {
      return;
    }
    _installed = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onButtonClick') {
        return;
      }
      switch (call.arguments) {
        case 'prev':
          onButtonClick(TaskbarButtonAction.prev);
        case 'toggle':
          onButtonClick(TaskbarButtonAction.toggle);
        case 'next':
          onButtonClick(TaskbarButtonAction.next);
      }
    });
  }

  /// 把播放状态推给原生侧。
  ///
  /// [isPlaying] 决定中间那枚画播放还是暂停字形；[visible] 为 false 时三枚一起
  /// 藏起来 —— 没有曲目时别留一排点了没反应的按钮。
  static Future<void> setButtons({
    required bool isPlaying,
    bool visible = true,
  }) async {
    if (!Platform.isWindows || !_installed) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setButtons', <String, Object>{
        'isPlaying': isPlaying,
        'visible': visible,
      });
    } catch (error) {
      // MissingPluginException：原生侧没接上（测试宿主 / 旧版 runner），忽略
      debugPrint('任务栏按钮同步失败：$error');
    }
  }

  /// 推当前曲目的封面：悬停看到的缩略图 / AeroPeek 预览换成这张方形封面。
  ///
  /// 传封面文件的原始字节，解码交给原生侧（GDI+）；解不出来就保持上一张。
  static Future<void> setCover(Uint8List bytes) async {
    if (!Platform.isWindows || !_installed || bytes.isEmpty) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setCover', <String, Object>{
        'bytes': bytes,
      });
    } catch (error) {
      debugPrint('任务栏封面同步失败：$error');
    }
  }

  /// 没有封面（或还没播放）时撤回自定义预览，悬停回到系统截图
  static Future<void> clearCover() async {
    if (!Platform.isWindows || !_installed) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('clearCover');
    } catch (error) {
      debugPrint('任务栏封面清理失败：$error');
    }
  }
}

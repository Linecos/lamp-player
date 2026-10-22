import 'package:window_manager/window_manager.dart';

/// 窗口控制能力。
///
/// 页面与标题栏只依赖这个接口，真实实现走 `window_manager`，
/// `test/` 下注入假实现，因此 widget 测试不需要桌面窗口插件。
abstract interface class WindowControls {
  /// 最小化窗口
  Future<void> minimize();

  /// 最大化 / 还原，返回操作后的最大化状态
  Future<bool> toggleMaximize();

  /// 当前是否最大化；平台不支持时抛错，由调用方兜底
  Future<bool> isMaximized();

  /// 关闭窗口（等价于点右上角 ×）
  Future<void> close();

  /// 开始拖动窗口（按住标题栏时调用）
  Future<void> startDragging();
}

/// 基于 `window_manager` 的实现。
///
/// 非 Windows 平台或插件未初始化时会抛错，调用方都做了兜底，
/// 因此失败只会让按钮没反应，不会崩。
class WindowManagerControls implements WindowControls {
  const WindowManagerControls();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<bool> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
      return false;
    }
    await windowManager.maximize();
    return true;
  }

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> startDragging() => windowManager.startDragging();
}

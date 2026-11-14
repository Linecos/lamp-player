import 'dart:async';

import 'package:flutter/material.dart';

import '../common/widgets/toast_pill.dart';
import '../features/library/widgets/library_rail.dart';
import '../features/player/player_bar.dart';

/// 应用内轻提示：浮在播放岛上方居中的胶囊，几秒后自己淡出。
///
/// 为什么不用 `SnackBar`：它在桌面窗口里是一条贯穿整个底边的长条，为一句
/// 「已恢复：某首歌」占满整行宽度，还压住播放岛。胶囊只占文字那么宽，位置抬到
/// 播放岛上方，视觉上不抢戏也不挡内容。
///
/// 同一时刻只留一条：后来的直接替换前一条（和 `hideCurrentSnackBar` 的语义一致），
/// 免得连续操作时排一队。
class AppToast {
  AppToast._();

  /// 没有操作按钮时的停留时间
  static const Duration defaultDuration = Duration(milliseconds: 1800);

  /// 带操作按钮时留久一点，让人来得及点
  static const Duration actionDuration = Duration(milliseconds: 4000);

  static OverlayEntry? _entry;

  /// 弹一条提示。[context] 只要有 `Overlay` 祖先即可（`MaterialApp` 里都满足）。
  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }
    final bool hasAction = actionLabel != null && onAction != null;
    hide();
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) => _ToastLayer(
        message: message,
        actionLabel: actionLabel,
        onAction: hasAction
            ? () {
                hide();
                onAction();
              }
            : null,
        hold: duration ?? (hasAction ? actionDuration : defaultDuration),
        onDismissed: hide,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 立即收起（重复调用无副作用）
  static void hide() {
    final OverlayEntry? entry = _entry;
    _entry = null;
    entry?.remove();
  }
}

/// 定位 + 进出场动画。锚点固定在播放岛上方，与提示来自哪个按钮无关。
class _ToastLayer extends StatefulWidget {
  const _ToastLayer({
    required this.message,
    required this.hold,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 淡入之后停留多久
  final Duration hold;
  final VoidCallback onDismissed;

  @override
  State<_ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<_ToastLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  /// 停留计时放在 State 里而不是静态变量：控件树销毁时能取消，不留悬挂的定时器
  /// （widget 测试结束时那句 `A Timer is still pending` 就是这么来的）
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    unawaited(_play());
  }

  Future<void> _play() async {
    await _fade.forward();
    if (!mounted) {
      return;
    }
    _hold = Timer(widget.hold, () => unawaited(_dismiss()));
  }

  Future<void> _dismiss() async {
    await _fade.reverse();
    if (!mounted) {
      return;
    }
    widget.onDismissed();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 横向定位在**主内容区**（侧栏右侧）的正中，而不是整个窗口的正中：
    // 提示基本都来自主区域的操作，落在内容区中点离触发处更近；
    // 纵向抬到播放岛上方，播放岛常驻，压在它上面会挡住进度和按钮
    return ValueListenableBuilder<bool>(
      valueListenable: LibraryRail.expandedNotifier,
      builder: (BuildContext context, bool expanded, Widget? child) {
        final double leading = expanded
            ? LibraryRail.expandedWidth
            : LibraryRail.collapsedWidth;
        return Positioned(
          left: leading,
          right: 0,
          bottom: PlayerBar.occupiedHeight + 12,
          child: child!,
        );
      },
      child: IgnorePointer(
        // 只有带按钮时才吃事件，否则鼠标穿过提示继续操作底下的界面
        ignoring: widget.onAction == null,
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 0.25),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: _fade, curve: Curves.easeOutCubic),
                  ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ToastPill(
                  message: widget.message,
                  actionLabel: widget.actionLabel,
                  onAction: widget.onAction,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

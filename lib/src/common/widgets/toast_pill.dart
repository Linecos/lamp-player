import 'package:flutter/material.dart';

/// 一句话提示的胶囊外观。
///
/// 全应用只有这一个样式：深色 `inverseSurface` 底 + 全圆角，宽度随文字走。
/// 以前用 Material 的 `SnackBar`，它在桌面窗口里是一条**贯穿整个底边的长白条**，
/// 为了一句「已恢复：某首歌」占掉整行宽度、还压住播放岛，非常显眼又挡内容。
/// 换成胶囊之后提示只占自己那点面积，位置也抬到播放岛上方。
///
/// 带操作时（例如「改完了，刷新」）右侧接一条分隔线和按钮；不带的整块都不吃
/// 指针事件，鼠标可以直接穿过它继续操作底下的界面。
class ToastPill extends StatelessWidget {
  const ToastPill({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.maxWidth = 520,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 单行提示的宽度上限：再长就折行，别横跨整个窗口
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasAction = actionLabel != null && onAction != null;

    final Widget text = Flexible(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: hasAction ? 8 : 20,
          top: 10,
          bottom: 10,
        ),
        child: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onInverseSurface,
          ),
        ),
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(20),
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            text,
            if (hasAction) ...<Widget>[
              Container(
                width: 1,
                height: 18,
                color: scheme.onInverseSurface.withValues(alpha: 0.18),
              ),
              const SizedBox(width: 4),
              _PillAction(label: actionLabel!, onPressed: onAction!),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _PillAction extends StatelessWidget {
  const _PillAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: scheme.inversePrimary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: scheme.inversePrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

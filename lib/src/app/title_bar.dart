import 'dart:async';

import 'package:flutter/material.dart';

import 'window_controls.dart';

/// 自绘的前置标题区：左上角固定显示应用名，其余为拖动区与窗口按钮。
///
/// 原生标题栏已在 `main.dart` 里通过 `TitleBarStyle.hidden` 关掉。
/// 应用名放在这里，切换页面或收起侧边栏时都不会移动。
/// 这里刻意不画分隔线，背景直接跟随页面底色，视觉上像是内容区的一部分，
/// 减少"外框感"。
///
/// - 拖动 / 双击最大化：整块空白区域（应用名也属于拖动区）
/// - 右侧三个按钮不参与拖动
class LampTitleBar extends StatefulWidget {
  const LampTitleBar({super.key, required this.controls, this.background});

  final WindowControls controls;

  /// 与页面底色保持一致；不传时用 `surfaceContainerLow`（曲库页底色）
  final Color? background;

  /// 高度；[WindowChrome] 据此预留布局
  static const double height = 36;

  @override
  State<LampTitleBar> createState() => _LampTitleBarState();
}

class _LampTitleBarState extends State<LampTitleBar> {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshMaximized());
  }

  Future<void> _refreshMaximized() async {
    try {
      final bool maximized = await widget.controls.isMaximized();
      if (!mounted || maximized == _maximized) {
        return;
      }
      setState(() => _maximized = maximized);
    } catch (_) {
      // 测试环境或平台不支持：保持默认（未最大化）
    }
  }

  Future<void> _minimize() async {
    try {
      await widget.controls.minimize();
    } catch (_) {
      // 忽略：按钮没反应比崩溃好
    }
  }

  Future<void> _toggleMaximize() async {
    try {
      final bool maximized = await widget.controls.toggleMaximize();
      if (!mounted) {
        return;
      }
      setState(() => _maximized = maximized);
    } catch (_) {
      // 同上
    }
  }

  Future<void> _close() async {
    try {
      await widget.controls.close();
    } catch (_) {
      // 同上
    }
  }

  Future<void> _startDragging() async {
    try {
      await widget.controls.startDragging();
    } catch (_) {
      // 同上
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Material(
      color: widget.background ?? scheme.surfaceContainerLow,
      child: SizedBox(
        height: LampTitleBar.height,
        child: Row(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                key: const ValueKey<String>('window-drag-area'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => unawaited(_startDragging()),
                onDoubleTap: () => unawaited(_toggleMaximize()),
                child: Semantics(
                  label: 'Lamp Player 标题栏（可拖动）',
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ExcludeSemantics(
                        child: Text(
                          'Lamp Player',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-minimize'),
              icon: Icons.remove,
              label: '最小化',
              onTap: () => unawaited(_minimize()),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-maximize'),
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              label: _maximized ? '还原' : '最大化',
              iconSize: 13,
              onTap: () => unawaited(_toggleMaximize()),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-close'),
              icon: Icons.close,
              label: '关闭',
              danger: true,
              onTap: () => unawaited(_close()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Windows 风格窗口按钮：默认透明，悬停时高亮；关闭键悬停变红底白字。
///
/// 这里刻意不用 `Tooltip`：标题栏挂在 `MaterialApp.builder` 上，位于
/// Navigator 的 `Overlay` 之上，而 `Tooltip` 强依赖 Overlay 祖先。
/// 原生 Windows 标题栏按钮同样不弹提示，所以只保留语义标签给读屏。
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconSize = 15,
    this.danger = false,
  });

  final IconData icon;

  /// 语义标签（读屏与测试用）
  final String label;

  final VoidCallback onTap;
  final double iconSize;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  static const Color _closeHover = Color(0xFFC42B1C);

  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool highlight = _hovering;
    final Color background = highlight
        ? (widget.danger ? _closeHover : scheme.surfaceContainerHighest)
        : Colors.transparent;
    final Color foreground = highlight && widget.danger
        ? Colors.white
        : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: LampTitleBar.height,
            color: background,
            child: Icon(widget.icon, size: widget.iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// 窗口外壳：上方是隐形的拖动条 + 窗口按钮，下方是应用内容。
///
/// 放在 `MaterialApp.builder` 里，因此标题区在所有页面之上、始终可见。
class WindowChrome extends StatelessWidget {
  const WindowChrome({
    super.key,
    required this.child,
    this.controls,
    this.background,
  });

  final Widget child;

  /// 不传时走真实的 `window_manager` 实现
  final WindowControls? controls;

  /// 与页面底色一致，避免出现「一条横带」
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        LampTitleBar(
          controls: controls ?? const WindowManagerControls(),
          background: background,
        ),
        Expanded(child: child),
      ],
    );
  }
}

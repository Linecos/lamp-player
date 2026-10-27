import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'immersive_chrome.dart';
import 'window_controls.dart';

/// 自绘的窗口标题区：左侧是拖动区，右侧是最小化 / 最大化 / 关闭按钮。
///
/// 原生标题栏已在 `main.dart` 里通过 `TitleBarStyle.hidden` 关掉。
/// 应用名与图标放到曲库侧栏顶部（见 `LibraryRail`），这里不再重复绘制。
/// 这里刻意不画分隔线，背景直接跟随页面底色，视觉上像是内容区的一部分，
/// 减少"外框感"。
///
/// - 拖动 / 双击最大化：左侧整块空白区域
/// - 右侧三个按钮不参与拖动
class LampTitleBar extends StatefulWidget {
  const LampTitleBar({
    super.key,
    required this.controls,
    this.background,
    this.leftInset = 0,
    this.controlsOnly = false,
  });

  final WindowControls controls;

  /// 与页面底色保持一致；不传时用 `surfaceContainerLow`（曲库页底色）
  final Color? background;

  /// 左上角让给页面的宽度：这段不接管拖动，页面顶部的按钮才收得到点击。
  final double leftInset;

  /// 只画右侧三个窗口按钮：页面自己绘制顶栏与拖动区时使用。
  final bool controlsOnly;

  /// 三个按钮的总宽度；页面顶栏据此预留右侧空间。
  static const double controlsWidth = 46 * 3;

  /// 高度；[WindowChrome] 据此预留布局。
  /// 48 给顶栏里的搜索框和窗口按钮留出上下呼吸空间。
  static const double height = 48;

  /// overlay 页面左上角放可点控件时默认让出的宽度。
  ///
  /// 标题条浮在页面之上，整条左侧都是拖动区；不让开的话，
  /// 页面顶部（y < 44）的按钮会被它整个吃掉点击。
  static const double defaultLeftInset = 160;

  @override
  State<LampTitleBar> createState() => _LampTitleBarState();
}

class _LampTitleBarState extends State<LampTitleBar> {
  bool _maximized = false;
  StreamSubscription<bool>? _maximizeSub;

  @override
  void initState() {
    super.initState();
    _listenMaximize();
    unawaited(_refreshMaximized());
  }

  @override
  void didUpdateWidget(LampTitleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controls != widget.controls) {
      unawaited(_maximizeSub?.cancel());
      _listenMaximize();
      unawaited(_refreshMaximized());
    }
  }

  @override
  void dispose() {
    unawaited(_maximizeSub?.cancel());
    super.dispose();
  }

  /// 系统触发的变化（Win+↑、拖到屏幕顶边）不会经过我们的按钮
  void _listenMaximize() {
    _maximizeSub = widget.controls.maximizeChanges.listen((bool maximized) {
      if (!mounted || maximized == _maximized) {
        return;
      }
      setState(() => _maximized = maximized);
    });
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = widget.background ?? scheme.surfaceContainerLow;

    final Widget controls = ValueListenableBuilder<bool>(
      valueListenable: forceLightWindowControls,
      builder: (BuildContext context, bool light, Widget? child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _CaptionButton(
              key: const ValueKey<String>('window-minimize'),
              glyph: WindowGlyph.minimize,
              label: '最小化',
              light: light,
              onTap: () => unawaited(_minimize()),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-maximize'),
              glyph: _maximized ? WindowGlyph.restore : WindowGlyph.maximize,
              label: _maximized ? '还原' : '最大化',
              light: light,
              onTap: () => unawaited(_toggleMaximize()),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-close'),
              glyph: WindowGlyph.close,
              label: '关闭',
              light: light,
              danger: true,
              onTap: () => unawaited(_close()),
            ),
          ],
        );
      },
    );

    if (widget.controlsOnly) {
      return Material(
        type: MaterialType.transparency,
        child: SizedBox(
          height: LampTitleBar.height,
          width: LampTitleBar.controlsWidth,
          child: controls,
        ),
      );
    }

    // 用透明 Material + 分区 ColoredBox 而不是 Material(color:)：
    // 不透明 Material 会把整条区域都当成实体吞掉点击，让位区就透不到页面。
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: LampTitleBar.height,
        child: Row(
          children: <Widget>[
            if (widget.leftInset > 0) SizedBox(width: widget.leftInset),
            Expanded(
              child: ColoredBox(
                color: background,
                child: GestureDetector(
                  key: const ValueKey<String>('window-drag-area'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => unawaited(_startDragging()),
                  onDoubleTap: () => unawaited(_toggleMaximize()),
                  child: Semantics(
                    label: '窗口标题栏（可拖动）',
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            ColoredBox(color: background, child: controls),
          ],
        ),
      ),
    );
  }
}

/// 自绘窗口按钮的图形类型。
enum WindowGlyph { minimize, maximize, restore, close }

class _WindowGlyphPainter extends CustomPainter {
  const _WindowGlyphPainter({required this.glyph, required this.color});

  final WindowGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 图形按 14×14 设计，按实际尺寸等比缩放
    canvas.save();
    canvas.scale(size.width / 14, size.height / 14);

    switch (glyph) {
      case WindowGlyph.minimize:
        canvas.drawLine(const Offset(2, 7), const Offset(12, 7), paint);
      case WindowGlyph.maximize:
        // 四角括号，参考 Coriander 的全屏图标
        final Path path = Path()
          ..moveTo(2, 5)
          ..lineTo(2, 2)
          ..lineTo(5, 2)
          ..moveTo(9, 2)
          ..lineTo(12, 2)
          ..lineTo(12, 5)
          ..moveTo(12, 9)
          ..lineTo(12, 12)
          ..lineTo(9, 12)
          ..moveTo(5, 12)
          ..lineTo(2, 12)
          ..lineTo(2, 9);
        canvas.drawPath(path, paint);
      case WindowGlyph.restore:
        canvas.drawRect(const Rect.fromLTWH(2, 5, 7, 7), paint);
        canvas.drawRect(const Rect.fromLTWH(5, 2, 7, 7), paint);
      case WindowGlyph.close:
        canvas.drawLine(const Offset(3, 3), const Offset(11, 11), paint);
        canvas.drawLine(const Offset(11, 3), const Offset(3, 11), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindowGlyphPainter oldDelegate) {
    return oldDelegate.glyph != glyph || oldDelegate.color != color;
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
    required this.glyph,
    required this.label,
    required this.onTap,
    this.light = false,
    this.danger = false,
  });

  final WindowGlyph glyph;

  /// 语义标签（读屏与测试用）
  final String label;

  final VoidCallback onTap;
  final bool light;
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
        ? (widget.danger
              ? _closeHover
              : (widget.light
                    ? Colors.white.withValues(alpha: 0.16)
                    : scheme.surfaceContainerHighest))
        : Colors.transparent;
    final Color foreground = highlight && widget.danger
        ? Colors.white
        : (widget.light ? Colors.white : scheme.onSurfaceVariant);

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
            child: Center(
              child: CustomPaint(
                key: ValueKey<String>('window-glyph-${widget.glyph.name}'),
                size: const Size(15, 15),
                painter: _WindowGlyphPainter(
                  glyph: widget.glyph,
                  color: foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 窗口外壳：默认上方是标题条 + 下方应用内容。
///
/// 放在 `MaterialApp.builder` 里，因此标题区在所有页面之上、始终可见。
///
/// [overlay] 为 true 时，页面铺满整个窗口，标题条浮在最上层并保持透明；
/// 曲库页会把侧栏一直画到窗口顶部，让应用图标 / 名称被侧栏背景包住。
/// 使用 overlay 的页面需要自己预留 [LampTitleBar.height] 的顶部空间；
/// 只有左上角 [LampTitleBar.defaultLeftInset] 宽的小块是例外——那段标题条
/// 不接管拖动，页面可以把顶部控件放进去。
class WindowChrome extends StatelessWidget {
  const WindowChrome({
    super.key,
    required this.child,
    this.controls,
    this.background,
    this.overlay = false,
    this.leftInset,
    this.controlsOnly = false,
  });

  final Widget child;

  /// 不传时走真实的 `window_manager` 实现
  final WindowControls? controls;

  /// 非 overlay 模式下与页面底色一致，避免出现「一条横带」
  final Color? background;

  /// 页面是否铺满窗口、标题条浮在内容之上
  final bool overlay;

  /// 标题条左侧让给页面的宽度；不传时 overlay 页面用默认值，非 overlay 为 0
  final double? leftInset;

  /// 只画窗口按钮，页面自己负责顶栏与拖动区。
  final bool controlsOnly;

  @override
  Widget build(BuildContext context) {
    final Widget titleBar = AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[immersiveMode, pointerNearTop]),
      // 沉浸模式下窗口按钮跟着页面一起隐，指针靠近顶端才露出来
      builder: (BuildContext context, Widget? child) {
        final bool hidden = immersiveMode.value && !pointerNearTop.value;
        return IgnorePointer(
          ignoring: hidden,
          child: AnimatedOpacity(
            opacity: hidden ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: child,
          ),
        );
      },
      child: LampTitleBar(
        controls: controls ?? const WindowManagerControls(),
        background: overlay ? Colors.transparent : background,
        leftInset: leftInset ?? (overlay ? LampTitleBar.defaultLeftInset : 0),
        controlsOnly: controlsOnly,
      ),
    );

    return MouseRegion(
      // 铺满整个窗口：右上角按钮区被它自己盖住，页面收不到 hover，
      // 所以感应统一放在外壳这一层。
      onHover: (PointerHoverEvent event) =>
          trackPointerNearTop(event.localPosition),
      onExit: (_) => pointerNearTop.value = false,
      child: _layout(titleBar),
    );
  }

  Widget _layout(Widget titleBar) {
    if (controlsOnly) {
      if (overlay) {
        return Stack(
          children: <Widget>[
            Positioned.fill(child: child),
            Positioned(
              top: 0,
              right: 0,
              width: LampTitleBar.controlsWidth,
              height: LampTitleBar.height,
              child: titleBar,
            ),
          ],
        );
      }
      return Column(
        children: <Widget>[
          SizedBox(
            height: LampTitleBar.height,
            child: Align(alignment: Alignment.centerRight, child: titleBar),
          ),
          Expanded(child: child),
        ],
      );
    }

    if (!overlay) {
      return Column(
        children: <Widget>[
          titleBar,
          Expanded(child: child),
        ],
      );
    }

    return Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: LampTitleBar.height,
          child: titleBar,
        ),
      ],
    );
  }
}

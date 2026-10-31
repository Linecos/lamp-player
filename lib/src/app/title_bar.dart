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
class LampTitleBar extends StatelessWidget {
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
  static const double controlsWidth = _captionWidth * 3;

  /// 单个窗口按钮的宽度。字形 20px，左右各留 16px 空白，
  /// 和 ZeroBit 那种「字距宽松、不挤成一排图标」的观感对齐
  static const double _captionWidth = 52;

  /// 高度；[WindowChrome] 据此预留布局。
  /// 48 给顶栏里的搜索框和窗口按钮留出上下呼吸空间。
  static const double height = 48;

  /// overlay 页面左上角放可点控件时默认让出的宽度。
  ///
  /// 标题条浮在页面之上，整条左侧都是拖动区；不让开的话，
  /// 页面顶部（y < 44）的按钮会被它整个吃掉点击。
  static const double defaultLeftInset = 160;

  Future<void> _startDragging() async {
    try {
      await controls.startDragging();
    } catch (_) {
      // 忽略：拖不动总比崩了强
    }
  }

  Future<void> _toggleMaximize() async {
    try {
      await controls.toggleMaximize();
    } catch (_) {
      // 同上
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = this.background ?? scheme.surfaceContainerLow;

    // 按钮颜色只跟主题深浅走：浅色模式纯黑、深色模式纯白。正在播放页那层
    // 取色背景上的按钮由页面自己画（固定白色），这里不再按底色挑对比度。
    final Color foreground = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;

    final Widget buttons = WindowButtons(
      controls: controls,
      foreground: foreground,
    );

    if (controlsOnly) {
      return Material(
        type: MaterialType.transparency,
        child: SizedBox(height: height, width: controlsWidth, child: buttons),
      );
    }

    // 用透明 Material + 分区 ColoredBox 而不是 Material(color:)：
    // 不透明 Material 会把整条区域都当成实体吞掉点击，让位区就透不到页面。
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: height,
        child: Row(
          children: <Widget>[
            if (leftInset > 0) SizedBox(width: leftInset),
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
            ColoredBox(color: background, child: buttons),
          ],
        ),
      ),
    );
  }
}

/// 最小化 / 最大化（还原）/ 关闭三个按钮。
///
/// 标题栏和正在播放页共用这一份：播放页要把按钮连同页面一起滑进来，不能再
/// 依赖 `MaterialApp.builder` 里那层固定在窗口右上角的浮层。
class WindowButtons extends StatefulWidget {
  const WindowButtons({
    super.key,
    required this.controls,
    required this.foreground,
    this.castShadow = false,
  });

  final WindowControls controls;

  /// 字形颜色：浅色主题纯黑、深色主题纯白；取色背景上固定白色
  final Color foreground;

  /// 背后是封面取色渐变时给字形补一圈反向描影；纯色底上会糊，不要开
  final bool castShadow;

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  bool _maximized = false;
  StreamSubscription<bool>? _maximizeSub;

  @override
  void initState() {
    super.initState();
    _listenMaximize();
    unawaited(_refreshMaximized());
  }

  @override
  void didUpdateWidget(WindowButtons oldWidget) {
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

  @override
  Widget build(BuildContext context) {
    // 悬停蒙层从字形颜色的明暗反推：白字配白蒙层、黑字配深蒙层
    final bool darkBackdrop = widget.foreground.computeLuminance() < 0.5
        ? false
        : true;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _CaptionButton(
          key: const ValueKey<String>('window-minimize'),
          glyph: WindowGlyph.minimize,
          label: '最小化',
          foreground: widget.foreground,
          darkBackdrop: darkBackdrop,
          needsHalo: widget.castShadow,
          onTap: () => unawaited(_minimize()),
        ),
        _CaptionButton(
          key: const ValueKey<String>('window-maximize'),
          glyph: _maximized ? WindowGlyph.restore : WindowGlyph.maximize,
          label: _maximized ? '还原' : '最大化',
          foreground: widget.foreground,
          darkBackdrop: darkBackdrop,
          needsHalo: widget.castShadow,
          onTap: () => unawaited(_toggleMaximize()),
        ),
        _CaptionButton(
          key: const ValueKey<String>('window-close'),
          glyph: WindowGlyph.close,
          label: '关闭',
          foreground: widget.foreground,
          darkBackdrop: darkBackdrop,
          needsHalo: widget.castShadow,
          danger: true,
          onTap: () => unawaited(_close()),
        ),
      ],
    );
  }
}

/// 自绘窗口按钮的图形类型。
enum WindowGlyph { minimize, maximize, restore, close }

/// 窗口按钮字形：按 20×20 设计稿画，1.6px 描边、直角转折、平头端点。
///
/// 对齐 ZeroBit Player 那套线稿：一条细横线、四角折角、对角双箭头、叉。
/// 早先用的是「圆角方框 + 圆头笔画 + 1.35 描边」，在 15px 下笔画几乎糊成一
/// 小块，而且圆角方框看起来更像「复选框」而不是「整窗」。
class _WindowGlyphPainter extends CustomPainter {
  const _WindowGlyphPainter({
    required this.glyph,
    required this.color,
    required this.shadowColor,
  });

  /// 设计稿边长，所有坐标都在这个尺度里写
  static const double _design = 20;

  /// 描边宽度：设计稿 20 里 1.6，约等于 ZeroBit 那套的 2/20
  static const double _stroke = 1.6;

  final WindowGlyph glyph;
  final Color color;

  /// 描影：白字形落在亮背景上、黑字形落在暗背景上，都靠它压住边界。正在播放
  /// 页的底色是封面取色的渐变，局部亮局部暗，单靠字形颜色总有一处看不清。
  final Color shadowColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _design, size.height / _design);
    // 描影只铺一层很淡的模糊：太厚会把 1.6 的细线糊成一条脏边
    _paint(canvas, shadowColor, 1.0);
    _paint(canvas, color, 0);
    canvas.restore();
  }

  void _paint(Canvas canvas, Color color, double blur) {
    final MaskFilter? mask = blur > 0
        ? MaskFilter.blur(BlurStyle.normal, blur)
        : null;
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter
      ..maskFilter = mask;
    switch (glyph) {
      case WindowGlyph.minimize:
        // 一条细横线，几乎占满图标宽度（参考稿里比折角框还宽一点）
        canvas.drawLine(const Offset(0.6, 10), const Offset(19.4, 10), stroke);
      case WindowGlyph.maximize:
        // 四角折角：臂长 6，中间留空，比圆角方框更像「整窗」
        canvas.drawPath(
          Path()
            ..moveTo(1, 7)
            ..lineTo(1, 1)
            ..lineTo(7, 1)
            ..moveTo(13, 1)
            ..lineTo(19, 1)
            ..lineTo(19, 7)
            ..moveTo(19, 13)
            ..lineTo(19, 19)
            ..lineTo(13, 19)
            ..moveTo(7, 19)
            ..lineTo(1, 19)
            ..lineTo(1, 13),
          stroke,
        );
      case WindowGlyph.restore:
        // 四角向内：折角的**拐点朝中心**、两臂伸向四角，和 maximize 正好相反。
        // 之前用对角双箭头，和旁边两个「方框类」字形风格不搭，摆在一起很跳。
        canvas.drawPath(
          Path()
            ..moveTo(1, 7)
            ..lineTo(7, 7)
            ..lineTo(7, 1)
            ..moveTo(19, 7)
            ..lineTo(13, 7)
            ..lineTo(13, 1)
            ..moveTo(1, 13)
            ..lineTo(7, 13)
            ..lineTo(7, 19)
            ..moveTo(19, 13)
            ..lineTo(13, 13)
            ..lineTo(13, 19),
          stroke,
        );
      case WindowGlyph.close:
        // 叉：边长 17，留出呼吸空间
        canvas
          ..drawLine(const Offset(1.5, 1.5), const Offset(18.5, 18.5), stroke)
          ..drawLine(const Offset(18.5, 1.5), const Offset(1.5, 18.5), stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _WindowGlyphPainter oldDelegate) {
    return oldDelegate.glyph != glyph ||
        oldDelegate.color != color ||
        oldDelegate.shadowColor != shadowColor;
  }
}

/// 窗口按钮：默认透明，悬停时亮起一个圆形底；关闭键悬停变红底白字。
///
/// 圆形底而不是整格方块：正在播放页左上角的「收起」是标准 `IconButton`，
/// 悬停高亮就是圆的；右上角这三个原先是整块矩形，同一条顶栏里两种形状并
/// 存，看着像两套控件。现在三个按钮各自在一个圆形底上悬停，点击热区仍是
/// 各自的整格（52×48，贴着窗口边角也好按）。
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
    required this.foreground,
    this.darkBackdrop = false,
    this.needsHalo = false,
    this.danger = false,
  });

  final WindowGlyph glyph;

  /// 语义标签（读屏与测试用）
  final String label;

  final VoidCallback onTap;

  /// 字形颜色：由标题栏按背后的实际底色挑好，不再死跟主题
  final Color foreground;

  /// 底色偏深：悬停铺白色蒙层，否则铺深色蒙层
  final bool darkBackdrop;

  /// 背后是取色渐变：给字形补一圈反向描影，纯色底上不需要
  final bool needsHalo;

  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  static const Color _closeHover = Color(0xFFC42B1C);

  /// 每个按钮占的宽度；三个加起来就是 [LampTitleBar.controlsWidth]
  static const double _slotWidth = LampTitleBar._captionWidth;

  /// 悬停时圆形底的直径。与「收起」按钮的圆形高亮视觉大小对齐，
  /// 比格子小一圈，相邻两个圆之间正好留出 6px 缝
  static const double _hoverDiameter = 40;

  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool highlight = _hovering;
    final Color background = !highlight
        ? Colors.transparent
        : widget.danger
        ? _closeHover
        // 悬停底也从底色推导：浅底铺深色蒙层、深底铺白色蒙层，
        // 否则浅底上白色蒙层等于没画
        : (widget.darkBackdrop
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.black.withValues(alpha: 0.06));
    final Color foreground = highlight && widget.danger
        ? Colors.white
        : widget.foreground;
    // 描影与字形反向：只在取色背景上画，纯色主题底加了反而发糊
    final Color shadow = !widget.needsHalo
        ? Colors.transparent
        : widget.foreground.computeLuminance() > 0.5
        ? Colors.black.withValues(alpha: 0.32)
        : Colors.white.withValues(alpha: 0.4);

    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: _slotWidth,
            height: LampTitleBar.height,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: _hoverDiameter,
                height: _hoverDiameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: background,
                ),
                child: Center(
                  child: CustomPaint(
                    key: ValueKey<String>('window-glyph-${widget.glyph.name}'),
                    size: const Size(20, 20),
                    painter: _WindowGlyphPainter(
                      glyph: widget.glyph,
                      color: foreground,
                      shadowColor: shadow,
                    ),
                  ),
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
      animation: Listenable.merge(<Listenable>[
        immersiveMode,
        pointerNearTop,
        pageOwnsWindowControls,
      ]),
      // 两种隐藏：沉浸模式下指针离开顶部就隐；页面自带按钮时整层让位
      builder: (BuildContext context, Widget? child) {
        final bool hidden =
            pageOwnsWindowControls.value ||
            (immersiveMode.value && !pointerNearTop.value);
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

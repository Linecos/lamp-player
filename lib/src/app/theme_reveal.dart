import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 深浅色切换时，从**鼠标最后点击的位置**向四周扩散的圆形揭示。
///
/// 圆内是已经切好的新主题，圆外仍是切换前那一帧 —— 也就是 Android 13
/// 换主题那种「从一个点铺开」的观感。
///
/// ## 为什么不是 `MaterialApp` 自带的 ThemeData 过渡
///
/// 曲库页把每个分区的 widget 树整棵缓存成快照（见 `library_page` 的
/// `_cachedSection`），而快照里的颜色是**建快照那一刻**定死的，所以配色一变
/// 就得让快照过期、整页重建。ThemeData 过渡等于每一帧换一次配色，
/// 也就是每一帧重建整个可见分区：2000 首曲库上实测中位 24ms/帧、
/// 累计 1.4s，比瞬时切换贵五倍还多。`app.dart` 因此一直关着主题动画。
///
/// ## 这里的做法与开销
///
/// 主题仍然**一帧切完**（一次重建，和以前一样），额外把切换前那一帧抓成一张
/// 图，按「屏幕减去一个圆」的形状画出来；圆随时间变大，旧的画面就被「挤掉」。
///
/// - 抓图：一次 [RenderRepaintBoundary.toImageSync]，一次性成本；抓不到就退回
///   瞬时切换，不影响功能
/// - 过渡：每帧只画一次 `drawPath`（矩形 + 圆形两条轮廓、偶奇填充，圆即挖空），
///   填充用 [ui.ImageShader] 直接采样那张图 —— 不建 `OpacityLayer`、不走
///   `saveLayer`，也不重建任何 widget（`CustomPainter` 挂在动画上自己重画）
/// - 内存：一张按设备像素比抓的图，1440×900@1.25 约 8MB；揭示走完（或再切
///   一次）立刻 `dispose`，不常驻
///
/// ## 只管明暗切换
///
/// 只在 `Brightness` 变化时抓图。强调色变化、以及「强调色跟随封面」每换一首
/// 歌都换一次主题 —— 那条路径必须保持瞬时切换，否则每次切歌都要抓一张图。
class ThemeReveal extends StatefulWidget {
  const ThemeReveal({super.key, required this.child});

  /// 应用内容（整个窗口，含自绘窗口按钮）
  final Widget child;

  /// 扩散时长。圆形铺满全屏比单纯淡出更需要时间才显得「平顺」，
  /// 但再长用户就要等它了。
  static const Duration duration = Duration(milliseconds: 400);

  /// 抓图精度上限。超过 1.5 之后肉眼分不出，内存却按平方涨。
  static const double maxCapturePixelRatio = 1.5;

  /// 遮盖层的 key，测试与目检用
  static const ValueKey<String> overlayKey = ValueKey<String>('theme-reveal');

  @override
  State<ThemeReveal> createState() => _ThemeRevealState();
}

class _ThemeRevealState extends State<ThemeReveal>
    with SingleTickerProviderStateMixin {
  /// 包住整个窗口内容，用来抓切换前那一帧
  final GlobalKey _contentKey = GlobalKey();

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ThemeReveal.duration,
  )..addStatusListener(_onStatus);

  /// 圆外要画的旧画面；为空表示当前没在做揭示
  ui.Image? _snapshot;

  /// 抓 [_snapshot] 时用的像素比，绘制时要按它缩回去
  double _snapshotRatio = 1;

  /// 这次扩散的圆心；为空时用窗口中心
  Offset? _origin;

  /// 最后一次按下的位置（逻辑像素，相对窗口左上角）
  Offset? _lastPointerDown;

  /// 上一帧的明暗，用来判断这次是不是真的换了深浅
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Brightness next = Theme.of(context).brightness;
    final Brightness? previous = _brightness;
    _brightness = next;
    // 首帧没有「上一张」可画；强调色变化明暗没变，也不需要
    if (previous == null || previous == next) {
      return;
    }
    final ui.Image? snapshot = _capture();
    if (snapshot == null) {
      // 抓不到就退回瞬时切换，功能不受影响
      return;
    }
    final ui.Image? stale = _snapshot;
    _snapshot = snapshot;
    _origin = _lastPointerDown;
    _controller.forward(from: 0);
    if (stale != null) {
      _disposeAfterFrame(stale);
    }
  }

  /// 抓当前画面；渲染对象还没画过或抓图失败时返回 null。
  ///
  /// 调用点在 `didChangeDependencies` 里，这一帧还没开始画，所以拿到的是
  /// **上一帧**（旧主题）的画面 —— 正好是要留在圆外的那张。
  ui.Image? _capture() {
    final RenderObject? render = _contentKey.currentContext?.findRenderObject();
    if (render is! RenderRepaintBoundary || render.debugNeedsPaint) {
      return null;
    }
    final double ratio = math.min(
      MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
      ThemeReveal.maxCapturePixelRatio,
    );
    try {
      final ui.Image image = render.toImageSync(pixelRatio: ratio);
      _snapshotRatio = ratio;
      return image;
    } catch (_) {
      return null;
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }
    final ui.Image? snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    setState(() => _snapshot = null);
    _disposeAfterFrame(snapshot);
  }

  /// 等这一帧画完再释放：上一张图可能还在这一帧的图层里
  void _disposeAfterFrame(ui.Image image) {
    WidgetsBinding.instance.addPostFrameCallback(
      (Duration _) => image.dispose(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _snapshot?.dispose();
    _snapshot = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui.Image? snapshot = _snapshot;
    return Listener(
      // 只记录位置，不拦截事件（deferToChild），点击照旧落到原来的控件上
      onPointerDown: (PointerDownEvent event) =>
          _lastPointerDown = event.position,
      child: Stack(
        fit: StackFit.expand,
        // 显式指定非方向性对齐，免得依赖上层的 Directionality
        alignment: Alignment.topLeft,
        textDirection: TextDirection.ltr,
        children: <Widget>[
          RepaintBoundary(key: _contentKey, child: widget.child),
          if (snapshot != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  key: ThemeReveal.overlayKey,
                  painter: ThemeRevealPainter(
                    image: snapshot,
                    origin: _origin,
                    pixelRatio: _snapshotRatio,
                    progress: _controller,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 圆外画旧画面、圆内留空的绘制器。
///
/// 挂在 [AnimationController] 上自己重画，过渡期间**不重建任何 widget**。
class ThemeRevealPainter extends CustomPainter {
  ThemeRevealPainter({
    required this.image,
    required this.origin,
    required this.pixelRatio,
    required Animation<double> progress,
  }) : _progress = progress,
       super(repaint: progress);

  /// 切换前那一帧
  final ui.Image image;

  /// 扩散圆心；为空时用窗口中心
  final Offset? origin;

  /// [image] 的抓图精度
  final double pixelRatio;

  final Animation<double> _progress;

  /// 揭示进度（0 → 1）
  Animation<double> get progress => _progress;

  /// 圆心到最远角的距离：圆涨到这个半径就铺满了
  static double radiusToCover(Offset center, Size size) {
    final double dx = math.max(center.dx, size.width - center.dx);
    final double dy = math.max(center.dy, size.height - center.dy);
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final Offset center = _clampToWindow(
      origin ?? size.center(Offset.zero),
      size,
    );
    final double cover = radiusToCover(center, size);
    final double radius = cover * _progress.value;
    // 圆已经盖满：整屏都是新主题，什么都不用画
    if (radius >= cover) {
      return;
    }
    // 矩形 + 圆形两条轮廓，偶奇填充让圆变成洞 —— 比 Path.combine 便宜
    final Path ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    final Paint paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        // 图是按像素比抓的，画的时候缩回逻辑像素
        Matrix4.diagonal3Values(1 / pixelRatio, 1 / pixelRatio, 1).storage,
        filterQuality: FilterQuality.low,
      );
    canvas.drawPath(ring, paint);
  }

  static Offset _clampToWindow(Offset point, Size size) =>
      Offset(point.dx.clamp(0.0, size.width), point.dy.clamp(0.0, size.height));

  @override
  bool shouldRepaint(ThemeRevealPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.origin != origin ||
      oldDelegate.pixelRatio != pixelRatio;
}

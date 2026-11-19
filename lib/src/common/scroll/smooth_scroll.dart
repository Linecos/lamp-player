import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 让鼠标滚轮也「平滑滚动」的控制器。
///
/// Flutter 桌面端处理滚轮走 [ScrollPosition.pointerScroll]：一个
/// `PointerScrollEvent` 直接把 pixels 设到目标（一格约 50px），一帧跳完，
/// 所以看起来是一格一格顿着走的。这里换成一段追帧动画：
///
/// - 每帧吃掉「剩余距离」的固定比例，比例按 dt 归一化——120Hz 和 60Hz 在
///   同样的时间里走同样远，越接近目标越慢，天然缓出；
/// - 连续滚轮叠的是**目标**，不是每格重起一段动画（后者会一格一顿）；
/// - 挂在 [ScrollActivity] 上，拖拽 / 键盘 / 列表换物理 / 位置重建这些新活动
///   都会把它 dispose 掉（ticker 一起停），不需要自己判断冲突。
///
/// 用法：给 ScrollView 的 `controller` 传它；不方便自己管控制器的地方用
/// [SmoothScroll] 包一层。
///
/// 注意不能靠根 `PrimaryScrollController` 一把兜住：`ModalRoute` 会给**每个
/// 路由**套一个 `PrimaryScrollController`（只对移动平台生效，且是个普通
/// `ScrollController`），它在桌面上既不继承、也不会平滑，还会把更外层的
/// 根控制器挡住 —— 所以每个滚动视图各自拿一个。
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class SmoothScrollPosition extends ScrollPositionWithSingleContext {
  SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0) {
      // PointerScrollInertiaCancelEvent（触摸板松手）：停下追帧，交回框架
      goBallistic(0.0);
      return;
    }
    final ScrollActivity? current = activity;
    if (current is SmoothWheelActivity) {
      // 连续滚轮：目标叠起来，动画接着跑，不从头再来
      current.addDelta(delta);
      return;
    }
    final double target = math.min(
      math.max(pixels + delta, minScrollExtent),
      maxScrollExtent,
    );
    if (target == pixels) {
      return;
    }
    updateUserScrollDirection(
      delta < 0.0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    beginActivity(
      SmoothWheelActivity(delegate: this, target: target, vsync: context.vsync),
    );
  }
}

/// 追帧滚轮动画：每帧朝目标走一段，走完交给惯性（速度为 0，直接停下）。
class SmoothWheelActivity extends ScrollActivity {
  SmoothWheelActivity({
    required ScrollActivityDelegate delegate,
    required double target,
    required TickerProvider vsync,
  }) : super(delegate) {
    _target = target;
    _ticker = vsync.createTicker(_tick)..start();
  }

  /// 每 16.7ms 保留的剩余距离比例：0.72 ⇒ 一帧走掉 28%，约 10 帧（160ms）
  /// 走完 95%。再大就拖沓，再小就还能看出「跳」。
  static const double _keepPerFrame = 0.72;

  /// 收尾阈值：小于半像素就没有「滑」的意义了，直接落到目标
  static const double _settle = 0.5;

  double _target = 0;
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => 0.0;

  /// 滚轮动画期间仍然接受点击：连续滚轮时鼠标不会一直悬在列表上，
  /// 若像「程序化动画」那样把指针屏蔽掉，点一下会像没反应
  @override
  bool get shouldIgnorePointer => false;

  ScrollPosition get _position => delegate as ScrollPosition;

  void addDelta(double delta) {
    final ScrollPosition position = _position;
    _target = math.min(
      math.max(_target + delta, position.minScrollExtent),
      position.maxScrollExtent,
    );
  }

  void _tick(Duration elapsed) {
    final ScrollPosition position = _position;
    final double dtMs = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    // 列表在滚的过程中可能变高 / 变矮（筛选、换分区），目标跟着夹一次
    _target = math.min(
      math.max(_target, position.minScrollExtent),
      position.maxScrollExtent,
    );
    final double remaining = _target - position.pixels;
    if (remaining.abs() <= _settle) {
      delegate.setPixels(_target);
      // 结束：交给 Idle 活动（会 dispose 本活动、停 ticker、发滚动结束通知）
      delegate.goBallistic(0.0);
      return;
    }
    // dt 归一化；首帧或异常 dt 按一帧算
    final double frames = dtMs > 0 && dtMs.isFinite ? dtMs / 16.683 : 1.0;
    final double keep = math.pow(_keepPerFrame, frames).toDouble();
    final double next = position.pixels + remaining * (1 - keep);
    // 这一帧就够贴住了：直接落到位，不为最后半个像素再排一帧
    if ((_target - next).abs() <= _settle) {
      delegate.setPixels(_target);
      delegate.goBallistic(0.0);
      return;
    }
    delegate.setPixels(next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// 给一个滚动视图配一个自管的 [SmoothScrollController]。
///
/// ```dart
/// SmoothScroll(
///   builder: (BuildContext context, ScrollController controller) =>
///       ListView(controller: controller, children: ...),
/// )
/// ```
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final SmoothScrollController _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// 自带平滑控制器的 [ListView]：内容很长的页面用它，省得自己管控制器。
class SmoothListView extends StatefulWidget {
  const SmoothListView({
    super.key,
    this.padding,
    this.shrinkWrap = false,
    required this.children,
  });

  final EdgeInsetsGeometry? padding;
  final bool shrinkWrap;
  final List<Widget> children;

  @override
  State<SmoothListView> createState() => _SmoothListViewState();
}

class _SmoothListViewState extends State<SmoothListView> {
  final SmoothScrollController _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: _controller,
      padding: widget.padding,
      shrinkWrap: widget.shrinkWrap,
      children: widget.children,
    );
  }
}

/// 自带平滑控制器的 [SingleChildScrollView]（只做纵向）。
class SmoothSingleChildScrollView extends StatefulWidget {
  const SmoothSingleChildScrollView({
    super.key,
    this.padding,
    required this.child,
  });

  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  State<SmoothSingleChildScrollView> createState() =>
      _SmoothSingleChildScrollViewState();
}

class _SmoothSingleChildScrollViewState
    extends State<SmoothSingleChildScrollView> {
  final SmoothScrollController _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _controller,
      padding: widget.padding,
      child: widget.child,
    );
  }
}

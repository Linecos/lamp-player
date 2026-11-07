import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 量某个 key 对应 widget 在屏幕上的矩形；量不到（还没布局 / 已卸载）返回 null。
Rect? rectOfKey(GlobalKey key) {
  final RenderObject? box = key.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 列表卡片与详情头部共用的飞行标识。
///
/// 两处按同一个字符串判断「这次飞行是谁在飞」：详情头部据此藏起自己，
/// 列表卡片据此藏起卡片封面——两边都藏着，屏幕上才只有飞行层那一张。
String artistCoverTag(String name) => 'artist:$name';

String albumCoverTag(String key) => 'album:$key';

/// 专辑卡片封面的圆角（32 的卡片外框 - 12 内边距 = 20，与卡片圆角同心）
const double albumCardCoverRadius = 20;

/// 专辑详情头部封面的圆角
const double albumDetailCoverRadius = 32;

/// 在 Overlay 上让一张封面从 [from] 飞到 [to]。
///
/// 艺术家 / 专辑的列表与详情是**同一个页面里的两个子树**（`AnimatedSwitcher`
/// 切换），原生的 `Hero` 只认路由，所以这里自己铺一层：位置按两端的矩形插值，
/// 尺寸用 `Transform.scale` 缩放。
///
/// 关键一点：这一层**始终按两端较大的那个尺寸构建**，再靠缩放显示。
/// 反过来（按终点尺寸构建）会有两处崩掉——起点比终点大时（详情退回列表），
/// 盒子被压到卡片大小，而里面的字号 / 圆角仍按大尺寸算，再乘上 >1 的缩放，
/// 就出现「字先暴涨一下」「最后四个角突然被填上」这种跳变。
///
/// [buildCover] 每帧用当前的 `size` / `radius` 重建：半径按视觉值反算
/// （`radius = 视觉半径 / 缩放`），所以放大缩小过程中圆角是平滑变的，
/// 落地时正好等于目标端自己的圆角。
///
/// 返回取消函数：页面销毁时必须调用，否则 Overlay 上的这一层会留在那里
/// （Overlay 挂在 Navigator 上，比页面活得久）。
VoidCallback flyCover(
  BuildContext context, {
  required Rect from,
  required Rect to,
  Rect Function()? toNow,
  double fromRadius = 0,
  double toRadius = 0,
  required Widget Function(double size, double radius) buildCover,
  required VoidCallback onDone,
  Duration duration = const Duration(milliseconds: 260),
}) {
  final OverlayState? overlay = Overlay.maybeOf(context);
  if (overlay == null || from.isEmpty || to.isEmpty) {
    onDone();
    return () {};
  }
  bool finished = false;
  late final OverlayEntry entry;
  void finish() {
    if (finished) {
      return;
    }
    finished = true;
    entry.remove();
    entry.dispose();
    onDone();
  }

  entry = OverlayEntry(
    builder: (BuildContext context) => _CoverFlight(
      from: from,
      to: to,
      toNow: toNow,
      size: math.max(from.width, to.width),
      fromRadius: fromRadius,
      toRadius: toRadius,
      duration: duration,
      onEnd: finish,
      buildCover: buildCover,
    ),
  );
  overlay.insert(entry);
  return finish;
}

/// 详情页头部的封面、以及列表卡片上的封面：有人正飞着时先让位给飞行层。
///
/// 不隐藏的话，飞行中的那一张和两端的那两张会同时出现在屏幕上。
class CoverFlightTarget extends StatelessWidget {
  const CoverFlightTarget({
    super.key,
    required this.hidden,
    required this.child,
  });

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(opacity: hidden ? 0 : 1, child: child);
  }
}

/// 二次贝塞尔插值
Offset _quadratic(Offset a, Offset control, Offset b, double t) {
  final double u = 1 - t;
  return a * (u * u) + control * (2 * u * t) + b * (t * t);
}

class _CoverFlight extends StatelessWidget {
  const _CoverFlight({
    required this.from,
    required this.to,
    required this.toNow,
    required this.size,
    required this.fromRadius,
    required this.toRadius,
    required this.duration,
    required this.onEnd,
    required this.buildCover,
  });

  final Rect from;

  /// 起飞时量到的终点（[toNow] 量不到时用它兜底）
  final Rect to;

  /// 终点的**实时**位置。详情内容自己还有一段上浮（`AnimatedSwitcher` 的
  /// 180ms 里头部封面会往上走约 10px），只在起飞那一刻量一次的话，
  /// 飞行 260ms 落地时真实封面已经高了一截——观感就是「到位后又往上顿一下」。
  final Rect Function()? toNow;

  /// 飞行盒子的边长：两端取大，靠缩放显示
  final double size;

  /// 两端的圆角（视觉值）
  final double fromRadius;
  final double toRadius;

  final Duration duration;
  final VoidCallback onEnd;
  final Widget Function(double size, double radius) buildCover;

  /// 这一帧该飞向哪里
  Rect _end() {
    final Rect? now = toNow?.call();
    return (now == null || now.isEmpty) ? to : now;
  }

  @override
  Widget build(BuildContext context) {
    final double startScale = size <= 0 ? 1 : from.width / size;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: duration,
        curve: Curves.easeOutCubic,
        onEnd: onEnd,
        builder: (BuildContext context, double t, Widget? _) {
          final Rect end = _end();
          final double endScale = size <= 0 ? 1 : end.width / size;
          final double scale = startScale + (endScale - startScale) * t;
          // 沿一条略微上抛的弧线走：直线看着像「平移」，Hero 默认的
          // `MaterialRectArcTween` 也是弧线
          final double lift = (end.center - from.center).distance * 0.12;
          final Offset control =
              Offset.lerp(from.center, end.center, 0.5)! - Offset(0, lift);
          final Offset center = _quadratic(from.center, control, end.center, t);
          // 圆角也按视觉值走：盒子被缩放到 scale，所以传进去的半径要除以它，
          // 才能让屏幕上的圆角正好从起点那一端的值平滑过渡到终点那一端
          final double visualRadius = fromRadius + (toRadius - fromRadius) * t;
          final double radius = scale <= 0
              ? visualRadius
              : visualRadius / scale;
          return Stack(
            children: <Widget>[
              Positioned(
                left: center.dx - size / 2,
                top: center.dy - size / 2,
                width: size,
                height: size,
                // 飞行途中不要被窗口边界裁掉：Overlay 本身是全屏的，
                // 这里不额外加 Clip
                child: Transform.scale(
                  key: const ValueKey<String>('cover-flight'),
                  scale: scale,
                  child: buildCover(size, radius),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// 「正在播放」页的转场：从下方 20% 处滑上来 + 渐显（300ms，fastOutSlowIn），
/// 返回时反向；封面另有 Hero 飞行（tag 见 [coverHeroTag]）。两边一起才有
/// 「详情页像抽屉一样弹出、封面长大」的效果。
///
/// 页面用渐显而不是只有位移：Hero 的飞行层画在 Navigator 最上层，页面越透明，
/// 飞行的封面就越像是「自己长大了」，而不是贴着一张滑进来的图。这层 opacity
/// 在 Impeller 下每帧要一张离屏图层，是转场内存尖刺的一部分——**但不能拿它
/// 换内存**（试过去掉，页面变成「实心顶出来」，已回退），怎么省见
/// `docs/PROJECT_MEMORY.md` §6 第 79 条。
class NowPlayingPageRoute extends PageRouteBuilder<Object?> {
  /// 转场（前进或后退）没走完时收到的 pop 请求，先记下，等转场结束再执行。
  bool _popQueued = false;

  NowPlayingPageRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) => builder(context),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              final Animation<double> curved = animation.drive(
                CurveTween(curve: Curves.fastOutSlowIn),
              );
              // 淡入稍微早收：透明度在前 75% 就走完，之后只剩位移。
              //
              // 这层 opacity 小于 1 时，Impeller 要把整页（全屏流光 + 歌词 +
              // 频谱）合成进一张离屏图层，一帧一张。压到 0.75 是保守值：反向
              // 播放时同一条曲线也管淡出，压得太狠会「收回时整页还亮着、
              // 最后一下骤暗」。**但它不能去掉**——没有淡入，页面是「实心从
              // 下面顶出来」，观感与封面 Hero 的长大完全脱节（2026-11-06 试过去掉，
              // 随即回退）。省内存的事在别处做，见 docs/PROJECT_MEMORY.md §6 第 79 条。
              final Animation<double> fade = animation.drive(
                CurveTween(
                  curve: const Interval(0, 0.75, curve: Curves.easeOut),
                ),
              );
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.2),
                  end: Offset.zero,
                ).animate(curved),
                child: FadeTransition(opacity: fade, child: child),
              );
            },
      );

  // 转场中不允许立刻 pop：
  //
  // 封面 Hero 的飞行层跟着路由动画走，转场中被 pop（快速连点封面、转场中
  // 按 Esc、托盘关页……）会撞上框架的已知缺陷——飞行层收不了尾，残骸永远
  // 挂在 Overlay 上：岛上的封面停在不可见占位里、那张带阴影的大封面冻在
  // 半空（flutter/flutter#121325、SO 78080285）。实测复现过一次，重启才能救。
  //
  // 于是这里把「转场中的 pop」排队到转场结束：行为上只是关页晚了最多 300ms，
  // 但飞行层永远完整地走完出生与收尾。

  @override
  RoutePopDisposition get popDisposition {
    // animation 在路由安装前是 null：那时不可能收到 pop，走 super
    final AnimationStatus? status = animation?.status;
    if (status != null && status != AnimationStatus.completed) {
      return RoutePopDisposition.doNotPop;
    }
    return super.popDisposition;
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    super.onPopInvokedWithResult(didPop, result);
    final Animation<double>? anim = animation;
    if (didPop || _popQueued || anim == null) {
      return;
    }
    // 只有前进转场中才排队；后退转场中（已经在关了）不再补一刀，
    // 否则等它退完会把下面的路由也带掉
    if (anim.status != AnimationStatus.forward) {
      return;
    }
    _popQueued = true;
    anim.addStatusListener(_popWhenSettled);
    _popWhenSettled(anim.status);
  }

  void _popWhenSettled(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }
    animation?.removeStatusListener(_popWhenSettled);
    if (!_popQueued) {
      return;
    }
    _popQueued = false;
    navigator?.pop();
  }
}

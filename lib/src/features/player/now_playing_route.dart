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
class NowPlayingPageRoute extends PageRouteBuilder<void> {
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
}

import 'package:flutter/material.dart';

/// 「正在播放」页的转场：从下方 20% 处滑上来 + 渐显（300ms，fastOutSlowIn），
/// 返回时反向；封面另有 Hero 飞行（tag 见 [coverHeroTag]）。两边一起才有
/// 「详情页像抽屉一样弹出、封面长大」的效果。
///
/// 页面用渐显而不是整页位移很重要：Hero 的飞行层画在 Navigator 最上层，
/// 页面越透明，飞行的封面就越像是「自己长大了」，而不是贴着一张滑进来的图。
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
              // 只要这层 opacity 小于 1，Impeller 就得把整页合成进一张离屏
              // 图层（页面里有全屏流光 + 歌词 + 频谱），一帧一张纹理。压到
              // 0.75 是保守值：反向播放时同一条曲线也管淡出，压得太狠会让
              // 「收回时整页还亮着、最后才骤暗」。真要彻底消掉这些图层，
              // 只能连淡入一起去掉——那是视觉取舍，等实测数据再定。
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

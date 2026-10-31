import 'package:flutter/material.dart';

/// 「正在播放」页的转场：从下方 20% 处滑上来 + 渐显（300ms，fastOutSlowIn），
/// 返回时反向；封面另有 Hero 飞行（tag 见 [coverHeroTag]）。两边一起才有
/// 「详情页像抽屉一样弹出、封面长大」的效果——参照 ZeroBit 的播放页转场。
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
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.2),
                  end: Offset.zero,
                ).animate(curved),
                child: FadeTransition(opacity: curved, child: child),
              );
            },
      );
}

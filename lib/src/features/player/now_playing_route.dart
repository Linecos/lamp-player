import 'package:flutter/material.dart';

/// 「正在播放」页的转场：从下方 20% 处滑上来（300ms，fastOutSlowIn），
/// 返回时反向；封面另有 Hero 飞行（tag 见 [coverHeroTag]）。两边一起才有
/// 「详情页像抽屉一样弹出、封面长大」的效果。
///
/// **不做整页渐显**（曾经做过）：那会让 Impeller 每帧把整页合成进一张离屏
/// 图层，release 下单张可达几十 MB，快速开关能把内存顶到 GB 级。详见文件内
/// `transitionsBuilder` 的注释。
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
              // 只做位移，**不包 FadeTransition**。
              //
              // 只要整页 opacity 小于 1，Impeller 就得把页面（全屏流光 + 歌词
              // + 频谱 + 大封面）合成进一张离屏图层，一帧一张；release 下这张
              // 图层还带 MSAA / 高精度格式，单张能到几十 MB，回收又滞后于分配。
              // 快速开关几轮就能在任务管理器里看到 GB 级的尖刺。
              // `SlideTransition` 只改矩阵，不分配任何离屏目标。
              //
              // 视觉代价：页面滑上来时不再有透明度渐变。封面 Hero 的飞行层画在
              // Navigator 最上层、不受影响，所以「封面长大、页面从下面顶出来」
              // 的观感还在。要恢复淡入，把下面这行换回
              // `FadeTransition(opacity: curved, child: child)` 即可。
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.2),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              );
            },
      );
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 详情页头部的虚影背景（专辑 / 歌单）：封面放大铺满、取中部、模糊、压暗。
///
/// 三处刻意的选择都是为了性能：
///
/// 1. **解码宽度写死**，不跟实时宽度走。按「尺寸 × 像素比」取 cacheWidth 的话，
///    侧栏展开 / 收起或拖窗口时每一帧都是一个新解码尺寸，等于每帧重解一遍
///    （侧栏那次几百 MB 的尖刺就是这么来的）；
/// 2. **先在小图层上模糊，再整体放大**。`ImageFiltered` 的成本按图层面积算，
///    在 480 的方块上做一次模糊，再 cover 放大到全宽：糊度翻了几倍，
///    成本却只有全尺寸的四分之一；
/// 3. **整块 RepaintBoundary**。背景是静态的，Skia 会缓存这张模糊，
///    下面列表怎么滚都不会重算。
class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({super.key, this.coverPath, this.fallbackColor});

  final String? coverPath;

  /// 没有封面时垫的底色；不传就用 `surfaceContainerHigh`
  final Color? fallbackColor;

  /// 模糊前的图层边长（逻辑像素）。放大倍率 ≈ 内容区宽度 / 这个值。
  static const double _baseSide = 480;

  /// 模糊半径（作用在 [_baseSide] 的图层上）。
  ///
  /// 放大到全宽后视觉上大约 ×2.5；再低就只剩双线性放大的块感，看不出是封面。
  static const double _blurSigma = 3.5;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 页面底色是 surfaceContainerLow（见 LibraryPage 的 Scaffold），不是 surface：
    // 拿 surface 去渐隐，深色模式下会比页面更黑、浅色模式下更白，
    // 底部就多出一条色带。
    final String? path = coverPath;
    final bool hasCover = path != null && path.isNotEmpty;
    return ClipRect(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (hasCover)
              ExcludeSemantics(
                child: FittedBox(
                  // cover：方形封面铺满宽横幅，等于只露出中间那一条
                  fit: BoxFit.cover,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: _blurSigma,
                      sigmaY: _blurSigma,
                    ),
                    child: SizedBox(
                      width: _baseSide,
                      height: _baseSide,
                      child: Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        // 固定解码宽度：这块背景永远按这一档解
                        cacheWidth: _baseSide.round(),
                        filterQuality: FilterQuality.low,
                      ),
                    ),
                  ),
                ),
              )
            else
              ColoredBox(color: fallbackColor ?? scheme.surfaceContainerHigh),
            // 整体压暗：往页面底色靠，深浅主题下文字都还压得住
            ColoredBox(
              color: scheme.surfaceContainerLow.withValues(
                alpha: hasCover ? 0.55 : 0.0,
              ),
            ),
            // 只做下面这一条：从上往下越来越实，到底部完全化进页面底色，
            // 和下面的曲目列表接上。
            //
            // 用多个停靠点逐段加速，而不是「中部才开始变、然后一路到底」：
            // 少一个停靠点时，alpha 的斜率会在起点处突然从 0 变成正数，
            // 人眼对这种斜率突变很敏感——看起来就是一道横向的分界线。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    scheme.surfaceContainerLow.withValues(alpha: 0),
                    scheme.surfaceContainerLow.withValues(alpha: 0.1),
                    scheme.surfaceContainerLow.withValues(alpha: 0.3),
                    scheme.surfaceContainerLow.withValues(alpha: 0.62),
                    scheme.surfaceContainerLow,
                  ],
                  stops: const <double>[0, 0.34, 0.6, 0.84, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

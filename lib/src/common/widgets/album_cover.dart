import 'dart:io';

import 'package:flutter/material.dart';

/// 专辑封面缩略图：有缓存文件就显示图片，否则回退到音符 / 播放中图标。
///
/// 只接收文件路径，不依赖曲目模型，任何页面都能复用。
class AlbumCover extends StatelessWidget {
  const AlbumCover({
    super.key,
    this.path,
    this.size = 40,
    this.radius = 12,
    this.playing = false,
    this.fallbackIcon,
  });

  /// 封面缓存文件路径；空字符串或 `null` 表示没有封面。
  final String? path;
  final double size;
  final double radius;

  /// 播放中时回退图标换成跳动的均衡器，与列表高亮保持一致。
  final bool playing;

  /// 没有封面时的回退图标；为空时按 [playing] 自动选择。
  final IconData? fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final double pixels = MediaQuery.devicePixelRatioOf(context) * size;
    final String? coverPath = path;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: coverPath == null || coverPath.isEmpty
            ? _fallback(context)
            : _CoverImage(
                file: File(coverPath),
                cacheWidth: pixels.round().clamp(32, 1024),
                fallback: _fallback(context),
              ),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        fallbackIcon ?? (playing ? Icons.graphic_eq : Icons.music_note),
        size: size * 0.5,
        color: playing ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 图片存在性在构建时同步判断：虚拟列表里避免每行先闪一下空容器。
class _CoverImage extends StatelessWidget {
  const _CoverImage({
    required this.file,
    required this.cacheWidth,
    required this.fallback,
  });

  final File file;
  final int cacheWidth;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    if (!file.existsSync()) {
      return fallback;
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          fallback,
    );
  }
}

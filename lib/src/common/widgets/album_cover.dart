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

/// 图片存在性只在路径变化时同步判断一次：虚拟列表里避免每行先闪一下空容器，
/// 也避免播放进度刷新时反复做同步磁盘检查。
class _CoverImage extends StatefulWidget {
  const _CoverImage({
    required this.file,
    required this.cacheWidth,
    required this.fallback,
  });

  final File file;
  final int cacheWidth;
  final Widget fallback;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  /// 最近确认存在的封面路径：同一张封面在列表里出现几十次时只做一次磁盘检查，
  /// 网络盘上每行一次同步 IO 会直接掉帧
  ///
  /// 上限内按「最久没用」淘汰，不是整体清空：清空等于让缓存里的每一张封面
  /// 都重新做一次 `existsSync`，在机械盘 / 网络盘上正好卡在滚动时掉帧。
  /// `Set` 是 `LinkedHashSet`，插入有序，命中后移到末尾即为 LRU。
  static final Set<String> _knownExisting = <String>{};

  static const int _maxKnownExisting = 512;

  late bool _exists;

  bool _resolveExists() {
    final String path = widget.file.path;
    if (_knownExisting.remove(path)) {
      _knownExisting.add(path);
      return true;
    }
    final bool exists = widget.file.existsSync();
    if (exists) {
      if (_knownExisting.length >= _maxKnownExisting) {
        _knownExisting.remove(_knownExisting.first);
      }
      _knownExisting.add(path);
    }
    return exists;
  }

  @override
  void initState() {
    super.initState();
    _exists = _resolveExists();
  }

  @override
  void didUpdateWidget(_CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _exists = _resolveExists();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_exists) {
      return widget.fallback;
    }
    return Image.file(
      widget.file,
      fit: BoxFit.cover,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          widget.fallback,
    );
  }
}

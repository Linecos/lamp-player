import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'cover_shape.dart';

/// 封面「飞入正在播放页」的 Hero tag：播放条与正在播放页两处必须一致。
const String coverHeroTag = 'now-playing-cover';

/// 专辑封面缩略图：有缓存文件就显示图片，否则回退到音符 / 播放中图标。
///
/// 只接收文件路径，不依赖曲目模型，任何页面都能复用。
/// 设置里打开「圆形封面」后，圆角自动变成 [size] 的一半（即正圆）。
///
/// [animateOnChange] 打开后（播放条 / 正在播放页这种「一张图长期占位、换歌时
/// 换内容」的地方），路径变化不会直接跳变：旧封面留在原地，新封面从略大的
/// 比例淡入并收到原位，缓入缓出。列表 / 网格里不要开：那些位置的 State 会被
/// 复用给别的曲目，滚动时一路都在放动画。
class AlbumCover extends StatefulWidget {
  const AlbumCover({
    super.key,
    this.path,
    this.size = 40,
    this.radius = 12,
    this.playing = false,
    this.fallbackIcon,
    this.animateOnChange = false,
    this.transitionDuration = const Duration(milliseconds: 340),
    this.transitionScale = 1.06,
  });

  /// 封面缓存文件路径；空字符串或 `null` 表示没有封面。
  final String? path;
  final double size;
  final double radius;

  /// 播放中时回退图标换成跳动的均衡器，与列表高亮保持一致。
  final bool playing;

  /// 没有封面时的回退图标；为空时按 [playing] 自动选择。
  final IconData? fallbackIcon;

  /// 换图时做「收进来 + 淡入」的过渡（见类注释，列表里别开）。
  final bool animateOnChange;

  /// 过渡时长
  final Duration transitionDuration;

  /// 新封面淡入时的起始缩放：1.0 表示不做缩放动画。幅度大了像「弹出来」，
  /// 1.05~1.08 左右是「浮上来落定」
  final double transitionScale;

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover>
    with SingleTickerProviderStateMixin {
  /// 正在显示 / 正在淡入的那张封面
  String? _current;

  /// 过渡期间垫在下面的上一张封面；过渡结束后清空
  String? _outgoing;

  /// 是否正在做换图过渡。`_outgoing` 为 null（从「没有封面」切过来）也要
  /// 淡入，所以不能只靠它判断。
  bool _crossfading = false;

  AnimationController? _fade;

  /// [build] 时记下的像素比：预解码发生在 [didUpdateWidget]，那里读
  /// MediaQuery 会往 element 上挂依赖，只能用上一次渲染时的值
  double _devicePixelRatio = 1;

  /// 连切时只认最后一次：每次请求自增，异步回调回来对不上就丢弃
  int _token = 0;

  /// 新图迟迟解码不出来时的兜底，避免一直卡在旧封面上
  Timer? _waitTimer;

  ImageStream? _pendingStream;
  ImageStreamListener? _pendingListener;

  AnimationController get _fadeCtrl => _fade ??= AnimationController(
    vsync: this,
    duration: widget.transitionDuration,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    _current = widget.path;
  }

  @override
  void didUpdateWidget(AlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      if (widget.animateOnChange) {
        _scheduleSwitch(widget.path);
      } else {
        // 关掉动画时 state 不参与渲染（build 直接用 widget.path），
        // 但得跟上，之后若打开开关才不会拿旧路径当起点
        _current = widget.path;
        _outgoing = null;
        _crossfading = false;
      }
    }
    if (oldWidget.transitionDuration != widget.transitionDuration) {
      _fade?.duration = widget.transitionDuration;
    }
  }

  @override
  void dispose() {
    _token++;
    _waitTimer?.cancel();
    _releasePending();
    _fade?.dispose();
    super.dispose();
  }

  /// 等新封面第一帧解码好再切换：反过来的话，淡入的头几帧是空白的，
  /// 在大封面上就是一次明显的闪烁。
  void _scheduleSwitch(String? path) {
    final int token = ++_token;
    _waitTimer?.cancel();
    _releasePending();

    if (path == null || path.isEmpty || !File(path).existsSync()) {
      // 空路径 / 文件不在：回退图标是同步画出来的，不需要等
      _applySwitch(token, path);
      return;
    }

    final ImageProvider provider = _providerFor(path);
    final ImageStream stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    // 图已经在缓存里时这里会同步回调——也就是在 [didUpdateWidget] 的 build
    // 途中 setState。当前 element 本来就在这次 build 的作用域内，框架允许，
    // 换图当场生效，不多等一帧。
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        stream.removeListener(listener);
        _applySwitch(token, path);
      },
      onError: (Object error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        _applySwitch(token, path);
      },
    );
    stream.addListener(listener);
    _pendingStream = stream;
    _pendingListener = listener;

    // 网络盘 / 大图偶尔解码得慢，等太久不如直接换、让 Image 自己填进来
    _waitTimer = Timer(const Duration(milliseconds: 250), () {
      _releasePending();
      _applySwitch(token, path);
    });
  }

  void _releasePending() {
    final ImageStream? stream = _pendingStream;
    final ImageStreamListener? listener = _pendingListener;
    _pendingStream = null;
    _pendingListener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
  }

  void _applySwitch(int token, String? path) {
    if (!mounted || token != _token) {
      return;
    }
    _waitTimer?.cancel();
    final String? previous = _current;
    if (previous == path) {
      // 解码回调和兜底定时器会先后到达同一个目标。此时过渡可能正跑到一半，
      // 绝不能顺手把过渡层撤掉——那会让动画从中间直接跳到终点
      return;
    }
    setState(() {
      _outgoing = previous;
      _current = path;
      _crossfading = true;
    });
    final AnimationController controller = _fadeCtrl;
    controller.duration = widget.transitionDuration;
    controller.forward(from: 0).whenComplete(() {
      if (!mounted) {
        return;
      }
      setState(() {
        _outgoing = null;
        _crossfading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final String? shown = widget.animateOnChange ? _current : widget.path;
    final String? outgoing = widget.animateOnChange ? _outgoing : null;
    final bool crossfading = widget.animateOnChange && _crossfading;

    return ValueListenableBuilder<bool>(
      valueListenable: circularCovers,
      // 只换圆角、不换子树：ValueListenableBuilder 重建的仍是同一个
      // ClipRRect，图片状态（已解码的那帧）不会被丢掉
      builder: (BuildContext context, bool circular, Widget? child) {
        // 缩小过程中的封面会溢出边框，裁剪必须在过渡层外面
        final Widget contents = SizedBox(
          width: widget.size,
          height: widget.size,
          child: crossfading
              ? _crossfade(context, shown, outgoing)
              : _picture(context, shown, const ValueKey<String>('current')),
        );
        if (!circular) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: contents,
          );
        }
        // 圆形要用 `ClipOval`，不能写成「半径 = size / 2」的 `ClipRRect`：
        // Hero 飞行时封面会被塞进「动画尺寸」的紧约束（56 的封面铺到 340），
        // 而 size 还是 56、半径算出来 28，画出来就是个 340 的圆角方块——
        // 退出播放页时看到「圆封面变方」的就是这一帧。ClipOval 跟着实际尺寸走，
        // 盒子被拉多大都是正圆。
        return ClipOval(child: contents);
      },
    );
  }

  Widget _crossfade(BuildContext context, String? shown, String? outgoing) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 旧封面不跟着淡出，只负责垫底：上下两层都半透明时，中间会漏出
        // 卡片底色的灰雾。新封面从 1.12 倍收到 1.0，全程盖满整个方框。
        // 从「没有封面」切过来时这里就是个回退图标，不至于闪一下空白。
        _picture(context, outgoing, const ValueKey<String>('outgoing')),
        AnimatedBuilder(
          key: const ValueKey<String>('incoming'),
          animation: _fadeCtrl,
          // 封面子树挂在 child 上：过渡期间每帧只换透明度和变换矩阵，
          // 不去重建图片 / 重新算磁盘存在性
          child: _picture(context, shown, const ValueKey<String>('current')),
          builder: (BuildContext context, Widget? child) {
            // 缓入缓出，不是一上来就最快：起点和终点都慢下来，中途才走完
            // 大半，观感才是「淡过来」而不是「猛一下盖上再定住」
            final double t = Curves.easeInOutCubic.transform(_fadeCtrl.value);
            return Opacity(
              // 从全透明淡起。旧封面在下面不透明垫着，透出的始终是上一张
              // 封面本身，不会漏底色
              opacity: t,
              child: Transform.scale(
                scale:
                    widget.transitionScale + (1 - widget.transitionScale) * t,
                child: child,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _picture(BuildContext context, String? path, Key key) {
    final double pixels = _devicePixelRatio * widget.size;
    final String? coverPath = path;
    return SizedBox(
      key: key,
      width: widget.size,
      height: widget.size,
      child: coverPath == null || coverPath.isEmpty
          ? _fallback(context)
          : _CoverImage(
              file: File(coverPath),
              cacheWidth: pixels.round().clamp(32, 1024),
              fallback: _fallback(context),
            ),
    );
  }

  /// 与 `Image.file(cacheWidth:)` 完全一致的提供者，预解码才能命中同一份
  /// 图片缓存——否则这张图会被解码两遍，切歌瞬间多一次重活。
  ImageProvider _providerFor(String path) {
    final double pixels = _devicePixelRatio * widget.size;
    return ResizeImage.resizeIfNeeded(
      pixels.round().clamp(32, 1024),
      null,
      FileImage(File(path)),
    );
  }

  Widget _fallback(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool playing = widget.playing;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        widget.fallbackIcon ?? (playing ? Icons.graphic_eq : Icons.music_note),
        size: widget.size * 0.5,
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

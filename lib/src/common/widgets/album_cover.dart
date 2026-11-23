import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'cover_shape.dart';

/// 不跟随「圆形封面」设置的实例用它：永远方形，也不会因为设置变化重建
const ValueListenable<bool> _alwaysSquare = AlwaysStoppedAnimation<bool>(false);

/// 封面「飞入正在播放页」的 Hero tag：播放条与正在播放页两处必须一致。
const String coverHeroTag = 'now-playing-cover';

/// 播放岛小封面的边长与圆角。
///
/// 放在共用层是因为飞行 shuttle 也要按它推算两端的圆角（见
/// [coverFlightShuttle]）；两边各写一份数字，改一处就错一处。
const double playerBarCoverSize = 56;

/// 与同为 56 的歌单卡片缩略图统一 20：同尺寸的封面圆角不该有两种。
const double playerBarCoverRadius = 20;

/// 解码宽度的档位（设备像素）：相邻两档差约 12%，肉眼看不出差别。
///
/// 为什么不直接用 `尺寸 × 像素比`：那等于「每个尺寸一份解码结果」。侧边栏
/// 展开 / 收起这种**宽度连续变化**的动画里，卡片宽度每帧都不同 → 每帧给每个
/// 可见封面重新解码一次，快速开合几轮就能堆出几百 MB（解码中间态 + 排队任务），
/// CPU 也跟着飙。分到固定档位后，一档之内的尺寸变化命中同一份解码结果。
const List<int> coverDecodeSteps = <int>[
  32, 40, 48, 56, 64, 72, 80, 96, 112, 128, 144, 160, 176, 192, //
  224, 256, 288, 320, 352, 384, 416, 448, 512, 576, 640, 704, //
  768, 832, 896, 960, 1024,
];

/// 某块封面该按多少像素宽解码：向上取到最近的档位。
int coverDecodeWidth(double logicalSize, double devicePixelRatio) {
  final double pixels = logicalSize * devicePixelRatio;
  for (final int step in coverDecodeSteps) {
    if (pixels <= step) {
      return step;
    }
  }
  return coverDecodeSteps.last;
}

/// 这张图是不是已经解过（或正在解）了，可以直接画出来。
///
/// 不能拿 provider 本身当键：`ResizeImage` 往缓存里塞的是它自己的私有键，
/// 只有先 `obtainKey` 一次才能问到。这两类 provider 的 key 都是同步算出来的，
/// 不涉及 IO，可以放心在构建路径上问。
bool imageAlreadyCached(ImageProvider<Object> provider) {
  bool? cached;
  // `SynchronousFuture.then` 是当场执行完的，回调跑完返回值就有了；
  // 真碰上异步算 key 的 provider 就按「没缓存」处理，顶多多留 100ms。
  unawaited(
    provider.obtainKey(ImageConfiguration.empty).then<void>((Object key) {
      cached = PaintingBinding.instance.imageCache.containsKey(key);
    }),
  );
  return cached ?? false;
}

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
    this.circular = false,
    this.decodeScale = 1,
    this.evictOnDispose,
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

  /// 解码宽度相对显示尺寸的缩放（0.3~1，见 [_AlbumCoverState._decodeWidthFor]）。
  ///
  /// 位图的内存代价是「解码位图 + GPU 纹理」两份，缩到 0.7 就是两边各省一半。
  /// 只给「临时副本」这类看不见解像度的场合用：封面飞行时那一张（[flyCover]
  /// 按小端尺寸传进来，和卡片已解好的那份共用一档，飞完即弃）。**列表、网格、
  /// 详情头部这些常驻位置一律用 1**——圆形头像也不例外：`ClipOval` 只裁掉四个
  /// 角，圆内那部分像素密度一分没省，按 0.75 解等于把位图放大 1.33 倍再画。
  final double decodeScale;

  /// 是否跟随「圆形封面」设置。
  ///
  /// 只有播放岛与正在播放页需要（封面的「主角」位置）；列表行、歌单卡片、
  /// 专辑 / 艺术家页一律方形——一行行圆头像看着比方形更碎，也更容易和行高打架。
  final bool circular;

  /// 卸载时是否把解码结果从图片缓存里摘掉。
  ///
  /// 默认按尺寸决定（见 `_CoverImageState._evictMinSize`）：大图一张顶几十张
  /// 小图，页面关了就该还回去。
  ///
  /// **Hero 飞行层里的那份要传 false**：它是临时副本，和页面 / 播放岛共用
  /// 同一份解码结果；飞行一结束它就卸载，顺手 evict 会把真正落地要显示的那份
  /// 一起清掉——大封面在落地的第一帧退回灰底阴影盘，等重新解码。
  final bool? evictOnDispose;

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

  /// 当前按多少像素宽解码（见 [_decodeWidthFor]）
  int _decodeWidth = 0;

  /// 尺寸变化不超过 20% 就沿用它，只有明显变了才换档。
  ///
  /// 侧边栏展开 / 收起时，卡片宽度会连续变化 10%~20%，每帧都换解码尺寸
  /// 等于每帧把可见封面全部重新解一遍（这正是那个内存 / CPU 尖刺的来源）。
  /// 一代按 20% 的偏差，缩略图放大显示几乎看不出来。
  int _decodeWidthFor(double size) {
    final double shown = size * widget.decodeScale.clamp(0.3, 1.0);
    final int wanted = coverDecodeWidth(shown, _devicePixelRatio);
    final int current = _decodeWidth;
    if (current == 0 || wanted > current * 1.2 || wanted < current / 1.2) {
      _decodeWidth = wanted;
    }
    return _decodeWidth;
  }

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

    /// 自己这一次监听用完了：先清引用再摘监听。
    void settle() {
      if (identical(_pendingStream, stream)) {
        _pendingStream = null;
        _pendingListener = null;
      }
      _removeQuietly(stream, listener);
    }

    // 图已经在缓存里时这里会同步回调——也就是在 [didUpdateWidget] 的 build
    // 途中 setState。当前 element 本来就在这次 build 的作用域内，框架允许，
    // 换图当场生效，不多等一帧。
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        settle();
        _applySwitch(token, path);
      },
      onError: (Object error, StackTrace? stackTrace) {
        settle();
        _applySwitch(token, path);
      },
    );
    // **先挂引用、再 addListener**：图已在缓存里时回调会在 addListener 里同步
    // 跑完（回调自己摘掉监听，流随即 dispose）。挂晚了就等于留下一对指向
    // 「已经 dispose 的流」的过期引用，之后 dispose 再摘一次会抛
    // `Bad state: Stream has been disposed`——而它发生在 element 卸载途中，
    // 会把框架的元素簿记整个搞坏（实测连锁出 Duplicate GlobalKey、
    // RenderFlex 溢出、播放岛渲染缺块，重启才能恢复）
    _pendingStream = stream;
    _pendingListener = listener;
    stream.addListener(listener);

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
      _removeQuietly(stream, listener);
    }
  }

  /// 摘监听，且容忍「流已经 dispose」。
  ///
  /// 一个 ImageStream 在「加过监听、又把监听全摘掉、且没有 keepAlive 句柄」
  /// 之后就算 dispose 了。我们自己摘掉最后一次监听就会造成这个状态，缓存淘汰
  /// 也会。此时再摘一次会抛 `Bad state: Stream has been disposed`，而这个
  /// 异常如果落在 element 卸载途中，会中断框架的卸载流程、把元素簿记搞坏
  /// （2026-11-09 的现场日志：随后出现 Duplicate GlobalKey、RenderFlex 溢出、
  /// 刷屏的 `_elements.contains(element)` 断言，播放岛从此渲染缺块）。
  static void _removeQuietly(ImageStream stream, ImageStreamListener listener) {
    try {
      stream.removeListener(listener);
    } on StateError {
      // 已经 dispose：本来就没有我们的事了
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
      // 不跟随设置的实例直接给一个恒 false 的 listenable：既不会变圆，
      // 也不会因为用户改设置而重建
      valueListenable: widget.circular ? circularCovers : _alwaysSquare,
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
    final String? coverPath = path;
    return SizedBox(
      key: key,
      width: widget.size,
      height: widget.size,
      child: coverPath == null || coverPath.isEmpty
          ? _fallback(context)
          : _CoverImage(
              file: File(coverPath),
              cacheWidth: _decodeWidthFor(widget.size),
              size: widget.size,
              evictOnDispose: widget.evictOnDispose,
              fallback: _fallback(context),
            ),
    );
  }

  /// 与 `Image.file(cacheWidth:)` 完全一致的提供者，预解码才能命中同一份
  /// 图片缓存——否则这张图会被解码两遍，切歌瞬间多一次重活。
  ImageProvider _providerFor(String path) {
    return ResizeImage.resizeIfNeeded(
      _decodeWidthFor(widget.size),
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
    required this.size,
    required this.fallback,
    this.evictOnDispose,
  });

  final File file;
  final int cacheWidth;

  /// 逻辑显示边长：只用来判断「这张封面值不值得在卸载时把解码结果扔掉」
  final double size;

  /// 覆盖「按尺寸决定要不要 evict」的默认行为
  final bool? evictOnDispose;

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

  /// 滚动中给新出现的封面留的冷静期：一闪而过、还没画出来就被扔掉的行，
  /// 不必真的去读盘 + 解码。
  ///
  /// 只在「最近一层滚动视图正在滚动」时才生效：静止时新出现的一行（窗口变大、
  /// 切分区、首次进列表）当帧就解码，不会平白多出一段灰底。
  static const Duration _scrollDecodeDelay = Duration(milliseconds: 100);

  /// 逻辑边长不小于它的封面，卸载时把解码结果从图片缓存里摘掉。
  ///
  /// 列表行（44）和网格卡片（190）留着：回滚时零成本，40MB 上限也装得下。
  /// 详情头图（240）、播放页大图（200–440）一张顶几十张小图，而且同一个页面
  /// 里只会出现一次，关掉就该还回去。
  static const double _evictMinSize = 200;

  late bool _exists;

  /// 这一刻该画哪份解码结果（也是卸载时要从缓存里摘掉的那个）
  ImageProvider? _provider;

  /// 冷静期到点的定时器
  Timer? _delay;

  /// 到点没有：false 时根本不建 `Image`，也就不会有解码
  bool _ready = false;

  /// 还没跑过第一次判定：`Scrollable.maybeOf` 要建立依赖，得等 initState 走完
  bool _needsRefresh = true;

  bool get _evictOnDispose =>
      widget.evictOnDispose ?? widget.size >= _evictMinSize;

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

  /// 与 `Image.file(cacheWidth:)` 完全一致的提供者：这样 `containsKey`、
  /// 预解码和真正去解的那一份才是同一个键。
  ImageProvider _providerFor() => ResizeImage.resizeIfNeeded(
    widget.cacheWidth,
    null,
    FileImage(widget.file),
  );

  bool get _scrolling {
    try {
      return Scrollable.maybeOf(context)?.position.isScrollingNotifier.value ??
          false;
    } catch (_) {
      // position 还没挂上（极早期的构建）：按静止处理，别把图拖没了
      return false;
    }
  }

  void _refresh() {
    _delay?.cancel();
    _delay = null;
    _ready = false;
    final ImageProvider? previous = _provider;
    _provider = null;
    final ImageProvider provider = _providerFor();
    // 换了一张图（或换了档）：大图的旧解码结果立刻还回去
    if (previous != null && previous != provider && _evictOnDispose) {
      unawaited(previous.evict());
    }
    if (!_exists) {
      return;
    }
    _provider = provider;
    // 已经解过（含正在解）：冷静期没有意义，当帧画出来
    if (imageAlreadyCached(provider)) {
      _ready = true;
      return;
    }
    if (!_scrolling) {
      _ready = true;
      return;
    }
    _delay = Timer(_scrollDecodeDelay, () {
      if (!mounted) {
        return;
      }
      setState(() => _ready = true);
    });
  }

  @override
  void initState() {
    super.initState();
    _exists = _resolveExists();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_needsRefresh) {
      return;
    }
    _needsRefresh = false;
    _refresh();
  }

  @override
  void didUpdateWidget(_CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool changed =
        oldWidget.file.path != widget.file.path ||
        oldWidget.cacheWidth != widget.cacheWidth ||
        oldWidget.size != widget.size;
    if (changed) {
      _exists = _resolveExists();
      _refresh();
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _delay = null;
    final ImageProvider? provider = _provider;
    _provider = null;
    if (provider != null && _evictOnDispose) {
      unawaited(provider.evict());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = _provider;
    if (!_exists || !_ready || provider == null) {
      return widget.fallback;
    }
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          widget.fallback,
    );
  }
}

/// 飞行 shuttle 垫底的小图：就是播放岛正在显示的那一份。
///
/// 播放页大图（380~440）和播放岛（56）不是同一档解码，而大图保留到页面
/// 卸载为止、卸载即 evict（见 `_CoverImageState._evictMinSize`）——所以
/// **每次点开播放页都是冷解码**。飞行开始的头一两帧大图还没解出来，两端子树
/// 又都被 Hero 换成了占位，画面上就是「点开播放详情页，封面闪一下」。
///
/// 这里重挂一份播放岛尺寸的 [AlbumCover]：解码宽度算的是同一套（`size` 56 +
/// 当前像素比），缓存键与播放岛上那份一致，当帧直接命中；shuttle 再把它拉到
/// 当前飞行框。大图解好就盖上去，中间不做任何淡入淡出（理由见
/// [coverFlightShuttle]）。飞行框一开始只有 56，这时候它还是清晰的原图。
///
/// [circular] 必须与真封面一致：垫底那份是**单独一套裁剪**，忘了跟上的话，
/// 圆形封面起飞的头几帧是一块方图（大图还没解出来，露出来的正是它）。
Widget coverFlightBackdrop({
  required String? path,
  required bool playing,
  bool circular = false,
}) {
  return AlbumCover(
    path: path,
    size: playerBarCoverSize,
    // 圆角交给 shuttle 按进度裁，这里不自带
    radius: 0,
    // 圆形封面是 `ClipOval`，不是「半径 = 边长一半」的圆角框
    circular: circular,
    playing: playing,
    // 临时副本：卸载时不能把播放岛那份正在用的解码结果一起摘掉
    evictOnDispose: false,
  );
}

/// 大封面的投影。
///
/// 正在播放页的封面本体与它的 Hero 飞行 shuttle 共用这一份配置：两边必须
/// 逐像素一致，否则飞行落地的那一帧阴影会「跳」一下。
///
/// 圆角跟随 [circularCovers]：圆形封面时阴影容器也要跟着圆，矩形阴影会在
/// 圆角外露出一圈方形的光晕。
class CoverShadow extends StatelessWidget {
  const CoverShadow({
    super.key,
    required this.radius,
    required this.child,
    this.circular = false,
  });

  /// 是否跟随「圆形封面」设置（只有正在播放页的封面需要）
  final bool circular;

  /// 阴影在封面之外还占多大。
  ///
  /// `blurRadius: 28`（σ≈16.6）的可见尾巴约 3σ，加上 `spreadRadius: 2` 与
  /// `offset(10, 12)`，64 能把整个人影包进来。Hero 飞行时靠它给阴影留地方：
  /// 边界盒小于这笔外扩，模糊的尾巴会被 RepaintBoundary 裁掉。
  static const double spread = 64;

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: circular ? circularCovers : _alwaysSquare,
      builder: (BuildContext context, bool circular, Widget? child) {
        return Stack(
          // 阴影本来就画在封面外面，硬裁会把四边切掉
          clipBehavior: Clip.none,
          children: <Widget>[
            // 阴影单独一层。`Container(decoration)` 把阴影和内容绑在同一个
            // RenderObject 上：Hero 落地、换歌这类「内容换了」的时刻会把阴影
            // 一起标脏，于是要重做一次 28px 高斯模糊。分成独立图层后，只要
            // 尺寸和圆角没变就复用已经光栅化的那一层。
            //
            // 这一层必须**比封面大一圈**（每边 [CoverShadow.spread]）：
            // `RepaintBoundary` 的边界就是它的光栅范围，用 `Positioned.fill`
            // 铺满封面的话，模糊到封面外的那圈尾巴会被齐边裁掉。飞行时
            // 的 shuttle 是留了余量的，于是落地那一帧阴影突然收窄一圈，
            // 看着就是「最后卡一下 / 闪一下」——两边必须按同一尺寸画
            Positioned(
              left: -CoverShadow.spread,
              top: -CoverShadow.spread,
              right: -CoverShadow.spread,
              bottom: -CoverShadow.spread,
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.all(CoverShadow.spread),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: circular ? BoxShape.circle : BoxShape.rectangle,
                      // 与封面自身的圆角一致，否则角上会露一圈光晕
                      borderRadius: circular
                          ? null
                          : BorderRadius.circular(radius),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          // Colors.black.withValues(alpha: 0.35)
                          color: Color(0x59000000),
                          blurRadius: 28,
                          spreadRadius: 2,
                          offset: Offset(10, 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            child ?? const SizedBox.shrink(),
          ],
        );
      },
      child: child,
    );
  }
}

/// 封面 Hero 飞行时的 shuttle。
///
/// 正反两个方向都用播放页那张大图：收起时的目标在播放条，那边只有 56px 小图，
/// 默认 shuttle 拿它放大时一路发虚。
///
/// 阴影要**跟着一起飞**。Hero 飞行时两端子树都会换成占位 SizedBox，阴影只挂在
/// 页面那棵子树上的话，整个飞行过程里画面上没有一圈暗边，落地那一帧才由页面
/// 补出来——看起来就是「封面先飞过去，再原地长出阴影」。
///
/// 代价要控住：飞行框的边长每帧都在变，把阴影直接铺进去等于每帧按新尺寸重做
/// 一次 28px 高斯模糊。所以按大图尺寸备一份「带阴影的封面」，外面套固定尺寸的
/// `RepaintBoundary`，每帧只改一个缩放矩阵。
///
/// 圆角按两端插值：shuttle 是把大图缩放绘制，圆角若写死成大图的 28，缩到播放岛
/// 那一端只剩 `28 × 56 / 340 ≈ 4.6`（看着比方块略圆），落地那一帧才「啪」一下
/// 变成 20。这里按当前飞行框反推进度、把圆角按 px 插值，两端都与真实封面一致。
/// 阴影**不跟着**插值：它自带 RepaintBoundary，每帧改半径就得重做一次高斯模糊，
/// 而阴影本来就是模糊的，圆角差几像素看不出来。
///
/// [cover] 要传**不带自己圆角**的那份（`radius: 0`）：内层若先裁成 28，小图那端
/// 需要的圆角（换算到 shuttle 坐标约 120）会被内层 28 抢先裁掉，等于白算。
///
/// [backdrop] 垫在 [cover] 底下（见 [coverFlightBackdrop]）：大图还没解出来的
/// 头几帧先拿它顶上，解好之后被 [cover] 直接盖住。
Widget coverFlightShuttle({
  required double size,
  required Widget cover,
  Widget? backdrop,
  ValueListenable<double>? turns,
  bool circular = false,
  double fromSize = 0,
  double fromRadius = 0,
  double toRadius = 0,
}) {
  // 两张图同一个盒子、同一份裁剪：垫底那张按自己的尺寸画，再整体拉到飞行框
  final Widget picture = backdrop == null
      ? cover
      : Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // `BoxFit.contain`：垫底那份是正方形，拉到飞行框正好铺满、不变形
            FittedBox(fit: BoxFit.contain, child: backdrop),
            cover,
          ],
        );
  // 圆形封面飞行途中接着转：shuttle 是独立子树，不自己盯着相位的话，
  // 退场第一帧就会退回正面（「先回到最开始的样子再退出」就是这一帧）
  final Widget art = turns == null
      ? picture
      : ValueListenableBuilder<double>(
          valueListenable: turns,
          builder: (BuildContext context, double value, Widget? child) =>
              Transform.rotate(
                key: const ValueKey<String>('cover-shuttle-spin'),
                angle: value * math.pi * 2,
                child: child,
              ),
          child: picture,
        );
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double side = constraints.biggest.shortestSide;
      final double scale = size <= 0 || side <= 0 ? 1 : side / size;
      // 飞行框边长随进度线性变化（两端都是正方形），据此反推进度：两端行程
      // 互逆，正飞反飞都成立，不用再往里传 Animation
      final double t = fromSize > 0 && size > fromSize && side > 0
          ? ((side - fromSize) / (size - fromSize)).clamp(0.0, 1.0)
          : 1;
      // 按逻辑像素插值，再换算回 shuttle 坐标（缩放前的边长）
      final double localRadius =
          (fromRadius + (toRadius - fromRadius) * t) * size / side;
      final Widget shaded = toRadius > 0 && localRadius > 0
          ? ClipRRect(
              borderRadius: BorderRadius.circular(localRadius),
              child: art,
            )
          : art;
      return OverflowBox(
        alignment: Alignment.center,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        // 缩放围着盒子中心走，而封面在盒子正中，于是封面正好铺满飞行框、
        // 阴影溢出到框外，落点与页面那棵子树逐像素对齐
        child: Transform.scale(
          scale: scale,
          child: SizedBox(
            width: size + CoverShadow.spread * 2,
            height: size + CoverShadow.spread * 2,
            child: RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.all(CoverShadow.spread),
                child: CoverShadow(
                  radius: 28,
                  circular: circular,
                  child: shaded,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import '../../common/ui_clock.dart';
import '../../rust/api/lyrics.dart' as lyrics_api;

/// 歌词视图：居中、当前行逐字染色、上下淡出。
///
/// 进度只从 [position] 拿（播放服务每 500ms 推一次），行内用 [UiClock] 插值到
/// 30fps，逐字染色才不会一顿一顿。整列歌词一次性建好（一首歌通常 < 200 行），
/// 换来的是变高行也能精确居中——虚拟列表做不到这一点。
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.lines,
    required this.position,
    required this.playing,
    required this.onSeek,
    this.edgeFadeBand = 0,
    this.revealAlignment = 0.5,
  });

  final List<lyrics_api.LyricLine> lines;

  /// 播放进度（秒）
  final ValueListenable<double> position;

  /// 是否正在播放：暂停时停止插值，避免歌词继续走
  final ValueListenable<bool> playing;

  final Future<void> Function(double seconds) onSeek;

  /// 底部必须淡干净的额外高度：正在播放页的频谱丝带压在歌词下层，
  /// 丝带有多高，底部淡出就要盖过它，滚下来的文字才不会糊在柱子上。
  final double edgeFadeBand;

  /// 当前行停在视口的哪个位置（0 = 顶、1 = 底）。
  ///
  /// 正在播放页里歌词要和封面中心线对齐，封面在左栏上方、中心线通常高于歌词区
  /// 中线，所以传一个小于 0.5 的值。
  final double revealAlignment;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

/// 上下淡出的渐变 stops（两端各用三段缓冲，中间全不透明）。
///
/// 直线渐变在「透明→不透明」走完的那一点上斜率突变，文字笔画从糊到清楚是
/// 一下子的，看着就是一条看不见的边。改成两段缓冲（0.3 处 12%、0.7 处 70%）
/// 后，alpha 是 S 形收尾，边界感就散了。
///
/// 底部一段按「丝带高度 [band] + 随高度缩放的过渡」算：最小窗口（900×560）里
/// 歌词区只有 370 高，用固定值会把整个下半屏吃掉。过渡段最少 [_fadeRampMin]，
/// 保证边框上滚动时不是一下子黑掉。
@visibleForTesting
List<double> lyricFadeStops({
  required double height,
  required double top,
  required double band,
}) {
  if (height <= 0) {
    return const <double>[0, 0, 0, 0, 1, 1, 1, 1];
  }
  final double ramp = (height * _fadeRampRatio).clamp(
    _fadeRampMin,
    _fadeRampMax,
  );
  final double bottom = (band + ramp).clamp(0.0, height);
  final double t = (top / height).clamp(0.0, 1.0);
  final double b = (1 - bottom / height).clamp(0.0, 1.0);
  // 极矮的歌词区里两段会越过对方，取中点收成一条硬边，别让 stops 反序
  if (t > b) {
    final double mid = (t + b) / 2;
    return <double>[0, mid, mid, mid, mid, mid, mid, 1];
  }
  return <double>[
    0,
    t * 0.3,
    t * 0.7,
    t,
    b,
    b + (1 - b) * 0.3,
    b + (1 - b) * 0.7,
    1,
  ];
}

/// 顶部淡出高度：藏住被视口上沿硬切掉的半行，再往外留一截给渐变
const double _fadeTop = 76;

/// 换行时的逐行回弹：参数取自 ZeroBit 的 `SpringListView`。
///
/// 换行时整列 `jumpTo` 到新行居中，每行再用 `Transform` 推回 `deltaY`（视觉上
/// 等于没动），随后按行序错峰弹回 0。全局积分一个弹簧做不到：那是整块刚性平移。
const int _lineStepDelayMs = 26;

/// 弹簧收尾容差：0.5px / 0.1px/s 以内掐断，免得一直抖
const Tolerance _springTolerance = Tolerance(distance: 0.5, velocity: 0.1);

/// 刚度 / 阻尼比随行在可视区里的位置递减：越靠下越软、越慢
double _springStiffness(double ratio) => 175 - 20 * ratio;
double _springDamping(double ratio) => 0.86 - 0.08 * ratio;

/// 一次性大跳（点歌词跳转、切歌定位）用的时长与曲线。
///
/// 那种场景位移动辄几百像素，弹簧反而显得拖；短促地滑过去更干脆。
const Duration _jumpDuration = Duration(milliseconds: 420);
const Curve _jumpCurve = Curves.easeInOutCubic;

/// 底部过渡段：随歌词区高度缩放，并夹在 [_fadeRampMin]~[_fadeRampMax]
const double _fadeRampRatio = 0.2;
const double _fadeRampMin = 56;
const double _fadeRampMax = 110;

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _scroll = ScrollController();

  /// 插值后的进度：每帧更新，只被当前行监听
  final ValueNotifier<double> _smooth = ValueNotifier<double>(0);

  /// [_base] 取自哪个时刻（[UiClock] 秒）：插值从这一时刻往后推算
  double _baseAt = 0;

  /// 是否正在听 [UiClock]（播放中且有歌词才需要）
  bool _clockOn = false;

  /// 上下淡出的遮罩（[ShaderMask] 的 dstIn 渐变）：按歌词区尺寸缓存。
  ///
  /// `shaderCallback` 每次绘制都会调一次，逐字染色 30fps 重绘时每帧新建一个
  /// 着色器，正是流光背景踩过的坑（Skia 缓存永远命中不了）。
  Rect? _maskRect;
  Shader? _maskShader;

  /// 缓存对应的丝带高度：切到没频谱的界面时要重建
  double _maskBand = -1;

  late List<GlobalKey> _keys;

  /// 每行外层（[Transform]）的 key。不能用正文那个：正文在 Transform 里面，
  /// `getOffsetToReveal` 会把弹簧位移一起算进去，目标位置就跟着弹簧飘了
  late List<GlobalKey> _lineKeys;

  /// 换行信号：整列已经 `jumpTo` 到位，各行按这个 `deltaY` 把自己推回去再弹回
  final ValueNotifier<_LineJump> _jump = ValueNotifier<_LineJump>(
    _LineJump.none,
  );
  int _jumpId = 0;

  double _base = 0;
  int _active = -1;
  bool _playing = false;
  bool _userScrolling = false;
  Timer? _resumeTimer;

  /// 正在自己 jumpTo：这期间滚动通知不是用户动作
  bool _driving = false;

  @override
  void initState() {
    super.initState();
    _keys = _buildKeys();
    _lineKeys = _buildKeys();
    _base = widget.position.value;
    _baseAt = UiClock.instance.seconds;
    _smooth.value = _base;
    _active = _indexAt(_base);
    _playing = widget.playing.value;
    widget.position.addListener(_onPosition);
    widget.playing.addListener(_onPlaying);
    _syncClock();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToActive(animate: false),
    );
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _keys = _buildKeys();
      _lineKeys = _buildKeys();
      _active = -1;
      _smooth.value = _base;
      _active = _indexAt(_base);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActive(animate: false),
      );
    }
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
      _onPosition();
    }
    if (oldWidget.playing != widget.playing) {
      oldWidget.playing.removeListener(_onPlaying);
      widget.playing.addListener(_onPlaying);
      _onPlaying();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    widget.playing.removeListener(_onPlaying);
    _resumeTimer?.cancel();
    if (_clockOn) {
      UiClock.instance.removeListener(_onTick);
    }
    _scroll.dispose();
    _smooth.dispose();
    _jump.dispose();
    super.dispose();
  }

  List<GlobalKey> _buildKeys() =>
      List<GlobalKey>.generate(widget.lines.length, (_) => GlobalKey());

  void _syncClock() {
    // 逐字插值、以及「什么时候换行」，都靠这个 tick 推进
    final bool on = _playing && widget.lines.length > 1;
    if (on == _clockOn) {
      return;
    }
    _clockOn = on;
    if (on) {
      _baseAt = UiClock.instance.seconds;
      UiClock.instance.addListener(_onTick);
    } else {
      UiClock.instance.removeListener(_onTick);
    }
  }

  void _onTick() {
    final double now = UiClock.instance.seconds;
    _smooth.value = _base + (now - _baseAt);
    _updateActive();
  }

  void _onPosition() {
    _base = widget.position.value;
    _baseAt = UiClock.instance.seconds;
    _smooth.value = _base;
    _updateActive();
  }

  void _onPlaying() {
    _playing = widget.playing.value;
    // 暂停瞬间以插值结果为准，避免回跳到 500ms 前的旧进度
    _base = _smooth.value;
    _baseAt = UiClock.instance.seconds;
    _syncClock();
  }

  void _updateActive() {
    final int next = _indexAt(_smooth.value);
    if (next == _active) {
      return;
    }
    setState(() => _active = next);
    if (_userScrolling) {
      // 用户还在拖：先别抢，松手 3 秒后再跟回来（见 [_onScrollNotification]）
      return;
    }
    if (_playing) {
      _jumpToActive();
    } else {
      // 暂停时没有 tick，点歌词 / 拖进度条换行只能一次性滑过去
      _scrollToActive();
    }
  }

  /// 二分找最后一条 `time <= position` 的歌词
  int _indexAt(double seconds) => lyricIndexAt(widget.lines, seconds);

  /// 换行：整列瞬间归位，再让每一行自己弹回来（见 [_SpringLyricLine]）。
  void _jumpToActive() {
    if (_active < 0 || _active >= _keys.length || !_scroll.hasClients) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    if (!position.hasPixels) {
      return;
    }
    final double target = _revealOffset(_active);
    if (target.isNaN) {
      return;
    }
    final double clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final double delta = clamped - position.pixels;
    if (delta.abs() < 0.5) {
      return;
    }
    // 拖进度条 / 切歌那种大跳：几百像素的弹簧会拖成慢动作，短促地滑过去
    if (delta.abs() > position.viewportDimension * 0.75) {
      _scrollToActive();
      return;
    }
    _driving = true;
    position.jumpTo(clamped);
    _driving = false;
    final (int top, int bottom) = _visibleSpan(clamped);
    _jump.value = _LineJump(
      id: ++_jumpId,
      deltaY: delta,
      top: top,
      bottom: bottom,
    );
  }

  /// 当前行停在 [LyricsView.revealAlignment] 时屏幕上看得到哪一段行（含首尾）：
  /// 从当前行往外扩，偏移差超过上/下半屏就算出屏
  (int, int) _visibleSpan(double anchorOffset) {
    final double viewport = _scroll.position.viewportDimension;
    final double up = viewport * widget.revealAlignment;
    final double down = viewport * (1 - widget.revealAlignment);
    int top = _active;
    int bottom = _active;
    while (top > 0) {
      final double offset = _revealOffset(top - 1);
      if (offset.isNaN || (anchorOffset - offset).abs() > up) {
        break;
      }
      top -= 1;
    }
    while (bottom < widget.lines.length - 1) {
      final double offset = _revealOffset(bottom + 1);
      if (offset.isNaN || (offset - anchorOffset).abs() > down) {
        break;
      }
      bottom += 1;
    }
    return (top, bottom);
  }

  /// 第 [index] 行居中时的滚动偏移
  double _revealOffset(int index) {
    final RenderObject? line = _lineKeys[index].currentContext
        ?.findRenderObject();
    final RenderObject? text = _keys[index].currentContext?.findRenderObject();
    if (line is! RenderBox || !line.attached || !line.hasSize) {
      return double.nan;
    }
    if (text is! RenderBox || !text.attached || !text.hasSize) {
      return double.nan;
    }
    // 居中的是正文：有译文时整行比正文高，按整行居中会把正文顶上去
    final Offset offset = _layoutOffset(text, line);
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      text.size.width,
      text.size.height,
    );
    // getOffsetToReveal 按「目标矩形顶边」对齐，这里要的是正文**中心**落在
    // 对齐线上，所以先取顶边贴顶的偏移，再自己挪半个正文高度
    final double base = RenderAbstractViewport.of(line)
        .getOffsetToReveal(line, 0, rect: rect)
        .offset;
    final double viewport = _scroll.position.viewportDimension;
    return base - viewport * widget.revealAlignment + rect.height / 2;
  }

  /// [descendant] 在 [ancestor] 里的排版偏移：只累加 parentData，不走
  /// paint transform，否则行自己的弹簧位移会混进来
  static Offset _layoutOffset(RenderObject descendant, RenderObject ancestor) {
    Offset offset = Offset.zero;
    RenderObject node = descendant;
    while (node != ancestor) {
      final RenderObject? parent = node.parent;
      if (parent == null) {
        break;
      }
      final Object? data = node.parentData;
      if (data is BoxParentData) {
        offset += data.offset;
      }
      node = parent;
    }
    return offset;
  }

  void _scrollToActive({bool animate = true}) {
    if (_active < 0 || _active >= _keys.length || !_scroll.hasClients) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    final double target = _revealOffset(_active);
    if (target.isNaN) {
      return;
    }
    final double clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (!animate) {
      position.jumpTo(clamped);
      return;
    }
    unawaited(
      position.animateTo(clamped, duration: _jumpDuration, curve: _jumpCurve),
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        !_driving &&
        notification.dragDetails != null) {
      // 用户接管滚动：先别抢，停手 3 秒后再跟回当前行
      _userScrolling = true;
      _resumeTimer?.cancel();
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) {
          return;
        }
        _userScrolling = false;
        if (_playing) {
          _jumpToActive();
        } else {
          // 暂停中没有 tick，自己滑回去
          _scrollToActive();
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 上下各留出对齐线两侧的距离，首尾行也能滚到对齐线
        final double topPad = math.max(
          24,
          constraints.maxHeight * widget.revealAlignment,
        );
        final double bottomPad = math.max(
          24,
          constraints.maxHeight * (1 - widget.revealAlignment),
        );
        // 上下边界用 dstIn 遮罩真去改 alpha：文字淡出、背景一点不动。底部一段
        // 要盖过频谱丝带（[LyricsView.edgeFadeBand]）再留过渡，否则滚到下半屏的
        // 歌词会直接糊在柱子上。着色器按尺寸缓存，见 [_maskShader]
        return ShaderMask(
          key: const ValueKey<String>('lyrics-edge-fade'),
          blendMode: BlendMode.dstIn,
          shaderCallback: _fadeShader,
          // 歌词区不要滚动条：桌面默认会在滚动时冒出一条竖条，
          // 压着封面和文字的边缘很难看
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(scrollbars: false),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: SingleChildScrollView(
                controller: _scroll,
                // 橡皮筋回弹：拖到首尾还能再拽出去一点再弹回来，和「弹」的
                // 跟随曲线是同一套手感（桌面默认的 Clamping 是贴住的）
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.only(
                  top: topPad,
                  bottom: bottomPad,
                  left: 16,
                  right: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (int i = 0; i < widget.lines.length; i += 1)
                      _SpringLyricLine(
                        key: ValueKey<String>('lyric-$i'),
                        index: i,
                        lineKey: _lineKeys[i],
                        anchorKey: _keys[i],
                        jump: _jump,
                        line: widget.lines[i],
                        active: i == _active,
                        distance: _active < 0 ? i : (i - _active).abs(),
                        position: _smooth,
                        textTheme: theme.textTheme,
                        onSeek: widget.onSeek,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 上下淡出的遮罩：同一个尺寸只建一次着色器
  Shader _fadeShader(Rect rect) {
    final Shader? cached = _maskShader;
    if (cached != null &&
        _maskRect == rect &&
        _maskBand == widget.edgeFadeBand) {
      return cached;
    }
    _maskRect = rect;
    _maskBand = widget.edgeFadeBand;
    final Shader shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      // 只有 alpha 起作用（dstIn）：透明处把歌词抹掉，白色处原样保留。
      // 每段缓冲取 12% / 70%，和 [lyricFadeStops] 的 0.3 / 0.7 对应
      colors: _fadeColors,
      stops: lyricFadeStops(
        height: rect.height,
        top: _fadeTop,
        band: widget.edgeFadeBand,
      ),
    ).createShader(rect);
    return _maskShader = shader;
  }
}

/// 与 [lyricFadeStops] 的 8 个 stop 一一对应的 alpha（S 形收尾）
const List<Color> _fadeColors = <Color>[
  Color(0x00FFFFFF),
  Color(0x1FFFFFFF),
  Color(0xB3FFFFFF),
  Color(0xFFFFFFFF),
  Color(0xFFFFFFFF),
  Color(0xB3FFFFFF),
  Color(0x1FFFFFFF),
  Color(0x00FFFFFF),
];

/// 二分找最后一条 `time <= seconds` 的歌词下标；没有歌词返回 -1。
///
/// 正在播放页（多行视图）与播放条（单行预览）共用，避免两处各写一份二分。
int lyricIndexAt(List<lyrics_api.LyricLine> lines, double seconds) {
  if (lines.isEmpty) {
    return -1;
  }
  final int ms = (seconds * 1000).round();
  int low = 0;
  int high = lines.length - 1;
  int found = -1;
  while (low <= high) {
    final int mid = (low + high) >> 1;
    if (lines[mid].timeMs.toInt() <= ms) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return found;
}

/// 一次换行：整列已经 `jumpTo` 到位，各行按 [deltaY] 把自己推回去再弹回。
class _LineJump {
  const _LineJump({
    required this.id,
    required this.deltaY,
    required this.top,
    required this.bottom,
  });

  static const _LineJump none = _LineJump(id: 0, deltaY: 0, top: 0, bottom: 0);

  /// 递增的序号：每行只处理比上次新的信号
  final int id;

  /// 这次换行滚动了多少像素（>0 表示内容往上走）
  final double deltaY;

  /// 可视区首行 / 末行
  final int top;
  final int bottom;
}

/// 一行歌词 + 它自己的回弹位移。
///
/// 换行时先被 `Transform` 推回去 [deltaY]（视觉上停在原地），再按行序错峰
/// 弹回 0，形成一行接一行归位的波浪。
class _SpringLyricLine extends StatefulWidget {
  const _SpringLyricLine({
    super.key,
    required this.index,
    required this.lineKey,
    required this.anchorKey,
    required this.jump,
    required this.line,
    required this.active,
    required this.distance,
    required this.position,
    required this.textTheme,
    required this.onSeek,
  });

  final int index;

  /// 挂在外层：算居中偏移用，绕开弹簧位移
  final GlobalKey lineKey;

  /// 挂在正文上：居中以正文为准，译文不会把当前行顶偏
  final GlobalKey anchorKey;

  final ValueListenable<_LineJump> jump;
  final lyrics_api.LyricLine line;
  final bool active;
  final int distance;
  final ValueListenable<double> position;
  final TextTheme textTheme;
  final Future<void> Function(double seconds) onSeek;

  @override
  State<_SpringLyricLine> createState() => _SpringLyricLineState();
}

class _SpringLyricLineState extends State<_SpringLyricLine>
    with SingleTickerProviderStateMixin {
  /// value 就是这一行相对排版位置的 Y 偏移；第一次换行才建，避免几百个常驻 ticker
  AnimationController? _spring;
  int _trigger = 0;
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    widget.jump.addListener(_onJump);
  }

  @override
  void didUpdateWidget(_SpringLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jump != widget.jump) {
      oldWidget.jump.removeListener(_onJump);
      widget.jump.addListener(_onJump);
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _spring?.dispose();
    widget.jump.removeListener(_onJump);
    super.dispose();
  }

  void _onJump() {
    final _LineJump jump = widget.jump.value;
    if (jump.id == _trigger) {
      return;
    }
    _trigger = jump.id;
    _delay?.cancel();

    // 屏幕外的行直接归位，不占动画
    if (jump.deltaY == 0 ||
        widget.index < jump.top - 1 ||
        widget.index > jump.bottom + 1) {
      _spring?.value = 0;
      return;
    }

    // 往前滚（内容往上走）时最上面那行先动，越往下越晚
    final bool forward = jump.deltaY >= 0;
    final int step = forward
        ? widget.index - jump.top
        : jump.bottom - widget.index;
    final int delayMs = math.max(0, step) * _lineStepDelayMs;
    final double ratio =
        ((widget.index - jump.top) / math.max(1, jump.bottom - jump.top)).clamp(
          0.0,
          1.0,
        );

    final bool fresh = _spring == null;
    final AnimationController spring = _spring ??=
        AnimationController.unbounded(vsync: this);
    if (fresh) {
      setState(() {});
    }
    // 瞬间推回去：jumpTo 已经把整列挪走了，这里抵消掉，这一帧画面上没动
    spring.value = jump.deltaY;

    if (delayMs == 0) {
      _run(spring, jump.deltaY, ratio);
      return;
    }
    final int trigger = _trigger;
    _delay = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted || trigger != _trigger) {
        return;
      }
      _run(spring, jump.deltaY, ratio);
    });
  }

  void _run(AnimationController spring, double from, double ratio) {
    spring.animateWith(
      SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: _springStiffness(ratio),
          ratio: _springDamping(ratio),
        ),
        from,
        0,
        0,
        tolerance: _springTolerance,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 每行一层 RepaintBoundary：弹动只挪图层，不重新光栅化文字
    final Widget content = RepaintBoundary(
      child: _LyricLineView(
        anchorKey: widget.anchorKey,
        line: widget.line,
        active: widget.active,
        distance: widget.distance,
        position: widget.position,
        textTheme: widget.textTheme,
        onSeek: widget.onSeek,
      ),
    );
    final AnimationController? spring = _spring;
    return KeyedSubtree(
      key: widget.lineKey,
      child: spring == null
          ? content
          : AnimatedBuilder(
              animation: spring,
              builder: (BuildContext context, Widget? child) =>
                  Transform.translate(
                    offset: Offset(0, spring.value),
                    child: child,
                  ),
              child: content,
            ),
    );
  }
}

/// 单行歌词：正文 +（罗马音 / 翻译）
class _LyricLineView extends StatelessWidget {
  const _LyricLineView({
    required this.anchorKey,
    required this.line,
    required this.active,
    required this.distance,
    required this.position,
    required this.textTheme,
    required this.onSeek,
  });

  /// 滚动居中的锚点：挂在正文上，译文不会把当前行顶偏
  final GlobalKey anchorKey;
  final lyrics_api.LyricLine line;
  final bool active;

  /// 与当前行的距离：用来做由近及远的透明度衰减
  final int distance;
  final ValueListenable<double> position;
  final TextTheme textTheme;
  final Future<void> Function(double seconds) onSeek;

  @override
  Widget build(BuildContext context) {
    final bool interlude = line.text.trim().isEmpty;
    final TextStyle style = (textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: active ? 28 : 22,
      height: 1.45,
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      letterSpacing: 0.2,
    );

    // 歌词固定使用白色系，不跟随主题色；当前行最实，上下按距离淡出。
    // 有了模糊之后不再一味压低透明度：远处那几行靠「糊」退出焦点，
    // alpha 压太狠的话糊都看不见，层次只剩「有字 / 没字」两档
    final Color white = Colors.white;
    final Color activeColor = white.withValues(alpha: 0.96);
    final Color dim = white.withValues(
      alpha: switch (distance) {
        1 => 0.62,
        2 => 0.5,
        3 => 0.4,
        4 => 0.32,
        _ => 0.26,
      },
    );

    final Widget main;
    if (interlude) {
      main = Text(
        '♪',
        textAlign: TextAlign.center,
        style: style.copyWith(
          color: active ? activeColor : dim,
          fontSize: active ? 24 : 18,
        ),
      );
    } else if (active && line.words.length >= 2) {
      main = _KaraokeText(
        text: line.text,
        words: line.words,
        lineEndMs: line.endMs.toInt(),
        position: position,
        style: style,
        baseColor: white.withValues(alpha: 0.42),
        highlightColor: white,
      );
    } else {
      main = Text(
        line.text,
        textAlign: TextAlign.center,
        style: style.copyWith(color: active ? activeColor : dim),
      );
    }

    // 越远的行越虚：靠模糊表现「退出焦点」。只压不透明度的话，文字笔画在
    // 某个 alpha 上还是清清楚楚的，边缘就还是硬的；糊开之后没有了高频细节，
    // 再叠上遮罩的淡出才是渐进的。
    //
    // 从相邻一行就开始给一点糊，一级一级往上加：之前是 1 行全清、2 行直接
    // σ1.2，一格就跳过去，看着像被分成「清楚」和「不清楚」两半。
    final double blurSigma = switch (distance) {
      0 => 0,
      1 => 0.5,
      2 => 1.1,
      3 => 1.8,
      4 => 2.5,
      _ => 3.2,
    };

    final List<String> extras = line.translation
        .split('\n')
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(onSeek(line.timeMs.toInt() / 1000)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            KeyedSubtree(
              key: anchorKey,
              child: blurSigma <= 0
                  ? main
                  : ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: blurSigma,
                        sigmaY: blurSigma,
                      ),
                      child: main,
                    ),
            ),
            if (extras.isNotEmpty) const SizedBox(height: 3),
            for (final String extra in extras)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  extra,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    // 译文只比正文略小，避免层级断层
                    fontSize: active
                        ? (_hasCjk(extra) ? 23 : 21)
                        : (_hasCjk(extra) ? 18 : 17),
                    height: 1.4,
                    color: Colors.white.withValues(
                      alpha: active
                          ? (_hasCjk(extra) ? 0.72 : 0.58)
                          : (_hasCjk(extra) ? 0.34 : 0.24),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static final RegExp _cjk = RegExp(
    r'[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]',
  );

  static bool _hasCjk(String text) => _cjk.hasMatch(text);
}

/// 逐字染色：底层是暗色整行，上层是同一位置的高亮整行，按已唱进度裁切。
///
/// 裁切不能用「容器宽度 × 比例」：整行文字在容器里居中，而 [TextPainter] 的
/// 坐标从文字块左上角算起，两者差一个居中偏移，算出来的矩形会落在左侧空白处。
/// 这里改成自绘——整行先排版一次，再把「已唱完的字」和「当前字已唱的部分」
/// 拼成一条路径去裁切高亮层，坐标天然一致，长句折行也不会错。
class _KaraokeText extends StatefulWidget {
  const _KaraokeText({
    required this.text,
    required this.words,
    required this.lineEndMs,
    required this.position,
    required this.style,
    required this.baseColor,
    required this.highlightColor,
  });

  final String text;
  final List<lyrics_api.LyricWord> words;
  final int lineEndMs;
  final ValueListenable<double> position;
  final TextStyle style;
  final Color baseColor;
  final Color highlightColor;

  @override
  State<_KaraokeText> createState() => _KaraokeTextState();
}

class _KaraokeTextState extends State<_KaraokeText> {
  TextPainter? _base;
  TextPainter? _highlight;

  /// 每个逐字片段在排版里的矩形：一个字被折行拆开时会有多段
  List<List<Rect>> _boxes = const <List<Rect>>[];
  List<int> _times = const <int>[];

  double _width = -1;
  String? _text;
  TextStyle? _style;

  @override
  void didUpdateWidget(_KaraokeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _width = -1;
    }
  }

  @override
  void dispose() {
    _base?.dispose();
    _highlight?.dispose();
    super.dispose();
  }

  /// 排版并量出每个字的矩形；只在文本 / 样式 / 宽度变化时重算
  void _layout(double width) {
    if (_width == width && _text == widget.text && _style == widget.style) {
      return;
    }
    _width = width;
    _text = widget.text;
    _style = widget.style;

    _base?.dispose();
    _highlight?.dispose();
    final TextPainter base = _painter(widget.baseColor, width);
    _base = base;
    _highlight = _painter(widget.highlightColor, width);

    final List<List<Rect>> boxes = <List<Rect>>[];
    int cursor = 0;
    for (final lyrics_api.LyricWord word in widget.words) {
      final int start = widget.text.indexOf(word.text, cursor);
      if (start < 0) {
        boxes.add(const <Rect>[]);
        continue;
      }
      final int end = start + word.text.length;
      boxes.add(
        base
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: end),
            )
            .map((TextBox box) => box.toRect())
            .toList(),
      );
      cursor = end;
    }
    _boxes = boxes;
    _times = widget.words
        .map((lyrics_api.LyricWord word) => word.timeMs.toInt())
        .toList();
  }

  TextPainter _painter(Color color, double width) {
    return TextPainter(
      text: TextSpan(
        text: widget.text,
        style: widget.style.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: width);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _layout(constraints.maxWidth);
        final TextPainter base = _base!;
        return Semantics(
          label: widget.text,
          child: SizedBox(
            width: base.width,
            height: base.height,
            child: _KaraokeLayers(
              base: base,
              highlight: _highlight!,
              boxes: _boxes,
              times: _times,
              lineEndMs: widget.lineEndMs,
              position: widget.position,
            ),
          ),
        );
      },
    );
  }
}

/// 逐字染色的两层结构：静态前缀 + 正在唱的那个字。
///
/// 以前是一个画笔每 33ms 把整行重画一遍（暗色整行 + 裁切的高亮整行），
/// 一次约 4ms；参考 ZeroBit 的做法，拆成两层：
/// * **前缀层**——整行暗色 + 已经唱完的字，只在跨过一个字时重建（一行 6~9 次）；
/// * **正在唱的字**——单独一个图层，位置就是这个词的包围盒，每 33ms 只重绘这一小块。
///
/// 每拍要刷的面积从「整行」降到「一个字」，画笔本身仍然是同一套裁切逻辑。
class _KaraokeLayers extends StatefulWidget {
  const _KaraokeLayers({
    required this.base,
    required this.highlight,
    required this.boxes,
    required this.times,
    required this.lineEndMs,
    required this.position,
  });

  final TextPainter base;
  final TextPainter highlight;
  final List<List<Rect>> boxes;
  final List<int> times;
  final int lineEndMs;
  final ValueListenable<double> position;

  @override
  State<_KaraokeLayers> createState() => _KaraokeLayersState();
}

class _KaraokeLayersState extends State<_KaraokeLayers> {
  /// 正在唱的那个字；-1 表示还没到第一个字 / 整行已经唱完
  int _current = -1;

  /// 已经唱完的字数（前缀层要整块填色的范围）
  int _sung = 0;

  @override
  void initState() {
    super.initState();
    _compute();
    widget.position.addListener(_sync);
  }

  @override
  void didUpdateWidget(_KaraokeLayers oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position.removeListener(_sync);
      widget.position.addListener(_sync);
    }
    if (!identical(oldWidget.times, widget.times) ||
        oldWidget.lineEndMs != widget.lineEndMs ||
        !identical(oldWidget.boxes, widget.boxes)) {
      _compute();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_sync);
    super.dispose();
  }

  /// 每 33ms 被调一次：只有「换到下一个字」时才重建，其余时候什么都不做
  void _sync() {
    final int current = _indexAt(widget.position.value * 1000);
    final int sung = _sungAt(widget.position.value * 1000, current);
    if (current == _current && sung == _sung) {
      return;
    }
    setState(() {
      _current = current;
      _sung = sung;
    });
  }

  void _compute() {
    final double ms = widget.position.value * 1000;
    _current = _indexAt(ms);
    _sung = _sungAt(ms, _current);
  }

  /// 最后一条 `times[i] <= ms` 的下标；整行唱完返回 -1
  int _indexAt(double ms) {
    if (ms >= widget.lineEndMs) {
      return -1;
    }
    int found = -1;
    for (int i = 0; i < widget.times.length; i += 1) {
      if (widget.times[i] <= ms) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }

  int _sungAt(double ms, int current) {
    if (ms >= widget.lineEndMs) {
      return widget.times.length;
    }
    return current < 0 ? 0 : current;
  }

  /// 某个字的包围盒（外扩 2px，别把抗锯齿边裁掉）
  Rect? _wordRect(int index) {
    if (index < 0 || index >= widget.boxes.length) {
      return null;
    }
    final List<Rect> rects = widget.boxes[index];
    if (rects.isEmpty) {
      return null;
    }
    Rect bound = rects.first;
    for (final Rect rect in rects.skip(1)) {
      bound = bound.expandToInclude(rect);
    }
    return bound.inflate(2);
  }

  @override
  Widget build(BuildContext context) {
    final Rect? word = _wordRect(_current);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: KaraokePrefixPainter(
                base: widget.base,
                highlight: widget.highlight,
                boxes: widget.boxes,
                times: widget.times,
                lineEndMs: widget.lineEndMs,
                sung: _sung,
              ),
            ),
          ),
        ),
        if (word != null)
          Positioned.fromRect(
            rect: word,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: KaraokeWordPainter(
                  highlight: widget.highlight,
                  boxes: widget.boxes,
                  times: widget.times,
                  lineEndMs: widget.lineEndMs,
                  index: _current,
                  origin: word.topLeft,
                  position: widget.position,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 逐字染色要填色的区域（排版坐标）。
///
/// 只算 [from]、[to) 这一段字：前缀层传 `[0, sung)`，正在唱的字传 `[i, i + 1)`。
/// 一个字被折行拆成多段时按宽度顺序依次填。
@visibleForTesting
Path karaokeFillPath({
  required List<List<Rect>> boxes,
  required List<int> times,
  required int lineEndMs,
  required double positionMs,
  required int from,
  required int to,
}) {
  final Path path = Path();
  final int end = math.min(to, boxes.length);
  for (int i = math.max(from, 0); i < end; i += 1) {
    final double start = times[i].toDouble();
    if (positionMs <= start) {
      break;
    }
    final double next = i + 1 < times.length
        ? times[i + 1].toDouble()
        : lineEndMs.toDouble();
    final double progress = next <= start
        ? 1
        : ((positionMs - start) / (next - start)).clamp(0.0, 1.0);
    final List<Rect> rects = boxes[i];
    if (rects.isEmpty) {
      continue;
    }
    if (progress >= 1) {
      for (final Rect rect in rects) {
        path.addRect(rect);
      }
      continue;
    }
    double remain =
        rects.fold<double>(0, (double sum, Rect rect) => sum + rect.width) *
        progress;
    for (final Rect rect in rects) {
      if (remain <= 0) {
        break;
      }
      final double take = math.min(remain, rect.width);
      path.addRect(Rect.fromLTWH(rect.left, rect.top, take, rect.height));
      remain -= take;
    }
  }
  return path;
}

/// 静态前缀层：整行暗色 + 已经唱完的字（整块填色）。
///
/// 只在跨过一个字时重建，所以它不进 `repaint`，也就不跟着进度每拍重绘。
@visibleForTesting
class KaraokePrefixPainter extends CustomPainter {
  KaraokePrefixPainter({
    required this.base,
    required this.highlight,
    required this.boxes,
    required this.times,
    required this.lineEndMs,
    required this.sung,
  });

  final TextPainter base;
  final TextPainter highlight;
  final List<List<Rect>> boxes;
  final List<int> times;
  final int lineEndMs;

  /// 已经唱完的字数
  final int sung;

  /// 已唱区域的排版坐标（测试用）
  Path get fillPath => karaokeFillPath(
    boxes: boxes,
    times: times,
    lineEndMs: lineEndMs,
    // 前缀层里的字都是唱完的，直接用无穷大让 progress 取满
    positionMs: double.infinity,
    from: 0,
    to: sung,
  );

  @override
  void paint(Canvas canvas, Size size) {
    base.paint(canvas, Offset.zero);
    final Path path = fillPath;
    if (path.getBounds().isEmpty) {
      return;
    }
    canvas.save();
    canvas.clipPath(path);
    highlight.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(KaraokePrefixPainter oldDelegate) =>
      !identical(oldDelegate.base, base) ||
      !identical(oldDelegate.highlight, highlight) ||
      !identical(oldDelegate.boxes, boxes) ||
      !identical(oldDelegate.times, times) ||
      oldDelegate.lineEndMs != lineEndMs ||
      oldDelegate.sung != sung;
}

/// 正在唱的那个字：图层只有这个词那么大，每 33ms 只重绘这一小块。
@visibleForTesting
class KaraokeWordPainter extends CustomPainter {
  KaraokeWordPainter({
    required this.highlight,
    required this.boxes,
    required this.times,
    required this.lineEndMs,
    required this.index,
    required this.origin,
    required this.position,
  }) : super(repaint: position);

  final TextPainter highlight;
  final List<List<Rect>> boxes;
  final List<int> times;
  final int lineEndMs;

  /// 正在唱的字的下标
  final int index;

  /// 这个字在图里的左上角：画的时候把整行平移回来，只留这个词
  final Offset origin;

  /// 播放进度：直接监听它重画，不重建 widget
  final ValueListenable<double> position;

  double get positionMs => position.value * 1000;

  /// 这个字已唱到的部分（图层坐标，测试用）
  @visibleForTesting
  Path get clipPath => karaokeFillPath(
    boxes: boxes,
    times: times,
    lineEndMs: lineEndMs,
    positionMs: positionMs,
    from: index,
    to: index + 1,
  ).shift(-origin);

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = clipPath;
    if (path.getBounds().isEmpty) {
      return;
    }
    canvas.save();
    canvas.clipPath(path);
    canvas.translate(-origin.dx, -origin.dy);
    highlight.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(KaraokeWordPainter oldDelegate) =>
      !identical(oldDelegate.highlight, highlight) ||
      !identical(oldDelegate.boxes, boxes) ||
      !identical(oldDelegate.times, times) ||
      oldDelegate.lineEndMs != lineEndMs ||
      oldDelegate.index != index ||
      oldDelegate.origin != origin ||
      oldDelegate.position != position;
}

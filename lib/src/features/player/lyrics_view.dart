import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import '../../common/ui_clock.dart';
import '../../rust/api/lyrics.dart' as lyrics_api;
import 'lyric_alignment.dart';

/// 歌词视图：当前行逐字染色、上下淡出。
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
    this.alignment = LyricAlignment.center,
    this.showTranslation = true,
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

  /// 歌词的水平对齐方式；垂直居中逻辑与它无关
  final LyricAlignment alignment;

  /// 是否显示译文 / 罗马音。
  ///
  /// 切换时不是直接摘掉，而是让每行的译文块按弹簧折叠 / 展开，整列歌词跟着
  /// 一起弹——直接换掉的话下面的行会「啪」地跳一下。
  final bool showTranslation;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

/// 上下淡出的渐变 stops（两端各用三段缓冲，中间全不透明）。
///
/// 直线渐变在「透明→不透明」走完的那一点上斜率突变，文字从看不见到完全实是
/// 一下子的，看着就是一条看不见的边。改成两段缓冲后，alpha 是 S 形收尾，
/// 边界感就散了。
///
/// 顶部 [deadZone] 是**严格 0** 的死区，而且调用方必须把它落在行与行之间
/// （见 [_LyricsViewState._deadZone]）。固定像素的死区一定会切在某一行中间：
/// 上半截被抹掉、下半截留下来，看着就是顶上一排断断续续的横线（字的底笔）。
/// 死区结束在行边界上，被裁的行整行消失，下面那行从 0 开始淡入，两头都干净。
///
/// 底部一段按「丝带高度 [band] + 随高度缩放的过渡」算：最小窗口（900×560）里
/// 歌词区只有 370 高，用固定值会把整个下半屏吃掉。过渡段最少 [_fadeRampMin]，
/// 保证边框上滚动时不是一下子黑掉。
@visibleForTesting
List<double> lyricFadeStops({
  required double height,
  required double top,
  required double band,
  double deadZone = 0,
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
  final double d = (deadZone / height).clamp(0.0, t);
  final double b = (1 - bottom / height).clamp(0.0, 1.0);
  // 极矮的歌词区里两段会越过对方，取中点收成一条硬边，别让 stops 反序
  if (t > b) {
    final double mid = (t + b) / 2;
    return <double>[0, mid, mid, mid, mid, mid, mid, 1];
  }
  return <double>[
    0,
    d,
    d + (t - d) * 0.7,
    t,
    b,
    b + (1 - b) * 0.3,
    b + (1 - b) * 0.7,
    1,
  ];
}

/// 单行在视口里的不透明度：把行区间在渐隐曲线上取平均。
///
/// 以前整片歌词套一张 `ShaderMask`（`BlendMode.dstIn`）做上下淡出——那是**一张
/// 全宽离屏图层**，Impeller 每帧都要重新分配一次，转场期间更是和帧数一起叠起来。
/// 现在改成按行把 alpha 乘进文字颜色，一个离屏图层都不产生。
///
/// 取「区间平均」而不是行中心点：一行跨在渐隐带里时，整行一起淡比取中点更接近
/// 原来连续渐变的观感（行高 40~60px，渐隐带 30~110px）。
@visibleForTesting
double lyricRowOpacity({
  required double top,
  required double bottom,
  required double height,
  required List<double> stops,
}) {
  if (height <= 0 || bottom <= top) {
    return 1;
  }
  // 分段线性，取 8 个采样点求平均：一行最多跨两三个 stop，误差看不出来
  const int samples = 8;
  double sum = 0;
  for (int i = 0; i < samples; i += 1) {
    final double y = top + (bottom - top) * (i + 0.5) / samples;
    sum += _fadeAlpha((y / height).clamp(0.0, 1.0), stops);
  }
  return sum / samples;
}

/// 渐隐曲线在 [t]（0 = 视口顶、1 = 视口底）处的 alpha。
///
/// [stops] 与 [_fadeColors] 一一对应，中间线性插值——和原来 `LinearGradient`
/// 实际画出来的东西一致。
double _fadeAlpha(double t, List<double> stops) {
  double previousStop = stops.first;
  double previousAlpha = _fadeColors.first.a;
  for (int i = 1; i < stops.length && i < _fadeColors.length; i += 1) {
    final double stop = stops[i];
    final double alpha = _fadeColors[i].a;
    if (t <= stop) {
      final double span = stop - previousStop;
      if (span <= 0) {
        return alpha;
      }
      return previousAlpha +
          (alpha - previousAlpha) * (t - previousStop) / span;
    }
    previousStop = stop;
    previousAlpha = alpha;
  }
  return _fadeColors.last.a;
}

/// 行框顶边到字迹顶边的距离：9px 内边距 + 字体自身的行距（实测 15~17px）。
///
/// 淡入段必须从这里才开始算。从行框顶边起算的话，等画到字的时候淡入段已经
/// 走掉七成，最上面那行字一出现就是七成亮度，看着像半截残影。
const double _fadeTopOffset = 13;

/// 顶部淡出：字迹出现之后还要多少像素才渐显到全不透明。
///
/// 死区落在「视口内第一条完整行」的顶边上（见 [_LyricsViewState._topBoundary]），
/// 被上沿裁掉的行整行消失，不会切出半截字。剩下这行从字迹顶边开始淡入，
/// 30px 大约走到行框底边，正好在自身高度里走完。
const double _fadeTopRamp = 30;

/// 量不到行位置时的兜底：按一整行算（普通行约 50、当前行约 59），乘 0.5
const double _fadeTop = 120;

/// 死区在行边界上再往下多盖的像素。
///
/// 行内下内边距 9px，22px 字的降部与抗锯齿边会溢出
/// 行框约 1px。死区正好卡在行框边界时，这一截就从渐显段漏出来（顶部那排虚线）。
const double _deadZoneGuard = 2;

/// 死区下边界：下一行的行框顶边再让出 [_deadZoneGuard]，上限取歌词区高度的 42%
@visibleForTesting
double deadZoneBoundary(double nextTop, double height) =>
    (nextTop + _deadZoneGuard).clamp(0.0, height * 0.42);

/// 换行时的逐行回弹。
///
/// 换行时整列 `jumpTo` 到新行居中，每行再用 `Transform` 推回 `deltaY`（视觉上
/// 等于没动），随后按行序错峰弹回 0。全局积分一个弹簧做不到：那是整块刚性平移。
const int _lineStepDelayMs = 26;

/// 弹簧收尾容差：0.5px / 0.1px/s 以内掐断，免得一直抖
const Tolerance _springTolerance = Tolerance(distance: 0.5, velocity: 0.1);

/// 刚度 / 阻尼比随行在可视区里的位置递减：越靠下越软、越慢
double _springStiffness(double ratio) => 175 - 20 * ratio;
double _springDamping(double ratio) => 0.86 - 0.08 * ratio;

/// 歌词在**布局**里的字号：恒定，等于非当前行的字号。
///
/// 换行时千万不能改字号——字号一变，长句的折行会跟着变（22px 一行装得下、
/// 28px 要折成两行），整列的高度就重排了。而换行时每行的弹簧补偿只是一个
/// **统一的位移**：重排带来的位移它补不掉，画面上就是「整列瞬间跳一下」
/// （实测折行那句能把下面每行顶下去 41px）。
///
/// 当前行的放大改走 [_activeLyricScale] 的 `Transform` 缩放：纯绘制变换，
/// 布局一点不动，补偿才补得准。
const double _lyricFontSize = 22;

/// 当前行的视觉放大倍数：22 → 28 的效果，由一个 `AnimatedScale` 渐变过去
const double _activeLyricScale = 28 / _lyricFontSize;

/// 当前行放大的过渡：600ms 缓出。再快就还是「啪」地变大，再慢会拖到下一句都开唱了
const Duration _activeScaleDuration = Duration(milliseconds: 600);

/// 一次性大跳（点歌词跳转、切歌定位）用的时长与曲线。
///
/// 那种场景位移动辄几百像素，弹簧反而显得拖；短促地滑过去更干脆。
const Duration _jumpDuration = Duration(milliseconds: 420);
const Curve _jumpCurve = Curves.easeInOutCubic;

/// 底部过渡段：随歌词区高度缩放，并夹在 [_fadeRampMin]~[_fadeRampMax]
const double _fadeRampRatio = 0.2;
const double _fadeRampMin = 56;
const double _fadeRampMax = 110;

/// 歌词区左右内边距（滚动视图）
const double _scrollPaddingX = 16;

/// 每行左右内边距
const double _linePaddingX = 12;

/// 歌词正文的最大宽度：固定列宽（不跟最长一行走），放不下的行折行。
///
/// 640 在 28px 字号下约 22 个汉字 / 45 个西文字符，绝大多数歌词一行装得下；
/// 三种对齐都只在这个块里进行，块本身居中——直接对齐到歌词区两边的话，整首
/// 歌词会贴到一侧，另一侧空一大片。
const double _lyricBlockWidth = 640;

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();

  /// 译文的展开进度：1 = 展开、0 = 收起。
  ///
  /// 用 300ms 缓出（和 `AnimatedSize` 一个手感）：弹簧那种过冲会让整列来回
  /// 鼓一下，看着反而乱。展开 / 收起时整列的高度变化是线性的（高度乘的就是
  /// 这个值），所以滚动能按同一条曲线精确补上，不必逐帧去追。
  late final AnimationController _translation;

  /// 切换开始时的滚动偏移与进度，以及要补的总距离。
  ///
  /// 译文块的高度恒等于「自然高度 × 进度」，所以当前行上面那一截内容的高度
  /// 也是进度的线性函数：补偿量 = 上面那些译文块的自然高度之和 × 进度变化量。
  /// 这样滚动和布局走的是同一条直线，抹掉整段动画里的相对位移。
  double _translationAnchor = double.nan;
  double _translationStart = 1;
  double _translationSpan = 0;

  /// 插值后的进度：每帧更新，只被当前行监听
  final ValueNotifier<double> _smooth = ValueNotifier<double>(0);

  /// [_base] 取自哪个时刻（[UiClock] 秒）：插值从这一时刻往后推算
  double _baseAt = 0;

  /// 是否正在听 [UiClock]（播放中且有歌词才需要）
  bool _clockOn = false;

  late List<GlobalKey> _keys;

  /// 每行外层（[Transform]）的 key。不能用正文那个：正文在 Transform 里面，
  /// `getOffsetToReveal` 会把弹簧位移一起算进去，目标位置就跟着弹簧飘了
  late List<GlobalKey> _lineKeys;

  /// 视口里第一行的下标。滚动是连续的，每次从它挪几步就能找到新位置，
  /// 不必全量测量（全屏能露出二十多行）
  int _firstVisible = 0;

  /// 每行译文块的 key：量它的**自然高度**（不受折叠进度影响），用来算补偿量
  late List<GlobalKey> _translationKeys;

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

  /// 每行的边界不透明度（上下渐隐）。
  ///
  /// 一行一个通知器：滚动时只有靠近上下边界的那几行会变，其余行不重建。以前
  /// 这里是整片歌词外面套一张 `ShaderMask`——那层是全宽的离屏图层，滚动和
  /// 转场时每帧都要重新分配（Impeller 没有光栅缓存）。
  final List<ValueNotifier<double>> _rowOpacity = <ValueNotifier<double>>[];

  Timer? _scrollSettle;

  @override
  void initState() {
    super.initState();
    _translation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: widget.showTranslation ? 1 : 0,
    );
    _translation.addListener(_followTranslation);
    _translation.addStatusListener(_onTranslationStatus);
    _keys = _buildKeys();
    _lineKeys = _buildKeys();
    _translationKeys = _buildKeys();
    _base = widget.position.value;
    _baseAt = UiClock.instance.seconds;
    _smooth.value = _base;
    _active = _indexAt(_base);
    _playing = widget.playing.value;
    widget.position.addListener(_onPosition);
    widget.playing.addListener(_onPlaying);
    _scroll.addListener(_onScrollOffset);
    _syncClock();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActive(animate: false);
      // 行位置要等布局完才量得到，渐隐只能在这里算第一次
      _refreshRowOpacity();
    });
  }

  /// 滚动位置变了：重算上下边界的渐隐强度。
  ///
  /// 只刷可见的那一段（视口里二十来行），滚停 250ms 后再全量对一次。每行的
  /// alpha 只写到「变化超过 0.01」的通知器里，滚动时真正重绘的通常就两三行。
  void _onScrollOffset() {
    if (!_scroll.hasClients) {
      return;
    }
    _refreshRowOpacity(visibleOnly: true);
    _scrollSettle?.cancel();
    _scrollSettle = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _refreshRowOpacity();
      }
    });
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showTranslation != widget.showTranslation) {
      _animateTranslation();
    }
    if (!identical(oldWidget.lines, widget.lines)) {
      _keys = _buildKeys();
      _lineKeys = _buildKeys();
      _translationKeys = _buildKeys();
      _firstVisible = 0;
      _active = -1;
      _smooth.value = _base;
      _active = _indexAt(_base);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(animate: false);
        _refreshRowOpacity();
      });
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
    _scroll.removeListener(_onScrollOffset);
    _scrollSettle?.cancel();
    _scroll.dispose();
    _smooth.dispose();
    _jump.dispose();
    _translation.dispose();
    for (final ValueNotifier<double> notifier in _rowOpacity) {
      notifier.dispose();
    }
    _rowOpacity.clear();
    super.dispose();
  }

  /// 折叠 / 展开译文：先量出要补多少滚动，再让两者走同一条曲线
  void _animateTranslation() {
    _rebaseTranslation();
    _translation.animateTo(
      widget.showTranslation ? 1 : 0,
      curve: Curves.easeOutCubic,
    );
  }

  /// 以「当前滚动位置 + 当前进度」为起点重算补偿
  void _rebaseTranslation() {
    _translationAnchor = _scroll.hasClients
        ? _scroll.position.pixels
        : double.nan;
    _translationStart = _translation.value;
    _translationSpan = _translationHeightAbove();
  }

  /// 当前行上面那些译文块的自然高度之和（不受折叠进度影响）
  double _translationHeightAbove() {
    if (_active <= 0) {
      return 0;
    }
    double sum = 0;
    for (int i = 0; i < _active && i < _translationKeys.length; i += 1) {
      final RenderObject? box = _translationKeys[i].currentContext
          ?.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        sum += box.size.height;
      }
    }
    return sum;
  }

  /// 收放结束时按最终布局再钉一次：逐帧补偿用的是上一帧的布局，跑完总会剩
  /// 下最后一帧那点残余，不收尾的话当前行会一直偏着
  void _onTranslationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _followTranslation();
        // 译文折叠会改行高，行区间跟着变
        _refreshRowOpacity();
      }
    });
  }

  /// 按动画进度补滚动，把当前行钉在原地。
  ///
  /// 补偿量是进度的一次函数，用同一个进度直接算，不必逐帧去量布局——那样
  /// 永远慢一帧，第一帧那下大位移补不上，看着就是当前行先跳一下再慢慢爬回来。
  void _followTranslation() {
    if (_userScrolling ||
        _active < 0 ||
        !_scroll.hasClients ||
        _translationAnchor.isNaN) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    final double target =
        _translationAnchor +
        _translationSpan * (_translation.value - _translationStart);
    final double clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - position.pixels).abs() > 0.5) {
      position.jumpTo(clamped);
    }
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
    // 切换中途换行的话，等这一帧跳完再按新布局重算补偿起点，别拿旧锚点继续补
    if (_translation.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _translation.isAnimating) {
          _rebaseTranslation();
        }
      });
    }
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
      // 滚动监听读到的是这一帧之前的位置，滚完再对一次
      _scheduleOpacityRefresh();
      return;
    }
    unawaited(
      position
          .animateTo(clamped, duration: _jumpDuration, curve: _jumpCurve)
          .whenComplete(_scheduleOpacityRefresh),
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        !_driving &&
        notification.dragDetails != null) {
      _beginUserScroll(restartTimer: false);
    } else if (notification is ScrollEndNotification && _userScrolling) {
      // 松手后给 3 秒观察时间，再跟回当前行
      _restartResumeTimer();
    }
    return false;
  }

  /// 用户开始接管滚动（拖动列表 / 鼠标滚轮）。
  ///
  /// 只做一件事：暂停自动跟随（不然刚滚开就被拽回当前行）。
  /// 不 setState——这层状态不参与绘制，重建整列只会白跑一次布局。
  void _beginUserScroll({bool restartTimer = true}) {
    // 旧的计时先作废：拖到一半被「停手 3 秒」拽回去会很突兀
    _resumeTimer?.cancel();
    _userScrolling = true;
    if (restartTimer) {
      // 滚轮每来一格就往后推 3 秒；拖动要等松手（ScrollEnd）才开始计时
      _restartResumeTimer();
    }
  }

  /// 停手满 3 秒就交还控制权：跟回当前行
  void _restartResumeTimer() {
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return ClipRect(
      // 滚动视图的抗锯齿裁剪会在上边界漏出 1px 的上一行笔画，ShaderMask 只
      // 覆盖自身边界以内，这 1px 就原样显示成一条淡横线。顶部内缩一个设备
      // 像素把它一起裁掉（那一行本来就在死区里，看不见内容）。
      clipper: _TopInsetClipper(1 / MediaQuery.devicePixelRatioOf(context)),
      child: Listener(
        // 鼠标滚轮 / 触摸板滚动不会带 dragDetails，光看滚动通知认不出「用户在滚」，
        // 这里补一手指针信号：滚动时同样暂停自动跟随
        onPointerSignal: (PointerSignalEvent event) {
          if (event is PointerScrollEvent) {
            _beginUserScroll();
          }
        },
        child: LayoutBuilder(
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
            // 左右对齐只在这个固定宽度的「块」里进行，块本身仍然居中：直接贴到
            // 歌词区两边的话，整首歌词会跑到一侧，另一侧空一大片
            final double band = math.min(
              _lyricBlockWidth,
              math.max(0, constraints.maxWidth - _scrollPaddingX * 2),
            );
            // 上下边界改成「按行给 alpha」（见 [_refreshRowOpacity]）：以前这里是
            // 整片歌词套一张 `ShaderMask`，那层是全宽的离屏图层，Impeller 每帧
            // 都要重新分配一次。`lyrics-edge-fade` 这个 key 留着——测试和调试
            // 按它取歌词视口的矩形。
            return KeyedSubtree(
              key: const ValueKey<String>('lyrics-edge-fade'),
              child: ScrollConfiguration(
                // 歌词区不要滚动条：桌面默认会在滚动时冒出一条竖条，
                // 压着封面和文字的边缘很难看
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
                      left: _scrollPaddingX,
                      right: _scrollPaddingX,
                    ),
                    child: Center(
                      child: SizedBox(
                        width: band,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (int i = 0; i < widget.lines.length; i += 1)
                              _SpringLyricLine(
                                key: ValueKey<String>('lyric-$i'),
                                index: i,
                                lineKey: _lineKeys[i],
                                anchorKey: _keys[i],
                                translationKey: _translationKeys[i],
                                jump: _jump,
                                line: widget.lines[i],
                                active: i == _active,
                                distance: _active < 0 ? i : (i - _active).abs(),
                                position: _smooth,
                                textTheme: theme.textTheme,
                                alignment: widget.alignment,
                                translation: _translation,
                                edgeOpacity: _edgeOpacityAt(i),
                                onSeek: widget.onSeek,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 取第 [i] 行的边界不透明度通知器（按需补齐，行数变化时跟着变）
  ValueListenable<double> _edgeOpacityAt(int index) {
    while (_rowOpacity.length <= index) {
      _rowOpacity.add(ValueNotifier<double>(1));
    }
    return _rowOpacity[index];
  }

  /// 重算每行的上下渐隐强度。
  ///
  /// 行位置只能等布局完成才读得到（[RenderBox]），所以这个方法都挂在「布局之后 /
  /// 滚动之后」：滚动时只刷可见的那一小段，静止时再全量对一次。
  /// 只把**变化超过 0.01** 的行写进通知器——滚动时通常就边界附近那几行会重绘。
  void _refreshRowOpacity({bool visibleOnly = false}) {
    final int count = widget.lines.length;
    if (count == 0 || !mounted) {
      return;
    }
    final RenderObject? self = context.findRenderObject();
    if (self is! RenderBox || !self.hasSize) {
      return;
    }
    final double height = self.size.height;
    if (height <= 0) {
      return;
    }
    // 与旧的遮罩用同一套曲线：顶部死区（行边界）+ 字迹起的淡入段 + 底部丝带
    final double deadZone = _topBoundary(height) + _fadeTopOffset;
    final double top = math.min(deadZone + _fadeTopRamp, height * 0.5);
    final List<double> stops = lyricFadeStops(
      height: height,
      top: top,
      band: widget.edgeFadeBand,
      deadZone: deadZone,
    );
    final int start = visibleOnly ? _firstVisible.clamp(0, count - 1) : 0;
    // 视口里最多露二十来行，多给一截余量，避免边界上漏更新
    final int end = visibleOnly ? math.min(count, start + 32) : count;
    for (int i = start; i < end; i += 1) {
      final RenderObject? box = _lineKeys[i].currentContext?.findRenderObject();
      double value = 1;
      if (box is RenderBox && box.hasSize && box.attached) {
        final double y = box.localToGlobal(Offset.zero, ancestor: self).dy;
        value = lyricRowOpacity(
          top: y,
          bottom: y + box.size.height,
          height: height,
          stops: stops,
        );
      }
      final ValueListenable<double> notifier = _edgeOpacityAt(i);
      if (notifier is ValueNotifier<double> &&
          (notifier.value - value).abs() > 0.01) {
        notifier.value = value;
      }
    }
  }

  /// 布局之后再刷一次渐隐（同一帧里多次调用只排一次）。
  ///
  /// 滚动监听里量到的是滚动之前的行位置，jumpTo / 译文折叠这类「一帧内改布局」
  /// 的操作要等这一帧画完才能量准。
  void _scheduleOpacityRefresh() {
    if (_opacityRefreshPending || !mounted) {
      return;
    }
    _opacityRefreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _opacityRefreshPending = false;
      _refreshRowOpacity();
    });
  }

  bool _opacityRefreshPending = false;

  /// 顶部死区的下边界：被视口上沿裁掉的那行整行消失，从下一行的顶边才开始
  /// 渐显。没有行被裁（最上面那行完整）时返回 0，走正常的顶部渐隐。
  ///
  /// 死区必须按行边界走，不能用固定像素：固定值必然切在某一行中间，那一行的
  /// 上半截被抹掉、下半截留下来，就是顶部那排断断续续的横线（字的底笔）。
  double _topBoundary(double height) {
    final RenderObject? self = context.findRenderObject();
    final int last = widget.lines.length - 1;
    if (self == null || last < 0) {
      return 0;
    }

    ({double top, double bottom})? bounds(int index) {
      final RenderObject? box = _lineKeys[index].currentContext
          ?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) {
        return null;
      }
      final double top = box.localToGlobal(Offset.zero, ancestor: self).dy;
      return (top: top, bottom: top + box.size.height);
    }

    // 从上次的位置滚动挪到「第一行还留在视口里的」。
    //
    // 不能拿 [active] 当起点：用户手动拖过之后当前行可能已经在视口外；也不能
    // 固定往前数几行——全屏时歌词区一千多像素、二十来行，顶部那行离当前行很
    // 远，数少了就漏掉它，于是误判成「最上面那行完整」、死区给 0，被裁的那行
    // 就露出来了（顶部那排横线）。滚动是连续的，从上次的位置挪几步就够。
    int first = _firstVisible.clamp(0, last);
    while (first > 0) {
      final ({double top, double bottom})? prev = bounds(first - 1);
      if (prev == null || prev.bottom <= 0.5) {
        break;
      }
      first -= 1;
    }
    while (first < last) {
      final ({double top, double bottom})? cur = bounds(first);
      if (cur == null || cur.bottom > 0.5) {
        break;
      }
      first += 1;
    }
    _firstVisible = first;

    final ({double top, double bottom})? head = bounds(first);
    if (head == null) {
      return _fallbackDeadZone(height);
    }
    if (head.top >= -0.5) {
      // 最上面这行是完整的：不需要死区
      return 0;
    }
    // 这行被上沿裁了：死区推到下一行的顶边，让它整行消失
    if (first < last) {
      final ({double top, double bottom})? next = bounds(first + 1);
      if (next != null && next.top > 0) {
        return deadZoneBoundary(next.top, height);
      }
    }
    return _fallbackDeadZone(height);
  }

  /// 量不到行位置时的兜底：按一行的高度估（22×1.45 + 上下各 9）
  double _fallbackDeadZone(double height) {
    return math.min(_fadeTop, height * 0.38) * 0.5;
  }
}

/// 与 [lyricFadeStops] 的 8 个 stop 一一对应的 alpha（S 形收尾）。
///
/// 顶部前两档都是 0，一直盖到 [lyricFadeStops] 的 0.5 处（[_fadeTop] 的一半，
/// 约一整行高）：被视口裁掉的行最多露这么多，再往下才允许出现任何亮度。
/// 底部保持原来的 70% / 12%，往下淡出不需要那么陡。
const List<Color> _fadeColors = <Color>[
  Color(0x00FFFFFF),
  Color(0x00FFFFFF),
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
    required this.translationKey,
    required this.jump,
    required this.line,
    required this.active,
    required this.distance,
    required this.position,
    required this.textTheme,
    required this.alignment,
    required this.translation,
    required this.edgeOpacity,
    required this.onSeek,
  });

  final int index;

  /// 挂在外层：算居中偏移用，绕开弹簧位移
  final GlobalKey lineKey;

  /// 挂在正文上：居中以正文为准，译文不会把当前行顶偏
  final GlobalKey anchorKey;

  /// 挂在译文块上：量它的自然高度，算收起 / 展开时该补多少滚动
  final GlobalKey translationKey;

  final ValueListenable<_LineJump> jump;
  final lyrics_api.LyricLine line;
  final bool active;
  final int distance;
  final ValueListenable<double> position;
  final TextTheme textTheme;
  final LyricAlignment alignment;

  /// 译文的展开进度（1 = 展开，0 = 收起）
  final ValueListenable<double> translation;

  /// 这一行的上下渐隐强度（0~1），由它在视口里的位置决定。
  ///
  /// 以前整片歌词套一张 `ShaderMask` 做边界淡出，那是一张全宽离屏图层；
  /// 改成按行把 alpha 乘进文字颜色之后，一个离屏图层都不产生。
  final ValueListenable<double> edgeOpacity;

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
    return ValueListenableBuilder<double>(
      valueListenable: widget.edgeOpacity,
      builder: (BuildContext context, double edge, Widget? child) {
        final Widget content = RepaintBoundary(
          child: _LyricLineView(
            anchorKey: widget.anchorKey,
            translationKey: widget.translationKey,
            line: widget.line,
            active: widget.active,
            distance: widget.distance,
            position: widget.position,
            textTheme: widget.textTheme,
            alignment: widget.alignment,
            translation: widget.translation,
            edgeOpacity: edge,
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
      },
    );
  }
}

/// 单行歌词：正文 +（罗马音 / 翻译）
class _LyricLineView extends StatelessWidget {
  const _LyricLineView({
    required this.anchorKey,
    required this.translationKey,
    required this.line,
    required this.active,
    required this.distance,
    required this.position,
    required this.textTheme,
    required this.alignment,
    required this.translation,
    required this.edgeOpacity,
    required this.onSeek,
  });

  /// 滚动居中的锚点：挂在正文上，译文不会把当前行顶偏
  final GlobalKey anchorKey;

  /// 译文块的 key：量自然高度用
  final GlobalKey translationKey;
  final lyrics_api.LyricLine line;
  final bool active;

  /// 与当前行的距离：用来做由近及远的透明度衰减
  final int distance;
  final ValueListenable<double> position;
  final TextTheme textTheme;

  /// 水平对齐方式：正文、译文、逐字染色层必须一致，否则当前行会歪
  final LyricAlignment alignment;

  /// 译文的展开进度（1 = 展开，0 = 收起），由整列共用同一个弹簧
  final ValueListenable<double> translation;

  /// 上下渐隐：整行统一乘进各段颜色（0 = 完全透明、1 = 原样）
  final double edgeOpacity;

  final Future<void> Function(double seconds) onSeek;

  @override
  Widget build(BuildContext context) {
    final bool interlude = line.text.trim().isEmpty;
    // 字号恒定（见 [_lyricFontSize]）：当前行的放大是外层 `AnimatedScale` 干的，
    // 这里只能改颜色 / 字重这类「怎么画」而不管「占多大地方」的属性
    final TextStyle style = (textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: _lyricFontSize,
      height: 1.45,
      // 字重会改字宽，长句理论上还是可能重新折行；中文假名的字宽是等宽的
      // （em 宽），实际不受影响，所以这一档强调保留
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      letterSpacing: 0.2,
    );

    // 歌词固定使用白色系，不跟随主题色；当前行最实，上下按距离淡出。
    //
    // 边界渐隐（视口上下沿）在这里一起乘进去：改的是颜色 alpha，不是套
    // `Opacity`/`ShaderMask`——那两者都要离屏图层，而这一层每帧都在重画。
    final double edge = edgeOpacity.clamp(0.0, 1.0);
    Color fade(Color color) =>
        edge >= 0.999 ? color : color.withValues(alpha: color.a * edge);
    final Color white = Colors.white;
    final Color activeColor = fade(white.withValues(alpha: 0.96));
    // 由近及远逐级压暗。远处行曾经还套一层 `ImageFiltered` 做「糊」，
    // 但 Impeller 没有光栅缓存：只要窗口里有动画在跑，每帧都会把这几百个
    // 模糊图层重新算一遍，纹理反复分配、RSS 一路涨到 400MB 以上。
    // 这些行本来就压到 0.26~0.62 的透明度，只留淡出看不出硬边。
    final Color dim = fade(
      white.withValues(
        alpha: switch (distance) {
          1 => 0.62,
          2 => 0.5,
          3 => 0.4,
          4 => 0.32,
          _ => 0.26,
        },
      ),
    );

    final Widget main;
    if (interlude) {
      main = Text(
        '♪',
        textAlign: alignment.textAlign,
        style: style.copyWith(
          fontSize: _lyricFontSize * 0.82,
          color: active ? activeColor : dim,
        ),
      );
    } else if (active && line.words.length >= 2) {
      main = _KaraokeText(
        text: line.text,
        words: line.words,
        lineEndMs: line.endMs.toInt(),
        position: position,
        style: style,
        baseColor: fade(white.withValues(alpha: 0.42)),
        highlightColor: fade(white),
        alignment: alignment,
      );
    } else {
      main = Text(
        line.text,
        textAlign: alignment.textAlign,
        style: style.copyWith(color: active ? activeColor : dim),
      );
    }

    final List<String> extras = line.translation
        .split('\n')
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList();

    // 译文的颜色随距离 / 边界渐隐变化，字号按是否中日韩文字分两档
    TextStyle extraStyle(String extra) {
      final bool cjk = _hasCjk(extra);
      return TextStyle(
        // 译文只比正文略小，避免层级断层；字号同样恒定，
        // 当前行靠外层那个缩放大一档
        fontSize: cjk ? 18 : 17,
        height: 1.4,
        color: fade(
          Colors.white.withValues(
            alpha: active ? (cjk ? 0.72 : 0.58) : (cjk ? 0.34 : 0.24),
          ),
        ),
      );
    }

    // 整块按对齐方式推到位。只改 TextAlign 不够：短行时 Text 的宽度就是文字
    // 自身宽度，它在 Column 里本来就贴着中线摆，文字对齐方式无从发挥
    Widget place(Widget child) =>
        Align(alignment: alignment.blockAlignment, child: child);

    // 当前行的「放大」：缩放整行文字，不是改字号（见 [_lyricFontSize]）。
    //
    // 锚点用 [LyricAlignment.blockAlignment]：横向跟着对齐方式（左对齐时左缘不动），
    // **竖直取中点**——放大出来的 8.7px 上下各溢出一半，刚好被上下那 9px 内边距
    // 吃掉，当前行与上下两行的间距才会一样。贴顶的话上面多 8.7、下面少 8.7。
    Widget emphasise(Widget child) => AnimatedScale(
      scale: active ? _activeLyricScale : 1,
      duration: _activeScaleDuration,
      curve: Curves.easeOutCubic,
      alignment: alignment.blockAlignment,
      child: child,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(onSeek(line.timeMs.toInt() / 1000)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 9,
          horizontal: _linePaddingX,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            KeyedSubtree(key: anchorKey, child: emphasise(place(main))),
            if (extras.isNotEmpty)
              // 译文跟着一起放大（不然当前行的译文会显得格外小），
              // 它自己成一个缩放：整行一起缩的话，译文收起时整块重心上移，
              // 会把正文带着晃 3px
              _TranslationBody(
                progress: translation,
                child: emphasise(
                  Column(
                    key: translationKey,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox(height: 3),
                      for (final String extra in extras)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: place(
                            Text(
                              extra,
                              textAlign: alignment.textAlign,
                              style: extraStyle(extra),
                            ),
                          ),
                        ),
                    ],
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

/// 译文 / 罗马音那一块，按整列共享的进度展开 / 收起。
///
/// 高度乘进度、从下沿裁掉（文字本身不会被压扁），和 `AnimatedSize` 的
/// `clipBehavior` 一个道理。子级一直留在树上——收起时它的自然高度还要用来
/// 算滚动补偿量，摘掉就量不到了。
/// 不叠 `Opacity`：那会给整块译文再开一层离屏图层，而它的高度每帧都在变。
class _TranslationBody extends StatelessWidget {
  const _TranslationBody({required this.progress, required this.child});

  /// 1 = 完全展开，0 = 收起
  final ValueListenable<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      // 树结构自始至终不变：结构一变（多一层 / 少一层），带 GlobalKey 的子级
      // 会被重新挂载，第一帧容易闪一下。收起时靠 opacity 0 直接跳过绘制，
      // 展开后 opacity 1 也不建图层，只有过渡那 300ms 会多一层。
      builder: (BuildContext context, double value, Widget? child) {
        final double factor = value.clamp(0.0, 1.0);
        return Opacity(
          // 按进度平方淡出：淡得比缩得快，等裁切边切到字中间时文字已经几乎
          // 透明，看不出这是一条硬边。不裁又不行——译文会压到下一行字上。
          opacity: factor * factor,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: factor,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
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
    required this.alignment,
  });

  final String text;
  final List<lyrics_api.LyricWord> words;
  final int lineEndMs;
  final ValueListenable<double> position;
  final TextStyle style;
  final Color baseColor;
  final Color highlightColor;
  final LyricAlignment alignment;

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
  LyricAlignment? _alignment;

  @override
  void didUpdateWidget(_KaraokeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.alignment != widget.alignment) {
      _width = -1;
    }
  }

  @override
  void dispose() {
    _base?.dispose();
    _highlight?.dispose();
    super.dispose();
  }

  /// 排版并量出每个字的矩形；只在文本 / 样式 / 对齐 / 宽度变化时重算
  void _layout(double width) {
    if (_width == width &&
        _text == widget.text &&
        _style == widget.style &&
        _alignment == widget.alignment) {
      return;
    }
    _width = width;
    _text = widget.text;
    _style = widget.style;
    _alignment = widget.alignment;

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
      // 折行后的每一行按对齐方式摆；单行时宽度就是文字宽度，由外层 Align 摆位
      textAlign: widget.alignment.textAlign,
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
/// 一次约 4ms；拆成两层：
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

/// 顶部内缩一段的裁剪区：挡掉滚动视图漏到上边界外的那 1px 笔画。
class _TopInsetClipper extends CustomClipper<Rect> {
  const _TopInsetClipper(this.inset);

  final double inset;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, inset, size.width, size.height);

  @override
  bool shouldReclip(_TopInsetClipper oldClipper) => oldClipper.inset != inset;
}

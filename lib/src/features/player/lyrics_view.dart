import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import '../../common/paint_cache.dart';
import '../../common/scroll/smooth_scroll.dart';
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
    this.blurEnabled = true,
    this.springScroll = true,
    this.fontFamily,
    this.fontSize = _defaultLyricFontSize,
    this.fontWeight = 400,
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

  /// 远处的行是否糊开（见 [lyricBlurSigma]）。
  ///
  /// 关掉只影响这一层：边界渐隐、距离淡出照旧，行 widget 与滚动锚定都不变。
  /// 「拖动时临时关模糊」仍然优先——滚动中一律不糊。
  final bool blurEnabled;

  /// 换行时整列是否弹簧地跟到新行（见 [_jumpToActive] 与 [_SpringLyricLine]）。
  ///
  /// 开着是「先跳到新位置、把视口内的行推回旧位置、再逐行错峰弹回」；关掉就
  /// 退化成普通的 420ms 平移（[_scrollToActive]），只有一次整体位移、没有推回、
  /// 没有逐行弹簧。**不能退成 jumpTo**：那样整列会一帧换位，看着是跳变。
  final bool springScroll;

  /// 歌词字体族（系统字体名）；null 表示跟随主题字体。
  ///
  /// 只作用于歌词正文，不动界面其余部分——想换的往往就是「歌词难看」，
  /// 不是整个应用的字体。
  final String? fontFamily;

  /// 歌词字号（逻辑像素，18–34）；当前行在此基础上放大 [_activeLyricSizeDelta]
  final double fontSize;

  /// 歌词字重（100–900）；当前行再加 [_activeWeightStep]，封顶 w900
  final int fontWeight;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

/// 上下淡出的渐变 stops（两端各用三段缓冲，中间全不透明）。
///
/// 直线渐变在「透明→不透明」走完的那一点上斜率突变，文字笔画从糊到清楚是
/// 一下子的，看着就是一条看不见的边。改成两段缓冲后，alpha 是 S 形收尾，
/// 边界感就散了。
///
/// 顶部一段由 [LyricsView] 自己按行框顶边算（见 `_fadeInRamp`），这里只需要
/// 把 [top] 之内的 alpha 给成 0、[top] 处到全不透明；传 0 就得到「顶部不淡、
/// 只淡底部」的曲线。
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
    t * 0.5,
    t * 0.8,
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

/// 顶部渐显走多少像素：约一行高（普通行 55、当前行 59）。
///
/// 按**行框顶边**连续取值，不再按「死区落在行边界」跳：行跨过原来那条线时
/// alpha 会从半亮一步掉到 0，滚轮一格 100+ px 更明显，看着就是整块消失。
/// 连续收尾之后行还没被裁就开始变暗，滚出上沿时正好是 0；而被裁的行顶边
/// 必然小于 0，也顺带归零，不会切出半截字（原来死区要防的就是这个）。
const double _fadeInRamp = 56;

/// 隔了 [distance] 行的模糊强度 σ（0 = 不糊）。
///
/// 一级一级往上加，中间不能有空档：之前排查内存时把 4 行以外的 σ 归零，
/// 结果第 3 行是糊的、第 4 行突然变清楚，画面上是「糊 → 清楚 → 再淡」的
/// 断档，看着像漏了处理。最远那几行本来就被边界渐隐压得很淡，糊一点即可。
@visibleForTesting
double lyricBlurSigma(int distance) => switch (distance) {
  0 => 0,
  1 => 0.5,
  2 => 1.1,
  3 => 1.8,
  4 => 2.5,
  _ => 3.2,
};

/// 逐字染色（卡拉 OK）总开关。
///
/// 这是歌词区最贵的一条分支：每帧都要重建 TextPainter 和逐字矩形路径。之前排查
/// 常驻内存时临时摘掉过，结论是**它不是泄漏源**（关掉后 RSS 曲线没有变化），
/// 所以保持打开。以后真要再旁路整条分支，把它改回 false 即可。
bool karaokeEnabled = true;

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

/// 歌词在**布局**里的字号默认值（设置里可改，18–34）。
///
/// 换行时千万不能改字号——字号一变，长句的折行会跟着变（22px 一行装得下、
/// 28px 要折成两行），整列的高度就重排了。而换行时每行的弹簧补偿只是一个
/// **统一的位移**：重排带来的位移它补不掉，画面上就是「整列瞬间跳一下」
/// （实测折行那句能把下面每行顶下去 41px）。
///
/// 当前行的放大改走 [_activeLyricSizeDelta] 换算出的 `Transform` 缩放：纯绘制
/// 变换，布局一点不动，补偿才补得准。
const double _defaultLyricFontSize = 22;

/// 当前行比正文大出多少像素（22 → 28 的效果），配一个 `AnimatedScale` 渐变
const double _activeLyricSizeDelta = 6;

/// 当前行比正文重多少（w400 → w600 的效果），封顶 w900
const int _activeWeightStep = 200;

/// 字号 + 字重：整列共用，从这里算出缩放倍数与间距补偿比例
class _LyricType {
  const _LyricType({required this.fontSize, required this.weight});

  final double fontSize;

  /// 100–900，与 `FontWeight` 的数值一致
  final int weight;

  /// 当前行的视觉放大倍数：字号大 6 px 对应的倍数
  double get scale => (fontSize + _activeLyricSizeDelta) / fontSize;

  /// 当前行放大后被吃掉的间距比例（见 [_emphasisGapRatioOf]）
  double get emphasisGapRatio => _emphasisGapRatioOf(scale);

  FontWeight get baseWeight => _fontWeightOf(weight);

  FontWeight get activeWeight => _fontWeightOf(weight + _activeWeightStep);

  /// 正文样式；译文按 0.82 / 0.77 倍字号另行给出
  TextStyle styleOf(TextTheme theme, {required bool active}) =>
      (theme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: fontSize,
        height: 1.45,
        fontWeight: active ? activeWeight : baseWeight,
        letterSpacing: 0.2,
      );
}

/// 数值字重 → `FontWeight`（100–900 落在 w100–w900 九档上，越界夹回）
FontWeight _fontWeightOf(int weight) {
  final int index = ((weight - 100) / 100).round().clamp(0, 8);
  return FontWeight.values[index];
}

/// 当前行放大 `scale` 倍后被「吃掉的」正文与译文间距比例
double _emphasisGapRatioOf(double scale) => (scale - 1) / (scale + 1);

/// 当前行放大的过渡：600ms 缓出。再快就还是「啪」地变大，再慢会拖到下一句都开唱了
const Duration _activeScaleDuration = Duration(milliseconds: 600);

/// 译文块顶部到第一行文字的固定内缩（`SizedBox` 3 + 上方 1px 内边距）
const double _translationInset = 4;

/// 当前行放大后，正文块与译文块之间的间距被吃掉多少，要补回多大一块。
///
/// 两块各以自身中心放大 `s` 倍：正文底边下移 `(s-1)/2 × 正文高`，译文顶边上移
/// `(s-1)/2 × 译文高` 再被块内那点固定内缩抵掉一截（内缩本身也跟着放大），
/// 间距被夹掉这么多。补在译文块内部的 `a` 经放大后视觉上是 `a × (s+1) / 2`
/// （块长高、中心又下移了一半），所以
/// `a = (s-1)/(s+1) × (正文高 + 译文高 − 2 × 内缩)`。行数越多、放大越明显，
/// 吃掉的越多：折成两行的正文加上一行译文，原来的 4px 间距只剩 2px。
///
/// 具体倍数由字号决定（见 [_LyricType.emphasisGapRatio]）。

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
///
/// 实际用的块宽还要过一遍 [_emphasisSafeTextWidth]：窗口窄下来时得给当前行的
/// 放大留余量，否则文字按块宽折好、再放大 1.27 倍就超出歌词视口，两头被裁掉。
const double _lyricBlockWidth = 640;

/// 当前行放大 `scale` 倍之后，一行文字最多能折多宽。
///
/// 放大是绘制变换（`AnimatedScale`），不参与布局：文字按 [band] 折好行，放大后
/// 左右各多出一截，块贴着视口边缘时就被裁掉（窗口越小裁得越多，截图上就是长句
/// 两头各少半个词）。这里从「放大后要落在 [available] 里」反推折行宽度，让长句
/// 在放大之前就折成两行，而不是放大后被切掉两头。
///
/// 只压文字、不压整块：块宽还决定左 / 右对齐时文字的落点，压窄了短句也会跟着
/// 往里挪。
///
/// - 居中：以块中心为锚点往两边长，`文字宽 × scale ≤ available`
/// - 左 / 右：锚点在一侧，多出来的宽度全压在那一侧。块本身是居中的（见
///   [_lyricBlockWidth]），能借到的只有「块边界到视口边界」那 `(available - band) / 2`
///   加上放大前文字外侧的内边距
double _emphasisSafeTextWidth({
  required double band,
  required double available,
  required LyricAlignment alignment,
  required double scale,
}) {
  final double inner = math.max(0, band - _linePaddingX * 2);
  if (available <= 0 || inner <= 0) {
    return 0;
  }
  final double safe = alignment == LyricAlignment.center
      ? available / scale
      : (available / 2 + band / 2 - _linePaddingX) / scale;
  // 留 1px：放大后正好贴到视口边缘的话，抗锯齿那一列会被裁出一道淡边
  return math.min(inner, math.max(0, safe - 1));
}

/// 取某个 key 当前排版高度；还没挂载或没布局时给 0
double _renderHeight(GlobalKey key) {
  final RenderObject? object = key.currentContext?.findRenderObject();
  return object is RenderBox && object.hasSize ? object.size.height : 0;
}

class _LyricsViewState extends State<LyricsView> with TickerProviderStateMixin {
  final SmoothScrollController _scroll = SmoothScrollController();

  /// 当前的字号 / 字重（设置里可改）：缩放倍数、间距补偿都从它算
  _LyricType get _type =>
      _LyricType(fontSize: widget.fontSize, weight: widget.fontWeight);

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

  /// 残差补偿层（[_AnchorShift]）的挂点：布局后量残差、绘制前平移
  final GlobalKey _shiftKey = GlobalKey();

  /// 切换期间「当前行的对齐偏移 − 实际滚动偏移」这个差值要恒定。
  ///
  /// 上面那条公式只数得进构建范围的行：视口外被 ListView 回收的行没有
  /// RenderObject，量不到译文高度，模型就少算一大截（一行译文约 30px）。
  /// 少算多少，当前行就被顶高多少，连点几下会一路往上爬。所以动画期间每帧
  /// 布局完都用 [_revealOffset] 量一次真实位置，把这个差值钉回去。
  double _translationGap = double.nan;

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

  /// 每行译文块的 key：量它的**自然高度**（不受折叠进度影响），用来算补偿量
  late List<GlobalKey> _translationKeys;

  /// 换行信号：整列已经 `jumpTo` 到位，各行按这个 `deltaY` 把自己推回去再弹回
  final ValueNotifier<_LineJump> _jump = ValueNotifier<_LineJump>(
    _LineJump.none,
  );
  int _jumpId = 0;

  double _base = 0;
  late final ValueNotifier<int> _activeNotifier = ValueNotifier<int>(-1);
  int get _active => _activeNotifier.value;
  bool _playing = false;
  bool _userScrolling = false;
  Timer? _resumeTimer;

  /// 正在自己 jumpTo：这期间滚动通知不是用户动作
  bool _driving = false;

  /// `jumpTo` 那一帧不重算渐隐（见 [_jumpToActive]）
  bool _suppressFade = false;

  /// 每行的边界不透明度（上下渐隐）。
  ///
  /// 一行一个通知器：滚动时只有靠近上下边界的那几行会变，其余行不重建。以前
  /// 这里是整片歌词外面套一张 `ShaderMask`——那层是全宽的离屏图层，滚动和
  /// 转场时每帧都要重新分配（Impeller 没有光栅缓存）。
  final List<ValueNotifier<double>> _rowOpacity = <ValueNotifier<double>>[];

  Timer? _scrollSettle;

  /// 上一次刷新渐隐时的滚动像素。
  ///
  /// 滚动监听回调那一刻布局还没重排，量到的行位置是**滚动之前**的；用两次
  /// pixels 的差把行「平移」过去，当帧就能算出正确的 alpha，不用等下一帧——
  /// 等下一帧的话，顶部那行会先按旧 alpha 亮一帧再消失（看起来是闪一下）。
  double? _lastPixels;

  /// 换行弹簧还在跑的时候，每帧重算一次渐隐。
  ///
  /// 换行是「先 `jumpTo` 到位，再让每行把自己推回去弹回来」：排版已经落到新
  /// 位置，屏幕上的行还在半路。而 alpha 只在滚动位置变化时重算，于是**行还没
  /// 滑到位，亮度已经先跳过去了** —— 顶部那几行每换一行就白 → 灰跳一下，看着
  /// 不像渐变。这里让 alpha 跟着弹簧的时间轴每帧重算，行滑到哪儿就淡到哪儿。
  ///
  /// 1100ms 覆盖「最后一行开始弹（错峰 26ms × 二十来行）+ 自己弹完」。
  AnimationController? _springWatch;

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
    _activeNotifier.value = _indexAt(_base);
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
    if (!_scroll.hasClients || _suppressFade) {
      return;
    }
    // 当帧就要正确：布局还没重排，量到的是滚动之前的位置，用 pixels 的差把行
    // 平移过去再算。少了这一步，顶部/底部那行会先按旧 alpha 亮一帧再消失
    // （滚轮一格一百多像素，肉眼就是「闪一下」）。之后再排一次布局后的刷新做校准。
    final double pixels = _scroll.position.pixels;
    final double delta = pixels - (_lastPixels ?? pixels);
    _lastPixels = pixels;
    _refreshRowOpacity(shiftY: -delta);
    _scheduleOpacityRefresh();
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
      _activeNotifier.value = -1;
      _smooth.value = _base;
      _activeNotifier.value = _indexAt(_base);
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

  void _onSpringTick() {
    if (mounted) {
      // 弹簧跑的时候只有当前行附近的几十行在移动
      _refreshRowOpacity(around: _active);
    }
  }

  AnimationController _watchSpring() {
    return _springWatch ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..addListener(_onSpringTick);
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
    _springWatch?.dispose();
    _scroll.dispose();
    _smooth.dispose();
    _jump.dispose();
    _translation.dispose();
    _activeNotifier.dispose();
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

  /// 以「当前滚动位置 + 当前进度」为起点重算补偿。
  ///
  /// [recenter]：换行触发的重算传 true。换行刚 `jumpTo` 归位过，当前行本来
  /// 就该精确停在对齐线上；但 jumpTo 用的是上一帧的布局，译文还在动，这一帧
  /// 的重排又会把行挪开一点，按 pixels 记 gap 会把这点漂移永久钉住。所以锚点
  /// 直接从「当前行应落在对齐线上」反推，gap 清零——后续逐帧校准全部以
  /// 对齐线为准，而不是以「重算那一刻恰好所在的位置」为准。
  void _rebaseTranslation({bool recenter = false}) {
    // 模型说的是滚动偏移，起点就取裸的 pixels（残差平移不参与模型）
    _translationAnchor = _scroll.hasClients
        ? _scroll.position.pixels
        : double.nan;
    _translationStart = _translation.value;
    _translationSpan = _translationHeightAbove();
    // 目标位置**只在第一次切换时量**。
    //
    // 动画中途再点一次（连点）时，画面上的当前行已经被残差层钉在原来的位置上，
    // 那才是要继续保持的位置。重新按 `reveal − pixels` 量一遍，量到的是布局
    // 与滚动偏移的关系，和「上一次真正画出来的位置」差着残差、还差着帧末校准
    // 刚做完还没画出来的那次跳转——每点一次就把当前行掰一下，连点就是上下抖。
    // 位置本身没变过，沿用上一个目标即可。
    if (_translationGap.isNaN) {
      _translationGap = _revealGap();
    }
    if (recenter) {
      final double reveal = _revealOffset(_active);
      if (!reveal.isNaN) {
        _translationGap = 0;
        _translationAnchor =
            reveal -
            _translationSpan * (_translation.value - _translationStart);
      }
    }
  }

  /// 当前行「对齐偏移 − 内容实际位置」的差值；量不到当前行时为 NaN
  ///
  /// 这里的「内容实际位置」是 [_contentOffset]（已含残差层的绘制平移），
  /// 所以记下来的是**画面上**的位置：动画中途再切一次（连点）时，基准是连续
  /// 的，不会因为残差把当前行掰一下。
  double _revealGap() {
    if (!_scroll.hasClients || _active < 0) {
      return double.nan;
    }
    final double reveal = _revealOffset(_active);
    if (reveal.isNaN) {
      return double.nan;
    }
    return reveal - _contentOffset;
  }

  /// 布局后、绘制前的残差补偿量；null = 保持现状（见 [_AnchorShift]）。
  ///
  /// 逐帧预估（[_followTranslation]）只能数到构建范围内的行：视口外的行被
  /// ListView 回收，几何冻结在最后已知的高度；动画中途它们带着当前进度的高度
  /// 重新进入构建范围，真实收缩率会台阶式上涨。恒定速率的预估模型每帧都会差
  /// 几个像素，而帧末校准（[_calibrateTranslation]）跳到的位置下一帧才画得出
  /// 来——两拍之间差的那几个像素，就是切译文时看得见的上下抖动。
  ///
  /// 这里在布局之后直接量「当前行离理想位置还差多少」，以绘制平移在**同一帧**
  /// 补齐；滚动位置仍由校准逐帧收敛，动画结束时两层一起归零。
  double? _anchorShiftDelta() {
    if (!_translation.isAnimating ||
        _userScrolling ||
        _active < 0 ||
        !_scroll.hasClients ||
        _translationGap.isNaN) {
      return null;
    }
    final ScrollPosition position = _scroll.position;
    final double reveal = _revealOffset(_active);
    if (reveal.isNaN) {
      return null;
    }
    final double ideal = (reveal - _translationGap).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // 只补预估的零头。残差一大说明滚动正被别的东西驱动（进度条跳转刚起步、
    // 边缘钳制），钉住内容反而错，交给驱动本身去走。
    final double shift = position.pixels - ideal;
    if (shift.abs() > 16) {
      return null;
    }
    return shift;
  }

  void _clearAnchorShift() {
    final RenderObject? renderObject = _shiftKey.currentContext
        ?.findRenderObject();
    if (renderObject is _RenderAnchorShift) {
      renderObject.clearShift();
    }
  }

  /// 残差层当前施加的绘制平移（还没画过就是 0）。
  ///
  /// 这一层平移让「布局位置」和「画出来的位置」差一个量：动画中途再切一次
  /// 译文时，如果按 `reveal − pixels` 记录当时的视觉基准，就会漏掉这层平移，
  /// 每点一次当前行就被那几像素掰一下——连点看着就是上下抖。
  double get _anchorShift {
    final RenderObject? renderObject = _shiftKey.currentContext
        ?.findRenderObject();
    if (renderObject is _RenderAnchorShift) {
      return renderObject.shift;
    }
    return 0;
  }

  /// 当前画面上内容实际滚到的位置：`pixels − 残差平移`。
  ///
  /// 一切补偿计算都用它，而不是裸的 `position.pixels`：`reveal − 它`
  /// 才是当前行真正画在屏幕上的位置（[_AnchorShift] 的 paint 平移已经算在内）。
  double get _contentOffset {
    if (!_scroll.hasClients) {
      return double.nan;
    }
    return _scroll.position.pixels - _anchorShift;
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
        // 动画已经停了，这里要强对一次：预估漏算的行只能在布局之后量出来
        _calibrateTranslation(force: true);
        // 残差补偿层收工：滚动已经校准到位，平移归零
        _clearAnchorShift();
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
    // 模型给的是「滚动偏移」；画面上差的那点残差由 [_AnchorShift] 补齐
    if ((clamped - position.pixels).abs() > 0.5) {
      position.jumpTo(clamped);
    }
    _scheduleTranslationCalibration();
  }

  /// 布局之后按真实位置对一次补偿（同一帧里只排一次）。
  ///
  /// 预估只数得到进构建范围的行，视口外的行漏算，误差会一直攒着往上顶。
  /// 这里量的是「当前行本来该在的对齐偏移」与「实际滚动偏移」之差：动画开始时
  /// 记下它，之后每帧把这个差值钉成常数，当前行就不会挪位。
  void _scheduleTranslationCalibration() {
    if (_translationCalibrating || !mounted) {
      return;
    }
    _translationCalibrating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _translationCalibrating = false;
      _calibrateTranslation();
    });
  }

  bool _translationCalibrating = false;

  void _calibrateTranslation({bool force = false}) {
    if (_userScrolling || (force != true && !_translation.isAnimating)) {
      return;
    }
    if (_translationGap.isNaN || !_scroll.hasClients) {
      return;
    }
    final double reveal = _revealOffset(_active);
    if (reveal.isNaN) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    final double delta = _translation.value - _translationStart;
    final double target = reveal - _translationGap;
    final double clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // 量出来的偏差就是模型漏算的那一截（只差在「上面那些行」的总高度上），
    // 顺手折算回每单位进度的补偿量，后面几帧的预估也就不再偏
    final double correction = clamped - position.pixels;
    if (correction.abs() > 0.5) {
      position.jumpTo(clamped);
      if ((target - clamped).abs() < 0.5 && delta.abs() > 0.05) {
        _translationSpan = math.max(0, _translationSpan + correction / delta);
      }
    }
    // 预估的起点跟着实际位置挪，免得下一帧又按旧锚点跳回去
    _translationAnchor = position.pixels - _translationSpan * delta;
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
    final int oldActive = _active;
    // 跨了一行以上 = 拖进度条 / 点歌词 / 切歌，不是自然换行
    final bool multiLine = (_active - next).abs() > 1;
    _activeNotifier.value = next; // 只更新 notifier，不 setState
    // 切换中途换行的话，等这一帧跳完再按新布局重算补偿起点，别拿旧锚点继续补。
    //
    // 但旧锚点必须**立刻**摘掉：换行自己会 `jumpTo` 把新行归位，而本轮帧里
    // 译文控制器的逐帧补偿（[_followTranslation]）还拿着「旧行」的锚点与补偿
    // 量，会把刚归位的滚动位置拉回旧行的目标；帧末重算（[_rebaseTranslation]）
    // 量到的是被拉歪之后的 pixels，错的差值从此被钉进 [_translationGap]，
    // 当前行就一直偏着，直到下一次换行才自愈。实测偏移量有五十多像素。
    // 锚点与差值一起置 NaN（两处补偿逻辑见 NaN 直接跳过），等这一帧布局完
    // 再按新行重算。
    if (_translation.isAnimating) {
      _translationAnchor = double.nan;
      _translationGap = double.nan;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _translation.isAnimating) {
          _rebaseTranslation(recenter: true);
        }
      });
    }
    if (_userScrolling) {
      // 用户还在拖：先别抢，松手 3 秒后再跟回来（见 [_onScrollNotification]）。
      //
      // 但拖动被系统打断时（指针取消、右键菜单抢走手势）ScrollEnd 不会来，
      // `_userScrolling` 就永远挂着、列表再也不跟随。这里补一道自愈：没有滚动
      // 活动、又没有待触发的计时器，就重新起一次「停手 3 秒」的计时。
      final bool timerArmed = _resumeTimer?.isActive ?? false;
      final bool scrolling =
          _scroll.hasClients && _scroll.position.isScrollingNotifier.value;
      if (!timerArmed && !scrolling) {
        _restartResumeTimer();
      }
      return;
    }
    // 上一行还是当前行时带着「正文与译文之间的间距补偿」，这一帧它不再是当前行、
    // 补偿收回去，整列会在它下面少掉这一截。跳转目标算的是旧布局，得先把这段
    // 高差减掉，否则落位之后再补一下就是一次回弹（[_emphasisGapAt]）。
    final double shrink = _emphasisGapAt(oldActive);
    if (_playing) {
      _jumpToActive(multiLine: multiLine, shrink: shrink);
    } else {
      // 暂停时没有 tick，点歌词 / 拖进度条换行只能一次性滑过去
      _scrollToActive(shrink: shrink);
    }
  }

  /// 第 [index] 行此刻带着的间距补偿（量它的两块排版高度反推）。
  ///
  /// 只有「当前行」带补偿，换行时上一行那段会收回去，见 [_updateActive]。
  double _emphasisGapAt(int index) {
    if (index < 0 || index >= _keys.length) {
      return 0;
    }
    final double main = _renderHeight(_keys[index]);
    final double block = _renderHeight(_translationKeys[index]);
    if (main <= 0 || block <= 0) {
      return 0;
    }
    // block 里已经含着补偿量 a：a = ratio × (main + block − a − 2 × 内缩)
    final double ratio = _type.emphasisGapRatio;
    return ratio * (main + block - 2 * _translationInset) / (1 + ratio);
  }

  /// 二分找最后一条 `time <= position` 的歌词
  int _indexAt(double seconds) => lyricIndexAt(widget.lines, seconds);

  /// 换行：整列瞬间归位，再让每一行自己弹回来（见 [_SpringLyricLine]）。
  void _jumpToActive({bool multiLine = false, double shrink = 0}) {
    if (_active < 0 || _active >= _keys.length || !_scroll.hasClients) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    if (!position.hasPixels) {
      return;
    }
    final double target = _revealOffset(_active);
    if (target.isNaN) {
      // 虚拟化之后「没进过视口」的行没有 RenderObject，量不到偏移：用户把歌词
      // 滚远了、或者拖进度条大跳，当前行就落在构建范围外。以前这里直接 return，
      // 而 `_updateActive` 只在**换行时**调本方法，于是这一行永远跳不过去、当前
      // 行越走越远，再也不会回到中间（顺带渐隐也不再刷新）。按平均行高先估一个
      // 位置把它拉进构建范围，落地后由 [_guessScrollToActive] 再精确对一次。
      _guessScrollToActive();
      return;
    }
    final double desired = target - shrink;
    final double clamped = desired.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final double delta = clamped - position.pixels;
    if (delta.abs() < 0.5) {
      return;
    }
    // 弹簧那套是「先跳到新位置、再把视口内的行推回旧位置、错峰弹回」。跨度一大
    // （点歌词、拖进度条、切歌）就有两个问题：推回只覆盖视口内那几行，其余行
    // 已经画在新位置上了，两批文字叠在一起就是残影；而且整列位移几百像素，
    // 看着也不像「换行」。
    //
    // 判据优先用「一次跨了几行」而不是像素：行高不一时（长句折行、带译文）
    // 同样的像素跨度对应的行数差很多。跨两行以上就走 420ms 的平滑滑动，
    // 中途不会出现「新位置直接出现」的那一帧；自然换行（一行几十像素）照旧走
    // 弹簧波浪。像素阈值留作兜底。
    if (multiLine || delta.abs() > position.viewportDimension * 0.5) {
      _scrollToActive();
      return;
    }
    if (!widget.springScroll) {
      // 关掉弹性滚动：不推回、不逐行错峰，退化成普通的 420ms 平移（[_scrollToActive]）。
      // 不能直接 jumpTo——那一帧整列「啪」地换位，看着就是跳变。
      _scrollToActive();
      return;
    }
    _driving = true;
    // 这一帧先别重算 alpha：`jumpTo` 已经把整列挪到新位置，但行还没推回去，
    // 现在算出来的是「新位置」的亮度，画面上却还是旧位置 —— 就是那一跳。
    // 交给下一帧的弹簧跟拍（[_watchSpring]）逐帧追。
    _suppressFade = true;
    position.jumpTo(clamped);
    _driving = false;
    final (int top, int bottom) = _visibleSpan(clamped);
    _jump.value = _LineJump(
      id: ++_jumpId,
      deltaY: delta,
      top: top,
      bottom: bottom,
    );
    _suppressFade = false;
    _watchSpring().forward(from: 0);
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

  void _scrollToActive({bool animate = true, double shrink = 0}) {
    if (_active < 0 || _active >= _keys.length || !_scroll.hasClients) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    final double target = _revealOffset(_active);
    if (target.isNaN) {
      // 虚拟化之后「从没进过视口」的行没有 RenderObject，量不到精确偏移
      // （切歌、拖进度条、点远处歌词都会走到这）。先按平均行高估个大概，
      // 等这一帧布局完再精确对一次。
      _guessScrollToActive();
      return;
    }
    final double clamped = (target - shrink).clamp(
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

  /// 目标行还没布局时的粗略定位：先按平均行高估，落地后再精确对一次。
  ///
  /// 纯「平均行高 × 序号」在折行导致行高不均时误差会按行数累积（长句多的歌，
  /// 第 100 行能差出好几屏），而一次估算后目标行常常还是没进构建范围。所以每次
  /// 落空都拿一行**已布局**的当锚点，用它的真实偏移反推，最多再来
  /// [_guessRounds] 轮——每轮都朝目标走一大步，通常第二轮就中了。
  void _guessScrollToActive() {
    if (!_scroll.hasClients) {
      return;
    }
    _jumpToEstimate(_averageLineExtent() * _active);
    _refineGuess(_guessRounds);
  }

  static const int _guessRounds = 2;

  void _jumpToEstimate(double offset) {
    final ScrollPosition position = _scroll.position;
    position.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  void _refineGuess(int rounds) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      final ScrollPosition position = _scroll.position;
      final double target = _revealOffset(_active);
      if (!target.isNaN) {
        position.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        _scheduleOpacityRefresh();
        return;
      }
      final int anchor = _firstLaidOutIndex();
      final double anchorOffset = anchor < 0
          ? double.nan
          : _revealOffset(anchor);
      if (rounds <= 0 || anchorOffset.isNaN) {
        // 这一帧就是走不到：至少把渐隐对上，别再拿旧 alpha 挂着
        _scheduleOpacityRefresh();
        return;
      }
      // 锚点的偏移是量出来的，只有「中间隔了几行」还在估
      _jumpToEstimate(anchorOffset + (_active - anchor) * _averageLineExtent());
      _refineGuess(rounds - 1);
    });
  }

  /// 最靠前的、已经布局过的那一行；一行都没有时返回 -1
  int _firstLaidOutIndex() {
    for (int i = 0; i < _lineKeys.length; i += 1) {
      final RenderObject? box = _lineKeys[i].currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        return i;
      }
    }
    return -1;
  }

  /// 已布局行里随便取一行的高度当平均行高（歌词行高基本一致）
  double _averageLineExtent() {
    for (final GlobalKey key in _lineKeys) {
      final RenderObject? box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.height > 1) {
        return box.size.height;
      }
    }
    return 64;
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
  /// 两件事：暂停自动跟随（不然刚滚开就被拽回当前行），并临时关掉远处行的模糊
  /// —— 滚动中一行都看不清，糊着只是白费光栅。上下的边界渐隐是外层遮罩，不受影响。
  void _beginUserScroll({bool restartTimer = true}) {
    // 拖动期间滚动位置归用户管，残差补偿层跟着清零
    _clearAnchorShift();
    // 用户自己滚过之后，当前行不再停在对齐线上：切换目标作废，下次切换重新量
    _translationGap = double.nan;
    _translationAnchor = double.nan;
    // 旧的计时先作废：拖到一半被「停手 3 秒」拽回去会很突兀
    _resumeTimer?.cancel();
    if (!_userScrolling) {
      setState(() => _userScrolling = true);
    }
    if (restartTimer) {
      // 滚轮每来一格就往后推 3 秒；拖动要等松手（ScrollEnd）才开始计时
      _restartResumeTimer();
    }
  }

  /// 停手满 3 秒就交还控制权：跟回当前行，模糊一起回来
  void _restartResumeTimer() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      setState(() => _userScrolling = false);
      if (_playing) {
        _jumpToActive();
      } else {
        // 暂停中没有 tick，自己滑回去
        _scrollToActive();
      }
    });
  }

  /// 歌词用的 TextTheme：把「歌词字体」设置套在主题上。
  ///
  /// 走 `TextTheme.apply` 而不是在每个 `TextStyle.copyWith` 里塞 family：
  /// 正文、逐字染色层、译文三处都从同一个 `textTheme` 取样式，套一次全对上，
  /// 漏改一处就会出现「正文换了、译文还是雅黑」。
  TextTheme _lyricTheme(TextTheme base) {
    final String? family = widget.fontFamily;
    if (family == null || family.isEmpty) {
      return base;
    }
    return base.apply(fontFamily: family);
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
        // 这里补一手指针信号：滚动时同样暂停自动跟随、并临时关掉远处的模糊
        onPointerSignal: (PointerSignalEvent event) {
          if (event is PointerScrollEvent) {
            _beginUserScroll();
          }
        },
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 高度变了就得重新对齐并重算渐隐（见 [_onViewportResized]）。
            // 基准只在真正修正过后才推进：慢拖窗口边缘时每帧变化可能都不到
            // 0.5，若每帧都把基准刷成当前高度，累计变化再大也永远触发不了修正。
            final double? lastHeight = _lastViewportHeight;
            if (lastHeight == null) {
              _lastViewportHeight = constraints.maxHeight;
            } else if ((constraints.maxHeight - lastHeight).abs() >= 0.5) {
              _lastViewportHeight = constraints.maxHeight;
              _onViewportResized();
            }
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
            // 歌词区两边的话，整首歌词会跑到一侧，另一侧空一大片。
            // 块里的文字还要按放大后的样子再收一道（见 [_emphasisSafeTextWidth]）。
            final double available = math.max(
              0,
              constraints.maxWidth - _scrollPaddingX * 2,
            );
            final double band = math.min(_lyricBlockWidth, available);
            final double textWidth = _emphasisSafeTextWidth(
              band: band,
              available: available,
              alignment: widget.alignment,
              scale: _type.scale,
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
                  // 只建视口附近的行。以前是 `SingleChildScrollView + Column`：
                  // 整首歌几十上百行全部建成 widget / RenderObject，一行一份
                  // 排版对象和图层，歌词一多就是几十 MB（release 实测 60 行比
                  // 无歌词多 65MB，且与行数无关的那部分全压在滚动上）。
                  //
                  // `addRepaintBoundaries: false`：行内自己已经有一层
                  // `RepaintBoundary`（弹动复用光栅），再让 ListView 包一层是
                  // 两层边界、两张位图。
                  child: _AnchorShift(
                    key: _shiftKey,
                    resolve: _anchorShiftDelta,
                    child: ListView.builder(
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
                      // 视口外多留几行（400px ≈ 6 行）：换行时相邻行要能被弹簧推到，
                      // 留太少会看到「从无到有」地冒出来
                      scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: false,
                      itemCount: widget.lines.length,
                      itemBuilder: (BuildContext context, int index) => Center(
                        child: SizedBox(
                          width: band,
                          child: _LyricLineWrapper(
                            index: index,
                            activeNotifier: _activeNotifier,
                            lineKey: _lineKeys[index],
                            anchorKey: _keys[index],
                            translationKey: _translationKeys[index],
                            jump: _jump,
                            line: widget.lines[index],
                            position: _smooth,
                            textTheme: _lyricTheme(theme.textTheme),
                            alignment: widget.alignment,
                            textWidth: textWidth,
                            type: _type,
                            translation: _translation,
                            userScrolling: _userScrolling,
                            blurEnabled: widget.blurEnabled,
                            edgeOpacity: _edgeOpacityAt(index),
                            onSeek: widget.onSeek,
                          ),
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
  ///
  /// 位置取正文锚点（[_keys]，在弹簧的 `Transform` 里）而不是行框（[_lineKeys]）：
  /// 换行后排版已经落到新位置、行还要弹 300ms，只有锚点量得到这期间的实际位置。
  /// [shiftY]：把量到的行位置整体平移多少像素。
  ///
  /// 滚动回调里布局还没重排，行的位置还是滚动之前的；传入 `-滚动增量` 就能
  /// 按「滚动之后」的位置算 alpha，不必等下一帧。
  void _refreshRowOpacity({int? around, double shiftY = 0}) {
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
    // 只需要底部的「丝带 + 过渡段」：顶部交给下面按行框顶边的连续渐显，
    // 走 stops 的话它会和死区/行边界一起跳，反而画出硬切。
    final List<double> stops = lyricFadeStops(
      height: height,
      top: 0,
      band: widget.edgeFadeBand,
    );
    // 默认全量跑一遍：没进视口的行没有 RenderObject，下面会整段跳过，代价只是
    // 一次 null 检查。弹簧跟拍是每帧都调的，那时只有当前行附近的几十行会动，
    // 用 [around] 收窄。
    final int start = around == null ? 0 : math.max(0, around - 24);
    final int end = around == null ? count : math.min(count, around + 40);
    for (int i = start; i < end; i += 1) {
      final RenderObject? line = _lineKeys[i].currentContext
          ?.findRenderObject();
      final RenderObject? text = _keys[i].currentContext?.findRenderObject();
      double value = 1;
      if (line is RenderBox &&
          line.hasSize &&
          line.attached &&
          text is RenderBox &&
          text.hasSize &&
          text.attached) {
        final double layoutTop = line
            .localToGlobal(Offset.zero, ancestor: self)
            .dy;
        // 正文锚点的实际位置减去排版偏移 = 弹簧把这一行推开了多少
        final double spring =
            text.localToGlobal(Offset.zero, ancestor: self).dy -
            layoutTop -
            _layoutOffset(text, line).dy;
        final double y = layoutTop + spring + shiftY;
        value =
            lyricRowOpacity(
              top: y,
              bottom: y + line.size.height,
              height: height,
              stops: stops,
            ) *
            _topFadeIn(y);
      }
      // 当前行不吃上下沿渐隐——但只在**没人滚它**的时候。
      //
      // 平时当前行停在对齐线上碰不到渐隐带，但歌词区矮 + 频谱丝带把底边推高、
      // 或者对齐线本身偏低时，它会落进带内，此时正在唱的字被乘掉二三成亮度，
      // 已唱的白看着是灰的。
      //
      // 反过来，用户手动滚列表把当前行带到视口边缘时，它必须和其他行一样淡出：
      // 否则滚到顶部就是「亮着被硬切」，比灰还难看。
      if (i == _active && !_userScrolling) {
        value = 1;
      }
      final ValueListenable<double> notifier = _edgeOpacityAt(i);
      if (notifier is ValueNotifier<double> &&
          (notifier.value - value).abs() > 0.01) {
        notifier.value = value;
      }
    }
  }

  /// 顶部渐显：行框顶边从视口上沿（0）往上 [_fadeInRamp] 内线性淡入。
  ///
  /// 取「行框顶边」而不是取区间平均：顶边一旦小于 0 就说明这行已经被视口裁了，
  /// 直接归零，不会露出半截字；而顶边还在 0 之上时是连续的，不会出现整块跳掉。
  double _topFadeIn(double y) {
    if (y <= 0) {
      return 0;
    }
    if (y >= _fadeInRamp) {
      return 1;
    }
    final double t = y / _fadeInRamp;
    return t * t * (3 - 2 * t);
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

  /// 上一次**已修正**的歌词视口高度（见 [_onViewportResized]）；
  /// 不随每帧布局更新，否则连续的小幅变化会把差值抹平
  double? _lastViewportHeight;
  bool _resizeFixPending = false;

  /// 视口高度变了（窗口化 ↔ 全屏、拖窗口边缘）。
  ///
  /// 尺寸变化不会触发滚动监听：`pixels` 没动，可渐隐带厚度与当前行的对齐位置
  /// 全是按旧高度算的，界面上就是「整片歌词停在旧位置、边上淡出不对」，要等到
  /// 下一句换行才纠正。这里等这一帧布局完重新对齐当前行、再全量重算一遍。
  void _onViewportResized() {
    if (_resizeFixPending || !mounted) {
      return;
    }
    _resizeFixPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resizeFixPending = false;
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      // 用户自己滚着的时候不抢位置，但渐隐仍要按新高度对上
      if (!_userScrolling) {
        // 重新定位是一次跳变，别让滚动监听把这次的位移当成用户滚动去补偿
        _lastPixels = null;
        _scrollToActive(animate: false);
      }
      _refreshRowOpacity();
    });
  }
}

/// 与 [lyricFadeStops] 的 8 个 stop 一一对应的 alpha（S 形收尾）。
///
/// 顶部前两档是 0，只有 [lyricFadeStops] 传了非 0 的 `top` 才用得上；底部
/// 保持原来的 70% / 12%，往下淡出不需要那么陡。
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

/// 歌词行包装器：监听 `_active` 变化，只有 distance 变了才重建这一行。
///
/// 视口外的行由外层 `ListView.builder` 自己回收，这里不必再按距离截断。
/// 之前为了省内存把 15 行以外换成占位 `SizedBox`，结果「还没唱到第一句」
/// （active = -1，distance 退化成行号）和用户手动滚远时，屏幕上是一排空行。
class _LyricLineWrapper extends StatelessWidget {
  const _LyricLineWrapper({
    required this.index,
    required this.activeNotifier,
    required this.lineKey,
    required this.anchorKey,
    required this.translationKey,
    required this.jump,
    required this.line,
    required this.position,
    required this.textTheme,
    required this.alignment,
    required this.textWidth,
    required this.type,
    required this.translation,
    required this.userScrolling,
    required this.blurEnabled,
    required this.edgeOpacity,
    required this.onSeek,
  });

  final int index;
  final ValueNotifier<int> activeNotifier;
  final GlobalKey lineKey;
  final GlobalKey anchorKey;
  final GlobalKey translationKey;
  final ValueNotifier<_LineJump> jump;
  final lyrics_api.LyricLine line;
  final ValueNotifier<double> position;
  final TextTheme textTheme;
  final LyricAlignment alignment;
  final _LyricType type;

  /// 一行文字最多折多宽（含当前行放大的余量，见 [_emphasisSafeTextWidth]）
  final double textWidth;
  final Animation<double> translation;
  final bool userScrolling;

  /// 设置里的模糊总开关；关掉时这一行永远不糊
  final bool blurEnabled;

  final ValueListenable<double> edgeOpacity;

  final Future<void> Function(double) onSeek;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: activeNotifier,
      builder: (context, active, _) {
        final int distance = active < 0 ? index : (index - active).abs();
        return _SpringLyricLine(
          key: ValueKey<String>('lyric-$index'),
          index: index,
          lineKey: lineKey,
          anchorKey: anchorKey,
          translationKey: translationKey,
          jump: jump,
          line: line,
          active: index == active,
          distance: distance,
          position: position,
          textTheme: textTheme,
          alignment: alignment,
          textWidth: textWidth,
          type: type,
          translation: translation,
          blur: blurEnabled && !userScrolling,
          edgeOpacity: edgeOpacity,
          onSeek: onSeek,
        );
      },
    );
  }
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
    required this.textWidth,
    required this.type,
    required this.translation,
    required this.blur,
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

  /// 一行文字最多折多宽（含当前行放大的余量，见 [_emphasisSafeTextWidth]）
  final double textWidth;

  /// 字号 / 字重（整列共用）
  final _LyricType type;

  /// 译文的展开进度（1 = 展开，0 = 收起）
  final ValueListenable<double> translation;

  /// 是否给远处的行加模糊。用户正在拖动列表时传 false：
  /// 滚动中一片糊没有信息量，还每帧都要多跑一遍光栅
  final bool blur;

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

  /// 当前行放大后被「吃掉的」正文与译文之间的间距，补在两者中间。
  ///
  /// 正文块与译文块各缩各的（见 [_LyricLineView.emphasise]），都以自身中心为锚点
  /// 放大 `scale` 倍（见 [_LyricType.scale]）：正文往下长出 `(scale-1)/2 × 正文高`，
  /// 译文往上长出 `(scale-1)/2 × 译文高`，两块之间那 4px 间距根本不够吃——一行正文时还
  /// 剩一点，折成两行就直接贴上（实测墨迹只剩 2px）。这里把两块自然高度量出来，
  /// 把被吃掉的量补回去，当前行的译文间距就与不放大时一致。
  ///
  /// 只有当前行需要，所以是**布局**高度、只在 active 时生效：其余行保持原来的
  /// 紧凑间距；当前行的锚点在它上方，本行长高不会把它自己顶偏（但它上面那一行
  /// 收回间距会把当前行整体上移，由 [_updateActive] 把这段高差算进跳转目标）。
  double _emphasisGap = 0;

  /// 上一帧真正用在布局里的间距：量高度时要把它扣掉
  double _appliedGap = 0;

  @override
  void initState() {
    super.initState();
    widget.jump.addListener(_onJump);
  }

  /// 量出正文块 / 译文块的布局高度（不受放大影响），算出该补多少间距。
  ///
  /// 只在布局之后量（构建期读不到子级的 RenderObject），量到的值存下来给下一次
  /// 构建用。两块高度只跟文字、折行宽度有关，与当前行无关，所以「上一帧的值」
  /// 就是这个值；而行变成当前行时一定会重建一次，那时取到的已经是对的。
  void _measureEmphasisGap() {
    if (!mounted) {
      return;
    }
    final double main = _renderHeight(widget.anchorKey);
    // 量到的译文块高度里已经含着上一次补的间距，先扣掉才是它的自然高度
    final double translation = math.max(
      0,
      _renderHeight(widget.translationKey) - _appliedGap,
    );
    if (main <= 0 || translation <= 0) {
      return;
    }
    // 块顶到第一行文字那点内缩放大后也会多出一截（`s × 内缩`），把侵蚀抵掉
    // 一点，所以是「正文 + 译文 − 2 倍内缩」而不是两者之和。
    final double gap =
        widget.type.emphasisGapRatio *
        (main + translation - 2 * _translationInset);
    if ((gap - _emphasisGap).abs() < 0.5) {
      return;
    }
    setState(() => _emphasisGap = gap);
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
    // 间距只给当前行，且换行那一帧就要用上：取上一次布局后量好的值（两块高度
    // 与当前行无关，所以它一直是对的），帧末再把下一帧要用的量出来。
    _appliedGap = widget.active ? _emphasisGap : 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureEmphasisGap());
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
            textWidth: widget.textWidth,
            type: widget.type,
            emphasisGap: _appliedGap,
            translation: widget.translation,
            blur: widget.blur,
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
    required this.textWidth,
    required this.type,
    required this.emphasisGap,
    required this.translation,
    required this.blur,
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

  /// 一行文字最多折多宽（含当前行放大的余量，见 [_emphasisSafeTextWidth]）
  final double textWidth;

  /// 字号 / 字重（整列共用）
  final _LyricType type;

  /// 当前行放大后要补回的正文 / 译文间距（见 [_SpringLyricLineState._emphasisGap]）
  final double emphasisGap;

  /// 译文的展开进度（1 = 展开，0 = 收起），由整列共用同一个弹簧
  final ValueListenable<double> translation;

  /// 是否给远处行加模糊；拖动列表期间会被关掉（见 [_LyricsViewState]）
  final bool blur;

  /// 上下渐隐：整行统一乘进各段颜色（0 = 完全透明、1 = 原样）
  final double edgeOpacity;

  final Future<void> Function(double seconds) onSeek;

  @override
  Widget build(BuildContext context) {
    final bool interlude = line.text.trim().isEmpty;
    // 字号由设置给定、整列恒定：当前行的放大是外层 `AnimatedScale` 干的，这里
    // 只能改颜色 / 字重这类「怎么画」而不管「占多大地方」的属性。当前行再加一档
    // 字重（见 [_LyricType.activeWeight]），默认就是原来的 w400 / w600
    final TextStyle style = type.styleOf(textTheme, active: active);

    // 歌词固定使用白色系，不跟随主题色；当前行最实，上下按距离淡出。
    // 有了模糊之后不再一味压低透明度：远处那几行靠「糊」退出焦点，
    // alpha 压太狠的话糊都看不见，层次只剩「有字 / 没字」两档
    //
    // 边界渐隐（视口上下沿）在这里一起乘进去：改的是颜色 alpha，不是套
    // `Opacity`/`ShaderMask`——那两者都要离屏图层，而这一层每帧都在重画
    final double edge = edgeOpacity.clamp(0.0, 1.0);
    Color fade(Color color) =>
        edge >= 0.999 ? color : color.withValues(alpha: color.a * edge);
    final Color white = Colors.white;
    final Color activeColor = fade(white.withValues(alpha: 0.96));
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
          color: active ? activeColor : dim,
          fontSize: type.fontSize * 0.82,
        ),
      );
    } else if (karaokeEnabled && active && line.words.length >= 2) {
      main = _KaraokeText(
        text: line.text,
        words: line.words,
        lineEndMs: line.endMs.toInt(),
        position: position,
        style: style,
        // 底色是「还没唱到」的部分。要和已唱的白拉开差距才看得出唱到哪了，
        // 但当前行不能比相邻行更灰（相邻行 distance=1 是 0.62）——那样刚跳到
        // 这一行、一个字都还没唱时，看着像没高亮。取 0.62 与相邻行同一档：
        // 当前行还有字号更大、字重更重、不吃模糊三样把它顶出来。
        baseColor: fade(white.withValues(alpha: 0.62)),
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

    // 越远的行越虚：靠模糊表现「退出焦点」。只压不透明度的话，文字笔画在
    // 某个 alpha 上还是清清楚楚的，边缘就还是硬的；糊开之后没有了高频细节，
    // 再叠上遮罩的淡出才是渐进的。
    //
    // 从相邻一行就开始给一点糊，一级一级往上加：之前是 1 行全清、2 行直接
    // σ1.2，一格就跳过去，看着像被分成「清楚」和「不清楚」两半。
    //
    // 用户拖动列表时临时关掉：滚动中一片糊没有信息量，而且每一行都要多跑一遍
    // 模糊光栅。上下的边界渐隐是外层遮罩，跟这里无关，照旧生效。
    //
    // 强度曲线见 [lyricBlurSigma]，**不按距离截断**：断在第 3 行的效果是画面上
    // 出现「糊 → 清楚 → 再淡」的断档。模糊本身每行只是一次小面积离屏；当年
    // 真正吃内存的是每行多挂的一层 `Transform`（见 [emphasise]）
    //
    // 已经被边界淡到全透明（`edge == 0`，顶部死区里那行、以及视口下方缓存区
    // 的行）就不糊：那一层离屏图层画出来也看不见，白占一次光栅。
    final double blurSigma = blur && edge > 0 ? lyricBlurSigma(distance) : 0;

    final List<String> extras = line.translation
        .split('\n')
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList();

    /// 译文跟正文一起糊：只糊正文时，未播放的行会出现「上面一团虚、下面
    /// 一行清清楚楚」的割裂感，看着像漏处理。
    ///
    /// 关模糊走 `enabled: false`，不换树结构：开始拖动、行进出死区时只改一个
    /// 属性，`Text` 的 Element / RenderParagraph 原地保留。换成「不包这一层」
    /// 会整段重建重排，一次性挂摘两百个 `ImageFiltered` 实测直接掉帧。
    Widget soften(Widget child) => ImageFiltered(
      enabled: blurSigma > 0,
      imageFilter: ImageFilterCache.imageFilter(sigma: blurSigma),
      child: child,
    );

    // 整块按对齐方式推到位。只改 TextAlign 不够：短行时 Text 的宽度就是文字
    // 自身宽度，它在 Column 里本来就贴着中线摆，文字对齐方式无从发挥
    //
    // 折行宽度由 [textWidth] 再收一道（当前行放大后不能超出歌词视口）：`Align`
    // 只给松约束，套一层 `ConstrainedBox` 就能把「文字按多宽折行」和「整块摆哪」
    // 分开——`Align` 自己仍然是整列的宽，左右对齐的落点不跟着变。
    Widget place(Widget child) => Align(
      alignment: alignment.blockAlignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: textWidth),
        child: child,
      ),
    );

    // 当前行的「放大」：缩放整行文字，不是改字号（见 [_LyricType.scale]）。
    //
    // 锚点用 [LyricAlignment.blockAlignment]：横向跟着对齐方式（左对齐时左缘不动），
    // **竖直取中点**——放大出来的那点高度上下各溢出一半，刚好被上下那 9px 内边距
    // 吃掉，当前行与上下两行的间距才会一样。贴顶的话上面多一截、下面少一截。
    Widget emphasise(Widget child) => !active
        ? child
        : AnimatedScale(
            scale: type.scale,
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
            // 模糊层要贴着文字：套在外面的话，整行宽（可能上千像素）都要糊一遍
            KeyedSubtree(key: anchorKey, child: emphasise(place(soften(main)))),
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
                      // 间距跟着译文一起收起，也一起被放大（见 [_LyricType.emphasisGapRatio]）。
                      // 这里的 3 + 下面那 1px 内边距之和 = [_translationInset]，
                      // 改这两个数要顺手改那个常量。
                      SizedBox(height: 3 + emphasisGap),
                      for (final String extra in extras)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: place(
                            soften(
                              Text(
                                extra,
                                textAlign: alignment.textAlign,
                                style: TextStyle(
                                  // 译文只比正文略小，避免层级断层；字号同样恒定，
                                  // 当前行靠外层那个缩放大一档
                                  fontSize:
                                      type.fontSize *
                                      (_hasCjk(extra) ? 0.82 : 0.77),
                                  height: 1.4,
                                  fontWeight: type.baseWeight,
                                  color: fade(
                                    Colors.white.withValues(
                                      alpha: active
                                          ? (_hasCjk(extra) ? 0.72 : 0.58)
                                          : (_hasCjk(extra) ? 0.34 : 0.24),
                                    ),
                                  ),
                                ),
                              ),
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
/// 不叠 `Opacity`：这里面的文字压着模糊层，加透明度会逐帧退回 saveLayer。
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
        // 展开后整块跟着当前行放大 1.27 倍（见 `emphasise`），**绘制范围会比
        // 布局高度多出上下各 (factor-1)*h/2**：两行译文时约 7px。这一档不能裁，
        // 否则当前行的罗马音 / 译文最后一笔会被切平（截图里就是「下方缺一条」）。
        // 多出来的 7px 落在行内那 9px 下内边距里，压不到下一行。
        // 收起过程中还得裁：高度乘进度时文字会压到下一行字上。
        final bool collapsed = factor < 0.999;
        return Opacity(
          // 按进度平方淡出：淡得比缩得快，等裁切边切到字中间时文字已经几乎
          // 透明，看不出这是一条硬边。不裁又不行——译文会压到下一行字上。
          opacity: factor * factor,
          child: ClipRect(
            clipBehavior: collapsed ? Clip.hardEdge : Clip.none,
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

  /// 上次排版用的两个颜色。
  ///
  /// **必须参与复用判断**：这两个颜色是「白色 × 行级渐隐」，滚动、进出渐隐带、
  /// 当前行切换时每帧都在变；少了这一步，颜色变了却复用旧 painter，高亮会一直
  /// 停在第一次排版时的那个亮度——跳转后看着「很灰」就是这么来的。
  Color? _baseColor;
  Color? _highlightColor;

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

  /// 排版并量出每个字的矩形；只在文本 / 样式 / 对齐 / 宽度变化时重算。
  ///
  /// 颜色**不算**几何变化：它只影响两个 [TextPainter] 的画笔，逐字的
  /// `getBoxesForSelection` 与颜色无关。行级渐隐把 alpha 乘进颜色里，滚动时
  /// 当前行每帧都在变——按几何一起重算的话，每帧都要重排一遍并重算每个字的矩形。
  void _layout(double width) {
    final bool geometry =
        _width != width ||
        _text != widget.text ||
        _style != widget.style ||
        _alignment != widget.alignment;
    if (!geometry &&
        _baseColor == widget.baseColor &&
        _highlightColor == widget.highlightColor) {
      return;
    }
    _width = width;
    _text = widget.text;
    _style = widget.style;
    _alignment = widget.alignment;
    _baseColor = widget.baseColor;
    _highlightColor = widget.highlightColor;

    _base?.dispose();
    _highlight?.dispose();
    final TextPainter base = _painter(widget.baseColor, width);
    _base = base;
    _highlight = _painter(widget.highlightColor, width);

    if (!geometry) {
      return;
    }
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

/// 把「帧末校准」提前到绘制前的残差补偿层（包着歌词 [ListView]）。
///
/// 逐帧预估（[_FollowTranslation]）在动画相位里跳，帧末校准（
/// [_CalibrateTranslation]）要等布局完才能量到真实位置，跳转下一帧才画得
/// 出来——两拍之间差的那几个像素就是切译文时的上下抖动。这个 RenderObject
/// 在自己 performLayout 的尾部（子树已布局完、还没绘制）量出残差，直接以
/// 绘制平移在同一帧补齐。
class _AnchorShift extends SingleChildRenderObjectWidget {
  const _AnchorShift({required this.resolve, required super.child, super.key});

  /// 布局完成后询问绘制平移量；返回 null 表示保持现状
  final double? Function() resolve;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderAnchorShift(resolve);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAnchorShift renderObject,
  ) {
    renderObject.resolve = resolve;
  }
}

class _RenderAnchorShift extends RenderProxyBox {
  _RenderAnchorShift(this.resolve);

  double? Function() resolve;

  double _shift = 0;

  /// 当前施加的绘制平移（正 = 内容往下多画）。补偿计算要靠它把「画出来的
  /// 位置」算准，否则动画中途再切一次会把基准挪走（连点时上下抖）。
  double get shift => _shift;

  /// 动画被打断（动画结束、用户开始拖动）时把残留的平移清掉。
  void clearShift() {
    if (_shift == 0) {
      return;
    }
    _shift = 0;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // 残差要在 paint 里量而不是 layout：视口多半是 relayout boundary，行高
    // 变化的 markNeedsLayout 传不到这一层；而 markNeedsPaint 一定能传上来
    // （绘制传播只停在 RepaintBoundary，这一层之上才有）。此时布局已完成，
    // 量到的就是这一帧最终的样子，平移当帧生效。
    final double? shift = resolve();
    if (shift != null && !shift.isNaN) {
      _shift = shift;
    }
    if (_shift == 0 || child == null) {
      super.paint(context, offset);
      return;
    }
    final Matrix4 transform = Matrix4.translationValues(0, _shift, 0);
    context.pushTransform(needsCompositing, offset, transform, super.paint);
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    super.applyPaintTransform(child, transform);
    // 让 localToGlobal（测试取矩形、浮层定位）看得见这层平移。
    // 量补偿量的路径（_revealOffset / _layoutOffset）走的是布局几何，
    // 不经过这里，不会被自己的平移污染。
    if (_shift != 0) {
      transform.multiply(Matrix4.translationValues(0, _shift, 0));
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return super.hitTestChildren(
      result,
      position: position - Offset(0, _shift),
    );
  }
}

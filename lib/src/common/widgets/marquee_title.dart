import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../paint_cache.dart';

/// 单行标题：放不下时两端渐隐，鼠标悬停后缓慢向左滚，移开再缓慢归位。
///
/// 为什么不用 `TextOverflow.ellipsis`：省略号本身要占掉一个字的位置，长歌名
/// 被硬切之后用户永远看不到后半段；渐隐在静止时就能看出「还有内容」，想看全
/// 把鼠标放上去即可，不悬停时又完全不占额外空间。
///
/// 滚动是**首尾相接的循环**：内容画两份、中间留一段空白，位移对
/// 「一份文字 + 空白」取一圈，走到末尾时下一份的开头正好接上，看不到闪回。
class MarqueeTitle extends StatefulWidget {
  const MarqueeTitle({
    super.key,
    required this.text,
    required this.style,
    this.velocity = 34,
  });

  final String text;
  final TextStyle style;

  /// 滚动速度（逻辑像素 / 秒）。越慢越像「跟着读」，太快会晃眼
  final double velocity;

  /// 悬停后先停一下再滚，避免鼠标只是路过就动起来
  static const Duration _hoverDelay = Duration(milliseconds: 450);

  /// 归位速度（比滚动快一点，但仍然是「滑回去」而不是瞬移）
  static const double _rewindVelocity = 220;

  /// 右侧渐隐的宽度（逻辑像素）。
  ///
  /// 原来是「宽度的 7%」：宽标题里差不多，窄窗口里只有十几像素——最后一个字
  /// 几乎原样亮到边上再突然消失，看着就是被硬切、边上还浮着半块笔画。
  /// 改成固定厚度之后，大小窗口的渐隐看起来一样。
  static const double _rightFadeSpan = 30;

  /// 渐隐最多占多宽的比例：很窄的位置（比如最小窗口里的标题栏）不该整条都在淡
  static const double _rightFadeMaxRatio = 0.35;

  /// 左侧渐隐的最大宽度（占视口的比例）
  static const double _leftFadeSpan = 0.05;

  /// 左侧渐隐从无到满需要滚多少像素
  ///
  /// 静止时左边根本没有字被推出去，这时候还淡就等于把第一个字啃掉一半，
  /// 看着很怪；所以左淡跟着位移走：开始滚之后十几像素内渐入到满。
  static const double _leftFadeRamp = 14;

  /// 遮罩渐变：左端按 [leftFade] 淡出，右端固定宽度收尾。
  ///
  /// 右端收在**离边界还有 1 逻辑像素**处、且最后一截已经是全透明：
  /// 裁剪的抗锯齿会在边界外漏出不到一像素的笔画，而 `ShaderMask` 只管自己
  /// 边界以内的部分，漏出来的那一条原样画出去就是边上的亮线 / 半块笔画。
  ///
  /// 中间加两个色标（0.8 / 0.3）把收尾做成 S 形：直线渐变在「满 → 0」走完的
  /// 那一点上斜率突变，最后一个字会先保持全亮再突然消失，看着像被硬切。
  @visibleForTesting
  static LinearGradient fadeGradient({
    required double width,
    required double leftFade,
  }) {
    final double w = width <= 0 ? 1 : width;
    final double edge = math.max(0, w - 1);
    final double span = math.min(_rightFadeSpan, edge * _rightFadeMaxRatio);
    // 一律不早于左淡的终点，stops 才不会反序
    double at(double px) => (px / w).clamp(leftFade.clamp(0.0, 1.0), 1.0);
    final double start = at(edge - span);
    final double knee = at(edge - span * 0.6);
    final double tail = at(edge - span * 0.25);
    final double end = at(edge);
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: <Color>[
        // 左淡为 0 时用白色起步：两个 stop 重合、颜色又不同的话，
        // 会在最左边留一条 1px 的硬边
        leftFade > 0 ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
        const Color(0xFFFFFFFF),
        const Color(0xFFFFFFFF),
        const Color(0xCCFFFFFF),
        const Color(0x4DFFFFFF),
        const Color(0x00FFFFFF),
        const Color(0x00FFFFFF),
      ],
      stops: <double>[0, leftFade, start, knee, tail, end, 1],
    );
  }

  /// 推进一帧的左淡计算（纯函数，方便测试）。
  ///
  /// - 静止时返回 0，第一个字保持完整；
  /// - 往前滚动时按**累计路程**渐入到满，且跨圈不清零：衔接那一刻 `value`
  ///   会从 ~1 跳回 ~0，左边照样有字在出，遮罩不该跟着闪一下；
  /// - 往回滑（归位）时改按「还剩多少位移」收掉，滑到起点正好收干净。
  @visibleForTesting
  static ({double leftFade, double travelled, double lastValue}) stepLeftFade({
    required double value,
    required double lastValue,
    required double cycle,
    required double travelled,
  }) {
    double delta = value - lastValue;
    // 跨圈：value 从 ~1 掉回 ~0，实际是往前走了 (1 - last) + value
    if (delta < -0.5) {
      delta += 1;
    }
    if (delta > 0) {
      final double next = travelled + delta * cycle;
      return (
        leftFade: _leftFadeSpan * (next / _leftFadeRamp).clamp(0.0, 1.0),
        travelled: next,
        lastValue: value,
      );
    }
    return (
      leftFade: _leftFadeSpan * (value * cycle / _leftFadeRamp).clamp(0.0, 1.0),
      travelled: travelled,
      lastValue: value,
    );
  }

  @override
  State<MarqueeTitle> createState() => _MarqueeTitleState();
}

class _MarqueeTitleState extends State<MarqueeTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  /// 一段「文字 + 空白」的长度：滚这么远，内容正好首尾相接
  double _cycle = 0;

  bool _overflow = false;
  bool _hovering = false;

  /// 循环世代号：移开鼠标 / 换歌时自增，正在等的延迟看到它变了就退出
  int _token = 0;

  /// 本轮已经滚了多远（像素，跨圈累加）。
  ///
  /// 左侧渐隐靠它判断「左边是不是一直在出字」：循环衔接时 `value` 会从 1 跳回 0，
  /// 如果直接拿 `value × cycle` 算，左淡会跟着瞬间归零再长回来——看起来就是
  /// 「遮罩一闪」。这里只累加前进量，衔接处不抖。
  double _travelled = 0;

  /// 上一帧的 `value`，用来算这一次前进了多少
  double _lastValue = 0;

  /// Shader 缓存：避免每帧 `createShader` 造成内存泄漏
  ///
  /// Key 格式："width-leftFade"，例如 "300.0-0.03"。
  /// Shader 缓存，使用全局 GradientShaderCache
  final GradientShaderCache _shaderCache = GradientShaderCache(maxSize: 20);

  /// 离散化 leftFade 到最近的 0.005 倍数，减少缓存条目。
  ///
  /// _leftFadeSpan = 0.05，分 10 档：0 / 0.005 / 0.01 / ... / 0.05，
  /// 视觉上无感知（每档只差 0.5% 视口宽）。
  double _quantizeLeftFade(double leftFade) {
    return (leftFade * 200).round() / 200;
  }

  /// 获取或创建 Shader，优先命中缓存。
  ///
  /// 宽度按 0.5px 量化（窗口拖拽时不至于每个像素都新建一次），
  /// leftFade 已在外部量化。
  Shader _getShader(double width, double leftFade) {
    final double quantizedWidth = (width * 2).round() / 2;
    final Gradient gradient = MarqueeTitle.fadeGradient(
      width: quantizedWidth,
      leftFade: leftFade,
    );
    final Rect rect = Rect.fromLTWH(0, 0, quantizedWidth, 100);
    return _shaderCache.shader(gradient: gradient, rect: rect);
  }

  @override
  void didUpdateWidget(MarqueeTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) {
      return;
    }
    _token++;
    _hovering = false;
    _travelled = 0;
    _lastValue = 0;
    _cachedText = null;
    _cachedTextWidth = null;
    // 换歌时清理 Shader 缓存
    _shaderCache.clear();
    _controller
      ..stop()
      ..value = 0;
  }

  @override
  void dispose() {
    _token++;
    _controller.dispose();
    _shaderCache.clear();
    super.dispose();
  }

  /// 缓存的文字宽度，避免每帧重新测量
  double? _cachedTextWidth;
  String? _cachedText;

  /// 量一份文字有多宽。用与 `Text` 完全相同的 style / textScaler，
  /// 否则算出的循环长度和实际渲染差几个像素，接缝处会哆嗦一下
  double _measureText(BuildContext context) {
    // 缓存文字宽度，避免每帧重新创建 TextPainter
    if (_cachedText == widget.text && _cachedTextWidth != null) {
      return _cachedTextWidth!;
    }

    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: widget.text,
        style: DefaultTextStyle.of(context).style.merge(widget.style),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final double width = painter.width;
    painter.dispose();

    _cachedText = widget.text;
    _cachedTextWidth = width;
    return width;
  }

  Future<void> _onEnter() async {
    _hovering = true;
    if (!_overflow || _cycle <= 0) {
      return;
    }
    final int token = ++_token;
    await Future<void>.delayed(MarqueeTitle._hoverDelay);
    if (!mounted || token != _token || !_hovering) {
      return;
    }
    if (!_overflow || _cycle <= 0) {
      return;
    }
    // 从静止启动才需要「渐入」；归位没走完就重新悬停的话，左边本来就有字
    // 在动，保持满遮罩，别让它先淡出去再淡回来
    _travelled = _controller.value * _cycle > 1
        ? MarqueeTitle._leftFadeRamp
        : 0;
    _lastValue = _controller.value;
    // 归位动画可能正跑到一半：直接接管，从当前位置接着滚
    _controller.repeat();
  }

  void _onExit() {
    _hovering = false;
    _token++;
    if (!_controller.isAnimating) {
      return;
    }
    _controller.stop();
    // 回到**本轮**滚动的开头：不管悬停期间循环了多少圈，位移量始终是
    // `value × cycle`，最多退一圈，不会倒着转好几圈回到「最开始那次」。
    // 也不往前（向右快进）滑到下一圈起点——那样文字会突然加速冲过去。
    final double distance = _controller.value * _cycle;
    final Duration duration = Duration(
      milliseconds: (distance / MarqueeTitle._rewindVelocity * 1000)
          .round()
          .clamp(150, 600),
    );
    unawaited(
      _controller.animateTo(0, duration: duration, curve: Curves.easeOut),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double viewport = constraints.maxWidth;
        final double textWidth = _measureText(context);
        final bool overflow = textWidth > viewport + 0.5;
        // 空白按视口取比例：窄栏里不至于占掉半屏，宽栏里又能把两遍歌名分开，
        // 看得出这是一次循环、而不是把歌名重复了一遍
        final double gap = math.max(32, viewport * 0.12);
        final double cycle = textWidth + gap;
        _overflow = overflow;
        _cycle = overflow ? cycle : 0;
        if (overflow) {
          _controller.duration = Duration(
            milliseconds: (cycle / widget.velocity * 1000).round().clamp(
              800,
              60000,
            ),
          );
        } else if (_controller.isAnimating) {
          // 窗口变宽、文字不再超出：别把标题停在半路
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _overflow) {
              return;
            }
            _controller
              ..stop()
              ..value = 0;
          });
        }

        final Widget single = Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          softWrap: false,
        );

        return MouseRegion(
          onEnter: (_) => unawaited(_onEnter()),
          onExit: (_) => _onExit(),
          child: SizedBox(
            width: double.infinity,
            height: constraints.maxHeight,
            child: !overflow
                ? single
                : ClipRect(
                    child: AnimatedBuilder(
                      animation: _controller,
                      // 内容比视口宽得多，得让它不受约束地铺开：
                      // 直接放 Row 会报 RenderFlex overflow，这里用 OverflowBox
                      // 只放开宽度，自己仍然是视口大小（ShaderMask 按它取渐变）。
                      // 整份内容当 child 传进来，动画每帧只换位移，不重建文字。
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        maxWidth: double.infinity,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            single,
                            SizedBox(width: gap),
                            single,
                          ],
                        ),
                      ),
                      // 两份文字 + 中间空白：位移走完一段就回到 0，
                      // 那一刻第二份的开头正好落在第一份的起点，看不出接缝
                      builder: (BuildContext context, Widget? child) {
                        final double offset = _controller.value * cycle;
                        final ({
                          double leftFade,
                          double travelled,
                          double lastValue,
                        })
                        step = MarqueeTitle.stepLeftFade(
                          value: _controller.value,
                          lastValue: _lastValue,
                          cycle: cycle,
                          travelled: _travelled,
                        );
                        _travelled = step.travelled;
                        _lastValue = step.lastValue;
                        final double leftFade = _quantizeLeftFade(
                          step.leftFade,
                        );
                        return ShaderMask(
                          shaderCallback: (Rect bounds) =>
                              _getShader(bounds.width, leftFade),
                          blendMode: BlendMode.dstIn,
                          child: Transform.translate(
                            offset: Offset(-offset, 0),
                            child: child,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        );
      },
    );
  }
}

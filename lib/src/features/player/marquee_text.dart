import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 单行「跑马灯」文字：放不下时循环滚动，两端渐隐。
///
/// 三个明确的行为约定（和「自己会动的横幅」区分开）：
///
/// * **静止就是静止**——只有鼠标停在这行字上才开始滚，移开就停。歌名一直在
///   动的话，余光永远被它拽着，很吵；
/// * **停下后回到第一个循环的起点**——也就是歌名的第一个字，而不是停在半途；
/// * **放得下就完全退化**——量出来一行装得完时返回普通 [Text]：不建图层、
///   不吃鼠标事件，也没有任何渐隐（把首字削掉一半会很奇怪）。
///
/// 循环是无缝的：并排铺两份同样的文字，走过「一份 + 间隔」后正好接上第二份，
/// 动画 value 归零那一帧画面上是同一个东西，看不出接缝。
///
/// 渐隐只做在**内容会被切掉的那一侧**：右端始终渐隐（句子还没完），左端
/// 随滚动距离从 0 涨到 [fadeWidth]——静止时左端是歌名的第一个字，不能动它。
class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.speed = 34,
    this.fadeWidth = 22,
  });

  final String text;

  /// 与 [Text.style] 同义；量宽度用的也是它（连同环境里的 textScaler）
  final TextStyle? style;

  /// 滚动速度（逻辑像素 / 秒），随字号缩放
  final double speed;

  /// 两端渐隐带的宽度
  final double fadeWidth;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  /// 一次循环要走过的距离（一份文字 + 间隔）。时长按它和速度算
  double _cycle = 0;

  /// 鼠标是否停在这行字上
  bool _hovering = false;

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) {
      return;
    }
    // 换歌：回到第一个字；鼠标还压在上面就接着滚新的歌名
    _controller.stop();
    _controller.value = 0;
    if (_hovering) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    _hovering = true;
    if (_cycle <= 0) {
      return;
    }
    // repeat() 从当前位置接着走：鼠标挪开一点点又回来，不会跳回开头
    _controller.repeat();
  }

  void _stop() {
    _hovering = false;
    if (!_controller.isAnimating) {
      return;
    }
    // 倒回起点。时长按当前进度折算，否则离得近的时候会突然变快
    _controller.animateBack(
      0,
      duration: Duration(milliseconds: (240 * _controller.value).round() + 120),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = DefaultTextStyle.of(context).style
        .merge(widget.style);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextPainter painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    // 量完就把段落还回去：TextPainter 持有的是 native 的 Paragraph，
    // 靠 GC 收是「迟早」，一首首换歌时会一直攒着
    final double textWidth = painter.width;
    final double textHeight = painter.height;
    painter.dispose();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        if (!available.isFinite || textWidth <= available) {
          // 装得下：把控制器归零，别让上一次的滚动带进新歌名
          _cycle = 0;
          if (_controller.value != 0) {
            _controller.value = 0;
          }
          return Text(widget.text, maxLines: 1, style: style);
        }

        final double textScale = scaler.scale(1);
        // 两份之间的空：约一个字高。太挤会被看成「歌名重复了一遍」
        final double gap = math.max(24, textHeight * 1.2);
        final double cycle = textWidth + gap;
        _cycle = cycle;
        _controller.duration = Duration(
          milliseconds: (cycle / (widget.speed * textScale) * 1000).round(),
        );

        final Widget line = Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(widget.text, maxLines: 1, softWrap: false, style: style),
            SizedBox(width: gap),
            Text(widget.text, maxLines: 1, softWrap: false, style: style),
          ],
        );

        return MouseRegion(
          // 只是「悬停才滚」，不进入可点状态，所以不给手型
          onEnter: (PointerEnterEvent _) => _start(),
          onExit: (PointerExitEvent _) => _stop(),
          child: Semantics(
            // 两份文字只是视觉上的接续，读屏读一遍就够
            label: widget.text,
            excludeSemantics: true,
            // 这里**不加** RepaintBoundary：实测加上反而每帧多花 ~9µs
            // （多合成一层 342×24 的缓存，比直接重绘这点面积还贵），而且多留
            // 一张纹理；频谱和歌词各自已经有绘制边界，不会被这边牵连
            child: ClipRect(
              child: SizedBox(
                width: available,
                height: textHeight,
                child: AnimatedBuilder(
                  animation: _controller,
                  child: line,
                  builder: (BuildContext context, Widget? child) {
                    final double shift = _controller.value * cycle;
                    return ShaderMask(
                      blendMode: BlendMode.dstIn,
                      // 只有这一行文字铺离屏图层（约一行高），不是整页
                      shaderCallback: (Rect rect) => _fadeShader(
                        rect,
                        // 滚出去多少，左端就渐隐多少：静止时首字不挨刀
                        left: math.min(widget.fadeWidth * textScale, shift),
                        fade: widget.fadeWidth * textScale,
                      ),
                      child: Transform.translate(
                        offset: Offset(-shift, 0),
                        // 两份文字加起来总比可视宽度长：让它按自然宽度铺开、
                        // 由外面的 ClipRect 裁，别在 Row 里报溢出
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          maxWidth: double.infinity,
                          maxHeight: double.infinity,
                          child: child,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 上一张遮罩。左端渐隐走满 22px 之后就固定不变了，滚动剩下的时间每帧
  /// 都是同一张——不缓存的话每帧都要新建一个 native `Shader`（还有两份
  /// `List`），一秒 60 个，全靠 GC 收
  Shader? _maskShader;
  double _maskWidth = -1;
  double _maskLeftStop = -1;
  double _maskRightStop = -1;

  /// 两端渐隐的遮罩：中间全不透明，两侧线性透明到 0
  Shader _fadeShader(Rect rect, {required double left, required double fade}) {
    const Color opaque = Color(0xFF000000);
    const Color clear = Color(0x00000000);
    final double width = math.max(1, rect.width);
    // 文字被缩放得很宽时两条渐隐带可能撞在一起，夹一下保证 stop 单调
    final double leftStop = (left / width).clamp(0.0, 0.45);
    final double rightStop = (1 - fade / width).clamp(0.55, 1.0);

    final Shader? cached = _maskShader;
    if (cached != null &&
        _maskWidth == width &&
        _maskLeftStop == leftStop &&
        _maskRightStop == rightStop) {
      return cached;
    }

    final List<Color> colors = <Color>[];
    final List<double> stops = <double>[];
    if (leftStop > 0.001) {
      colors.add(clear);
      stops.add(0);
      colors.add(opaque);
      stops.add(leftStop);
    } else {
      colors.add(opaque);
      stops.add(0);
    }
    colors.add(opaque);
    stops.add(rightStop);
    colors.add(clear);
    stops.add(1);

    _maskWidth = width;
    _maskLeftStop = leftStop;
    _maskRightStop = rightStop;
    return _maskShader = LinearGradient(
      colors: colors,
      stops: stops,
    ).createShader(rect);
  }
}

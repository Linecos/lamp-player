import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../common/audio/audio_quality.dart';

/// 音质分布的环形饼图。
///
/// 四档各占一段圆弧，扇区可点（回调 [onSelect]），中间的读数跟着悬停 / 选中
/// 换：没选中时是总首数，选中后是那一档的首数与占比。
///
/// 颜色是同一个强调色的四阶（见 [sliceColor]）：从 HR 到「其他」逐级向背景
/// 过渡，浅色主题下越往后越浅、深色主题下越往后越暗。
class QualityRing extends StatefulWidget {
  const QualityRing({
    super.key,
    required this.breakdown,
    this.selected,
    this.onSelect,
    this.size = 152,
  });

  final QualityBreakdown breakdown;

  /// 当前筛选用的档位；null 表示不筛选
  final AudioQuality? selected;

  /// 点击某个扇区；再点同一档由调用方决定是取消还是保持
  final ValueChanged<AudioQuality>? onSelect;

  final double size;

  @override
  State<QualityRing> createState() => _QualityRingState();
}

class _QualityRingState extends State<QualityRing>
    with SingleTickerProviderStateMixin {
  /// 鼠标悬停的档位：只影响这一帧的高亮与中心读数
  AudioQuality? _hovered;

  /// 拖动转过的角度（度，顺时针为正）；命中与绘制都带上它
  double _rotation = 0;

  /// 松手后的角速度（度/秒），用来做惯性
  double _velocity = 0;

  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  Duration? _lastPanAt;

  /// 上一次指针相对圆心的角度（度，12 点为 0、顺时针）
  double _lastAngle = 0;

  /// 是否「抓住圆盘」：按在环上就跟着指针转，按在中心洞里退化成横向拖动
  bool _angularDrag = false;

  static const double _innerRatio = 0.62;
  static const double _gapDegrees = 1.6;

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  Offset get _center => Offset(widget.size / 2, widget.size / 2);

  /// 指针相对圆心的角度（度，12 点方向为 0、顺时针）；[-180, 180)
  double _angleOf(Offset local) {
    final Offset p = local - _center;
    return math.atan2(p.dy, p.dx) * 180 / math.pi + 90;
  }

  /// 从中心洞按下时的灵敏度：横向拖两个直径转一圈
  double get _degreesPerPixel => 720 / widget.size;

  void _onPanStart(DragStartDetails details) {
    _stopSpin();
    _lastPanAt = null;
    _lastTick = Duration.zero;
    _lastAngle = _angleOf(details.localPosition);
    // 离圆心太近时角度会剧烈跳动，那种位置按横向位移转更稳
    _angularDrag =
        (details.localPosition - _center).distance >=
        widget.size / 2 * _innerRatio * 0.85;
    // 按下后指针就不再发悬停事件，先清掉高亮，否则转起来一直亮着旧的那档
    if (_hovered != null) {
      setState(() => _hovered = null);
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    double degrees;
    if (_angularDrag) {
      // 抓着环转：拖到哪转到哪，指针绕一圈环就转一圈
      final double angle = _angleOf(details.localPosition);
      degrees = angle - _lastAngle;
      // 跨越 ±180° 时差值是假的，折回最近的一侧
      if (degrees > 180) {
        degrees -= 360;
      } else if (degrees < -180) {
        degrees += 360;
      }
      _lastAngle = angle;
    } else {
      degrees = details.delta.dx * _degreesPerPixel;
    }
    final Duration? last = _lastPanAt;
    final Duration? now = details.sourceTimeStamp;
    if (last != null && now != null) {
      final double dt = (now - last).inMicroseconds / 1000000;
      // 只留最后一段速度：拖得快就甩得远，慢慢挪松手就停
      if (dt > 0.001) {
        _velocity = degrees / dt;
      }
    }
    _lastPanAt = now;
    setState(() => _rotation = (_rotation + degrees) % 360);
  }

  void _onPanEnd(DragEndDetails details) {
    _lastPanAt = null;
    if (_velocity.abs() < 30) {
      return;
    }
    if (_velocity.abs() > 1200) {
      _velocity = _velocity.sign * 1200.0;
    }
    _lastTick = Duration.zero;
    _ticker ??= createTicker(_tick);
    _ticker!.start();
  }

  void _stopSpin() {
    _ticker?.stop();
    _velocity = 0;
    _lastTick = Duration.zero;
  }

  void _tick(Duration elapsed) {
    final double dt = (elapsed - _lastTick).inMicroseconds / 1000000;
    _lastTick = elapsed;
    if (dt <= 0) {
      return;
    }
    // 每 0.35 秒减半，够滑一段又不至于转个不停
    _velocity *= math.pow(0.5, dt / 0.35).toDouble();
    if (_velocity.abs() < 24) {
      _stopSpin();
      return;
    }
    setState(() => _rotation = (_rotation + _velocity * dt) % 360);
  }

  /// 每档的起始角（度，0 在 12 点方向、顺时针）；0 首的档不占角度
  List<_Slice> _slices() {
    final List<_Slice> slices = <_Slice>[];
    double start = 0;
    for (final AudioQuality quality in AudioQuality.values) {
      final int count = widget.breakdown.countOf(quality);
      if (count == 0) {
        continue;
      }
      final double sweep = 360.0 * count / widget.breakdown.total;
      slices.add(_Slice(quality: quality, start: start, sweep: sweep));
      start += sweep;
    }
    return slices;
  }

  AudioQuality? _hitTest(Offset local, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double dx = local.dx - center.dx;
    final double dy = local.dy - center.dy;
    final double radius = math.sqrt(dx * dx + dy * dy);
    final double outer = size.width / 2;
    final double inner = outer * _innerRatio;
    // 环带外留一点宽容：鼠标贴着环点，别因为差两像素就没反应
    if (radius < inner - 6 || radius > outer + 4) {
      return null;
    }
    // 指针角度要减掉环自己转过的角度，才能对上扇区的起始角
    final double degrees =
        (math.atan2(dy, dx) * 180 / math.pi + 90 - _rotation) % 360;
    for (final _Slice slice in _slices()) {
      if (degrees >= slice.start && degrees < slice.start + slice.sweep) {
        return slice.quality;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<_Slice> slices = _slices();
    final AudioQuality? active = _hovered ?? widget.selected;
    final double size = widget.size;

    final Widget center = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          active == null
              ? '${widget.breakdown.total}'
              : '${widget.breakdown.countOf(active)}',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: active == null
                ? scheme.onSurface
                : sliceColor(scheme, active),
          ),
        ),
        Text(
          active == null
              ? '首'
              : '${(widget.breakdown.fractionOf(active) * 100).toStringAsFixed(1)}%',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    return MouseRegion(
      cursor: widget.onSelect == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onHover: (PointerHoverEvent event) {
        final AudioQuality? hit = _hitTest(
          event.localPosition,
          Size(size, size),
        );
        if (hit != _hovered) {
          setState(() => _hovered = hit);
        }
      },
      onExit: (_) {
        if (_hovered != null) {
          setState(() => _hovered = null);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 拖动转环：松手后带一点惯性，慢慢挪就原地停
        onPanStart: widget.breakdown.total == 0 ? null : _onPanStart,
        onPanUpdate: widget.breakdown.total == 0 ? null : _onPanUpdate,
        onPanEnd: widget.breakdown.total == 0 ? null : _onPanEnd,
        onTapUp: widget.onSelect == null
            ? null
            : (TapUpDetails details) {
                final AudioQuality? hit = _hitTest(
                  details.localPosition,
                  Size(size, size),
                );
                if (hit != null) {
                  widget.onSelect!(hit);
                }
              },
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              CustomPaint(
                size: Size(size, size),
                painter: _RingPainter(
                  slices: slices,
                  rotation: _rotation,
                  innerRatio: _innerRatio,
                  gapDegrees: _gapDegrees,
                  selected: widget.selected,
                  hovered: _hovered,
                  scheme: scheme,
                  total: widget.breakdown.total,
                ),
              ),
              center,
            ],
          ),
        ),
      ),
    );
  }
}

/// 一档在环上占的一段
class _Slice {
  const _Slice({
    required this.quality,
    required this.start,
    required this.sweep,
  });

  final AudioQuality quality;

  /// 起始角（度，0 = 12 点，顺时针）
  final double start;

  /// 扫过角度（度）
  final double sweep;
}

/// 档位配色：同一个强调色的四阶，靠向背景过渡出「深 → 浅」。
///
/// 取 `scheme.primary` 为最深的一阶（HR），依次混入 `scheme.surface`：
/// 浅色主题下越往后越浅，深色主题下越往后越暗——两种主题都保持「与背景
/// 对比度递减」的同一套阶梯，不出现刺眼的浅档。
Color sliceColor(ColorScheme scheme, AudioQuality quality) {
  final double mix = switch (quality) {
    AudioQuality.hiRes => 0,
    AudioQuality.standard => 0.22,
    AudioQuality.high => 0.42,
    AudioQuality.other => 0.6,
  };
  if (mix == 0) {
    return scheme.primary;
  }
  return Color.lerp(scheme.primary, scheme.surface, mix)!;
}

/// 档位的显示名与中文说明
String qualityLabel(AudioQuality quality) => switch (quality) {
  AudioQuality.hiRes => 'HR',
  AudioQuality.standard => 'SQ',
  AudioQuality.high => 'HQ',
  AudioQuality.other => '其他',
};

String qualityCaption(AudioQuality quality) => switch (quality) {
  AudioQuality.hiRes => 'Hi-Res 高解析',
  AudioQuality.standard => '无损标准音质',
  AudioQuality.high => '有损高码率',
  AudioQuality.other => '低码率或未知',
};

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.slices,
    required this.rotation,
    required this.innerRatio,
    required this.gapDegrees,
    required this.selected,
    required this.hovered,
    required this.scheme,
    required this.total,
  });

  final List<_Slice> slices;

  /// 环整体转过的角度（度，顺时针为正）
  final double rotation;
  final double innerRatio;
  final double gapDegrees;
  final AudioQuality? selected;
  final AudioQuality? hovered;
  final ColorScheme scheme;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = size.width / 2;
    final double inner = radius * innerRatio;
    final double stroke = radius - inner;
    final double ringRadius = (radius + inner) / 2;

    // 空库画一个中性色的整环，至少有个「形状」在
    if (slices.isEmpty || total == 0) {
      canvas.drawCircle(
        center,
        ringRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = scheme.surfaceContainerHighest,
      );
      return;
    }

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    for (final _Slice slice in slices) {
      // 只有一段时不留缝，否则圆环看起来缺了口
      final bool solitary = slices.length == 1;
      final double gap = solitary ? 0 : gapDegrees;
      final double sweep = math.max(0, slice.sweep - gap);
      final bool lit = hovered != null
          ? hovered == slice.quality
          : selected != null
          ? selected == slice.quality
          : false;
      final bool dimmed = (hovered != null || selected != null) && !lit;

      paint.color = sliceColor(
        scheme,
        slice.quality,
      ).withValues(alpha: dimmed ? 0.42 : 1);
      // 高亮的那段略微加粗，指向感比只换透明度明确
      final double width = lit ? stroke + 6 : stroke;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        _startRadians(slice.start + rotation + gap / 2),
        _sweepRadians(sweep),
        false,
        paint..strokeWidth = width,
      );
    }

    // 每档的分隔刻度：细线落在缝里，深色下也不会糊成一圈
    // 颜色取面板底色（环形图所在的卡片就是 surfaceContainerHigh）
    if (slices.length > 1) {
      final Paint tick = Paint()
        ..color = scheme.surfaceContainerHigh.withValues(alpha: 0.9);
      for (final _Slice slice in slices) {
        final double angle = _startRadians(slice.start + rotation);
        final Offset from =
            center + Offset(math.cos(angle), math.sin(angle)) * inner;
        final Offset to =
            center + Offset(math.cos(angle), math.sin(angle)) * radius;
        canvas.drawLine(from, to, tick..strokeWidth = 2);
      }
    }
  }

  /// 角度换算：0° 在 12 点方向，顺时针为正
  ///
  /// 只用于**起始角**与刻度线；扫过的角度是纯角度差，不能再减 90°，
  /// 否则每段弧都会短 90°（曾经的 bug：四档只剩半圈）。
  double _startRadians(double degrees) => (degrees - 90) * math.pi / 180;

  double _sweepRadians(double degrees) => degrees * math.pi / 180;

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.slices.length != slices.length ||
      oldDelegate.total != total ||
      oldDelegate.selected != selected ||
      oldDelegate.hovered != hovered ||
      oldDelegate.scheme != scheme ||
      !_sameSlices(oldDelegate.slices, slices);

  bool _sameSlices(List<_Slice> a, List<_Slice> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i += 1) {
      if (a[i].quality != b[i].quality || a[i].sweep != b[i].sweep) {
        return false;
      }
    }
    return true;
  }
}

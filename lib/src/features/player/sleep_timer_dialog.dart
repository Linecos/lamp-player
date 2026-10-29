import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 睡眠定时浮窗：一个时钟轮盘，0~60 分钟、步长 1 分钟。
///
/// 返回值：`minutes` 为分钟数（0 = 关闭定时），`extendToTrackEnd` 表示到点时
/// 若当前曲目还没播完是否顺延到播完；`null` 表示用户取消，不改动现有定时。
///
/// 轮盘把 0~60 映射到整圈：
/// 12 点位置是 0（关闭），顺时针走到 60 后又回到 0——所以想要整整一小时
/// 时用下面的快选，别在接缝上抠。
Future<SleepTimerResult?> showSleepTimerDialog(
  BuildContext context, {
  int initialMinutes = 30,
  bool hasTimer = false,
  bool extendToTrackEnd = true,
}) {
  return showDialog<SleepTimerResult>(
    context: context,
    builder: (BuildContext dialogContext) => _SleepTimerDialog(
      initialMinutes: initialMinutes,
      hasTimer: hasTimer,
      extendToTrackEnd: extendToTrackEnd,
    ),
  );
}

/// 睡眠定时的选择结果
typedef SleepTimerResult = ({int minutes, bool extendToTrackEnd});

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog({
    required this.initialMinutes,
    required this.hasTimer,
    required this.extendToTrackEnd,
  });

  final int initialMinutes;
  final bool hasTimer;
  final bool extendToTrackEnd;

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  late int _minutes = widget.initialMinutes.clamp(0, 60);
  late bool _extend = widget.extendToTrackEnd;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool off = _minutes == 0;

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 与播放队列、输出设备弹窗一致：标题右边留一个关闭叉号，
              // 不用先找到底部的「取消」
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '睡眠定时',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          off
                              ? '不定时，到点不会自动暂停'
                              : (widget.hasTimer
                                    ? '当前还剩 $_minutes 分钟，到点自动暂停'
                                    : '到点自动暂停，醒来点一下继续'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey<String>('sleep-close'),
                    tooltip: '关闭',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: _MinuteDial(
                  minutes: _minutes,
                  onChanged: (int value) => setState(() => _minutes = value),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: <Widget>[
                  for (final int preset in const <int>[15, 30, 45, 60])
                    ChoiceChip(
                      key: ValueKey<String>('sleep-preset-$preset'),
                      label: Text('$preset 分'),
                      selected: _minutes == preset,
                      showCheckmark: false,
                      // 紧凑一点：4 个芯片要在同一行里排下
                      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: _minutes == preset
                          ? null
                          : (bool _) => setState(() => _minutes = preset),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const ValueKey<String>('sleep-extend-switch'),
                value: _extend,
                // 不定时的时候这个开关没有意义
                onChanged: off
                    ? null
                    : (bool value) => setState(() => _extend = value),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('听完当前曲目再暂停'),
                subtitle: const Text('到点时本曲没播完就顺延到播完'),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  // 已在倒计时才给「关闭定时」：不然取消要先把轮盘拖回 0，太难发现
                  if (widget.hasTimer)
                    TextButton(
                      key: const ValueKey<String>('sleep-clear'),
                      onPressed: () =>
                          Navigator.of(context)
                              .pop((minutes: 0, extendToTrackEnd: _extend)),
                      child: const Text('关闭定时'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('sleep-confirm'),
                    onPressed: () => Navigator.of(context)
                        .pop((minutes: _minutes, extendToTrackEnd: _extend)),
                    child: Text(off ? '关闭定时' : '开始'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 时钟轮盘：拖动指针环，0 在 12 点位置，顺时针增加。
///
/// 60 个刻度靠拖动 1 分钟 1 分钟地抠太累，所以下面还给了快选芯片；
/// 这里只管连续拖动的手感与读数。
class _MinuteDial extends StatefulWidget {
  const _MinuteDial({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  State<_MinuteDial> createState() => _MinuteDialState();
}

class _MinuteDialState extends State<_MinuteDial> {
  static const double _size = 236;
  static const double _radius = 96;

  void _handle(Offset local) {
    final Offset center = const Offset(_size / 2, _size / 2);
    final Offset v = local - center;
    if (v.distance < 16) {
      // 太靠圆心时角度不稳定，忽略
      return;
    }
    // atan2 以 3 点方向为 0；+90° 把起点挪到 12 点，再归一化到 [0, 2π)
    double angle = math.atan2(v.dy, v.dx) + math.pi / 2;
    if (angle < 0) {
      angle += 2 * math.pi;
    }
    final int value = (angle / (2 * math.pi) * 60).round().clamp(0, 60);
    if (value != widget.minutes) {
      widget.onChanged(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      key: const ValueKey<String>('sleep-dial'),
      width: _size,
      height: _size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (TapDownDetails d) => _handle(d.localPosition),
        onPanStart: (DragStartDetails d) => _handle(d.localPosition),
        onPanUpdate: (DragUpdateDetails d) => _handle(d.localPosition),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            CustomPaint(
              size: const Size(_size, _size),
              painter: _DialPainter(
                minutes: widget.minutes,
                radius: _radius,
                ringColor: scheme.surfaceContainerHighest,
                activeColor: scheme.primary,
                tickColor: scheme.outlineVariant,
                thumbColor: scheme.primary,
                thumbCoreColor: scheme.onPrimary,
              ),
            ),
            // 中心读数
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '${widget.minutes}',
                  key: const ValueKey<String>('sleep-dial-value'),
                  style:
                      (Theme.of(context).textTheme.displaySmall ??
                              const TextStyle())
                          .copyWith(
                            color: widget.minutes == 0
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                ),
                Text(
                  widget.minutes == 0
                      ? '不定时'
                      : (widget.minutes == 60 ? '分钟（1 小时）' : '分钟'),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.minutes,
    required this.radius,
    required this.ringColor,
    required this.activeColor,
    required this.tickColor,
    required this.thumbColor,
    required this.thumbCoreColor,
  });

  final int minutes;
  final double radius;
  final Color ringColor;
  final Color activeColor;
  final Color tickColor;
  final Color thumbColor;
  final Color thumbCoreColor;

  /// 12 点方向起算、顺时针的角度（弧度）
  static double _angleOf(int minute) =>
      -math.pi / 2 + minute / 60 * 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final Rect ring = Rect.fromCircle(center: center, radius: radius);

    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = ringColor;
    canvas.drawCircle(center, radius, track);

    if (minutes > 0) {
      final Paint active = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..color = activeColor;
      canvas.drawArc(
        ring,
        -math.pi / 2,
        minutes / 60 * 2 * math.pi,
        false,
        active,
      );
    }

    // 每 5 分钟一个刻度，整点（15/30/45/60）长一些
    final Paint tick = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = tickColor;
    for (int minute = 0; minute <= 60; minute += 5) {
      final double angle = _angleOf(minute);
      final bool major = minute % 15 == 0;
      final double inner = radius - (major ? 26 : 20);
      final double outer = radius - 14;
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * inner,
        center + Offset(math.cos(angle), math.sin(angle)) * outer,
        tick,
      );
    }

    // 指针
    final Offset knob =
        center +
        Offset(math.cos(_angleOf(minutes)), math.sin(_angleOf(minutes))) *
            radius;
    canvas.drawCircle(knob, 13, Paint()..color = thumbColor);
    canvas.drawCircle(knob, 5, Paint()..color = thumbCoreColor);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.minutes != minutes ||
      old.radius != radius ||
      old.activeColor != activeColor ||
      old.ringColor != ringColor ||
      old.tickColor != tickColor ||
      old.thumbColor != thumbColor ||
      old.thumbCoreColor != thumbCoreColor;
}

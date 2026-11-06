import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../common/ui_clock.dart';
import '../../common/widgets/cover_shape.dart';

/// 圆形封面的旋转相位（0~1 圈）。
///
/// 播放页的大封面、播放条的小封面、Hero 飞行用的 shuttle 共用这一份角度，
/// 所以进出播放页时封面是**接着转**的：退场不会先回正再飞，落地也不会
/// 突然跳一下。以前角度是播放页私有的，退场第一帧 shuttle 拿的是没旋转的
/// 封面，看上去就是「先回到最开始的样子再退出」。
///
/// 只有「圆形封面 + 正在播放」才转；暂停停在当前角度，再播接着转。
/// 用 [UiClock.fast]（60fps）推进，不跟显示器刷新率走。
class CoverSpin {
  CoverSpin._();

  /// 一圈的时长
  static const Duration period = Duration(seconds: 25);

  /// 当前角度（0~1 圈），所有展示封面的地方都看它
  static final ValueNotifier<double> turns = ValueNotifier<double>(0);

  /// 谁在要求"转"：播放页、播放条各算一个来源。
  ///
  /// 用来源表而不是布尔值，是因为两边生命周期不同——播放页退出时会销毁，
  /// 那不代表播放条也不用转了。全部来源都撤掉才停时钟。
  static final Map<Object, bool> _owners = <Object, bool>{};

  static bool _ticking = false;

  /// 暂停前累计的秒数 / 本次开始转的时刻（[UiClock] 秒）
  static double _elapsed = 0;
  static double _startedAt = 0;

  /// 某个来源上报自己的状态：圆形封面且正在播放才算"要转"。
  ///
  /// 幂等，可以在每次状态变化时直接调用。
  static void sync(
    Object owner, {
    required bool playing,
    required bool circular,
  }) {
    _owners[owner] = playing && circular;
    _retune();
  }

  /// 来源销毁：撤掉它那一票，别把别人的时钟也带走。
  static void release(Object owner) {
    if (_owners.remove(owner) != null) {
      _retune();
    }
  }

  /// 关掉圆形封面时回正，下次打开从正面开始
  static void resetAngle() {
    _stop();
    _elapsed = 0;
    if (turns.value != 0) {
      turns.value = 0;
    }
  }

  /// 测试隔离：清掉全局相位与时钟监听
  @visibleForTesting
  static void reset() {
    _stop();
    _owners.clear();
    _elapsed = 0;
    if (turns.value != 0) {
      turns.value = 0;
    }
  }

  static void _retune() {
    final bool wanted = _owners.values.any((bool value) => value);
    if (!wanted) {
      _stop();
      return;
    }
    if (!_ticking) {
      _ticking = true;
      _startedAt = UiClock.fast.seconds;
      UiClock.fast.addListener(_tick);
    }
  }

  /// 诊断用：是否正以 60fps 推进相位（`LAMP_MEM_LOG` 会打出来）
  static bool get debugTicking => _ticking;

  /// 诊断用：登记的来源数 / 其中要求转的数量
  static String get debugOwners {
    final int wanted = _owners.values.where((bool value) => value).length;
    return '${_owners.length}（要转 $wanted）';
  }

  static void _tick() {
    final double seconds = _elapsed + UiClock.fast.seconds - _startedAt;
    turns.value = (seconds / (period.inMilliseconds / 1000)) % 1;
  }

  static void _stop() {
    if (!_ticking) {
      return;
    }
    _elapsed += UiClock.fast.seconds - _startedAt;
    _ticking = false;
    UiClock.fast.removeListener(_tick);
  }
}

/// 按全局相位旋转封面；方形封面直接返回原样，不多套一层变换。
///
/// 播放条用它，让 56px 的小封面跟大封面共用同一个角度——否则 Hero 落地
/// 那一帧会从"转着的角度"突然跳回正面。
class SpinningCover extends StatefulWidget {
  const SpinningCover({super.key, required this.playing, required this.child});

  final bool playing;
  final Widget child;

  @override
  State<SpinningCover> createState() => _SpinningCoverState();
}

class _SpinningCoverState extends State<SpinningCover> {
  @override
  void initState() {
    super.initState();
    circularCovers.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(SpinningCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      _sync();
    }
  }

  @override
  void dispose() {
    circularCovers.removeListener(_sync);
    CoverSpin.release(this);
    super.dispose();
  }

  void _sync() {
    CoverSpin.sync(
      this,
      playing: widget.playing,
      circular: circularCovers.value,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: circularCovers,
      builder: (BuildContext context, bool circular, Widget? _) {
        if (!circular) {
          return widget.child;
        }
        return ValueListenableBuilder<double>(
          valueListenable: CoverSpin.turns,
          // 旋转用「Transform 在上、边界在下」：只换矩阵、复用下面的光栅
          builder: (BuildContext context, double turns, Widget? child) =>
              Transform.rotate(
                key: const ValueKey<String>('spinning-cover'),
                angle: turns * math.pi * 2,
                child: child,
              ),
          child: RepaintBoundary(child: widget.child),
        );
      },
    );
  }
}

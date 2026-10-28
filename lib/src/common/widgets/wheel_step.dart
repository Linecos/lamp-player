import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 把鼠标滚轮翻译成「一格」步进。
///
/// Flutter 的 Slider 本身不处理滚轮，桌面上只能拖着调。这里只负责认方向
/// （向上 = +1，向下 = -1），夹紧、合并、提交都由调用方决定——音量要 10%
/// 一格，均衡器要 1 dB 一格，步长不该写死在这里。
///
/// 滚轮走 `PointerSignalResolver` 抢占：页面自己也有 `Scrollable`，两边都直接
/// 处理的话会「一边调推子一边滚页面」。resolver 里最先登记的赢，而命中路径是
/// 由内向外分发的——推子在里面，所以滚动落在推子上时页面就不会跟着动。
class WheelStep extends StatelessWidget {
  const WheelStep({
    super.key,
    required this.onStep,
    required this.child,
    this.behavior = HitTestBehavior.deferToChild,
  });

  /// 参数为方向：`1` 向上滚（变大），`-1` 向下滚（变小）
  final ValueChanged<int> onStep;

  final Widget child;

  /// 命中方式：铺一层透明感应区时用 [HitTestBehavior.translucent]，
  /// 这样下层的 Slider 依旧能接住拖拽
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: behavior,
      onPointerSignal: (PointerSignalEvent event) {
        if (event is! PointerScrollEvent) {
          return;
        }
        final double delta = event.scrollDelta.dy;
        if (delta == 0) {
          return;
        }
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          (PointerSignalEvent _) => onStep(delta < 0 ? 1 : -1),
        );
      },
      child: child,
    );
  }
}

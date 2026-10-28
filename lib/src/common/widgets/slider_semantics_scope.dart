import 'package:flutter/widgets.dart';

/// 让 [Slider] 成为独立的语义边界，规避 Flutter 3.47 的 Windows 无障碍缺陷。
///
/// 背景：`Slider` 的取值气泡用 `OverlayPortal` 实现，气泡的语义节点是「遍历子
/// 节点」（`traversalChildIdentifier`），它的遍历父节点由 `OverlayPortal` 锚点上
/// 的 `Semantics(traversalParentIdentifier: ...)` 决定。锚点本身不是语义边界，
/// 这个 id 会被并进最近的祖先语义节点（在本应用里是整个页面节点），于是气泡节点
/// 被跨分支嫁接。Windows 的 `ui::AXTree` 不接受这种结构，会拒绝整次语义更新
/// （日志里的 `Failed to update ui::AXTree, error: ...` / `Nodes left pending by
/// the update: ...`），之后无障碍树永久冻结；再遇到一次路由 pop，引擎就会在
/// `accessibility_bridge.cc` 的 `CreateRemoveReparentedNodesUpdate` 里空指针崩溃
/// （表现为窗口「卡死」后退出）。
///
/// 加一层 `Semantics(container: true)` 后，锚点的遍历父节点固定为这层容器节点，
/// 不再随页面结构变化而失效，嫁接关系也被限制在 Slider 自己的子树里。
///
/// 上游：flutter/flutter#190357（框架侧已修，尚未进入 release），
/// 崩溃侧：flutter/flutter#175041。升级到带修复的 Flutter 后可以删掉这层包装。
class SliderSemanticsScope extends StatelessWidget {
  const SliderSemanticsScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(container: true, child: child);
  }
}

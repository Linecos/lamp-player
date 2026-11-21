import 'package:flutter/material.dart';

/// 分区里的「列表 ↔ 子页面」切换：淡入 + 轻微上滑。
///
/// 与 `AnimatedSwitcher` 的过渡完全一致（每个页面一个控制器，
/// `CurvedAnimation(curve: switchInCurve, reverseCurve: switchOutCurve)`，
/// 淡入淡出 + 1.5% 上浮），差别只在两点：
///
/// - **不靠 key 分代**：分区切走再切回来时，如果靠换 key 让切换器重建，
///   它就会以「当前页面」为初始状态；等到用户点开某一档，那次重建正好是第一
///   次构建，新旧页面同时进树的过渡就没了（表现为「切回来第一次点击没有动画」）。
///   这里让切换器跨分区切换保留状态，只有 [jumpToken] 变了才无过渡地直接换页。
/// - **无过渡换页**（[jumpToken] 变化）：给「一步进详情」这类场景用——那一帧
///   就要看到详情，中间不能先露出列表。
class SubPageSwitcher extends StatefulWidget {
  const SubPageSwitcher({
    super.key,
    required this.child,
    this.jumpToken = 0,
    this.duration = const Duration(milliseconds: 180),
    this.switchInCurve = Curves.easeOutCubic,
    this.switchOutCurve = Curves.easeInCubic,
  });

  /// 当前要显示的页面；key 变了即视为换页
  final Widget child;

  /// 变一次就「直接换页、不过渡」一次（见类注释）
  final int jumpToken;

  final Duration duration;
  final Curve switchInCurve;
  final Curve switchOutCurve;

  @override
  State<SubPageSwitcher> createState() => _SubPageSwitcherState();
}

class _SubPageSwitcherState extends State<SubPageSwitcher>
    with TickerProviderStateMixin {
  /// 位移只给 1.5%（约 10px）：淡入一点点上浮就够，别做成整页平移
  static final Tween<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.015),
    end: Offset.zero,
  );

  late _Entry _current;

  /// 正在淡出的旧页面；跑完就丢掉，树里只留一份
  final List<_Entry> _outgoing = <_Entry>[];

  int _jumpToken = 0;

  @override
  void initState() {
    super.initState();
    _jumpToken = widget.jumpToken;
    _current = _createEntry(widget.child, value: 1);
  }

  @override
  void dispose() {
    _disposeEntry(_current);
    for (final _Entry entry in _outgoing) {
      _disposeEntry(entry);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(SubPageSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _current.controller.duration = widget.duration;
      for (final _Entry entry in _outgoing) {
        entry.controller.duration = widget.duration;
      }
    }
    if (widget.jumpToken != _jumpToken) {
      _jumpToken = widget.jumpToken;
      _jumpTo(widget.child);
      return;
    }
    if (Widget.canUpdate(_current.child, widget.child)) {
      // 同一个页面换了内容（数据刷新）：原地更新，不做过场
      _current.child = widget.child;
      return;
    }
    _switchTo(widget.child);
  }

  _Entry _createEntry(Widget child, {required double value}) {
    final AnimationController controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: value,
    );
    return _Entry(
      child: child,
      controller: controller,
      animation: CurvedAnimation(
        parent: controller,
        curve: widget.switchInCurve,
        reverseCurve: widget.switchOutCurve,
      ),
    );
  }

  /// 换页并播放过渡：新页面淡入、旧页面淡出
  void _switchTo(Widget child) {
    _outgoing.add(_current);
    final _Entry next = _createEntry(child, value: 0);
    _current = next;
    next.controller.forward();

    final _Entry leaving = _outgoing.last;
    leaving.controller.reverse();
    leaving.controller.addStatusListener((AnimationStatus status) {
      if (status != AnimationStatus.dismissed || leaving.disposed || !mounted) {
        return;
      }
      setState(() {
        _outgoing.remove(leaving);
        _disposeEntry(leaving);
      });
    });
  }

  /// 直接换页：丢掉所有在跑的过渡，新页面立刻满不透明
  void _jumpTo(Widget child) {
    for (final _Entry entry in _outgoing) {
      _disposeEntry(entry);
    }
    _outgoing.clear();
    if (Widget.canUpdate(_current.child, child)) {
      _current.child = child;
      _current.controller
        ..stop()
        ..value = 1;
      return;
    }
    _disposeEntry(_current);
    _current = _createEntry(child, value: 1);
  }

  void _disposeEntry(_Entry entry) {
    if (entry.disposed) {
      return;
    }
    entry.disposed = true;
    entry.animation.dispose();
    entry.controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final _Entry entry in _outgoing) _buildEntry(entry),
        _buildEntry(_current),
      ],
    );
  }

  Widget _buildEntry(_Entry entry) {
    return FadeTransition(
      opacity: entry.animation,
      child: SlideTransition(
        position: _slide.animate(entry.animation),
        child: entry.child,
      ),
    );
  }
}

class _Entry {
  _Entry({
    required this.child,
    required this.controller,
    required this.animation,
  });

  Widget child;
  final AnimationController controller;
  final CurvedAnimation animation;
  bool disposed = false;
}

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/material.dart';

import '../../../common/widgets/slim_slider.dart';
import '../../../common/widgets/wheel_step.dart';
import '../../../theme/tokens.dart';

/// 请播放条把音量浮层弹出来一下。
///
/// 音量条平时只在悬停时出现；用 Ctrl+↑ / Ctrl+↓ 调音量时若只换图标，
/// 看不出当前百分比。浮层本身仍归 [VolumeControl] 的 `OverlayPortal` 管，
/// 这里只发「展示一下」的信号，免得把控制器暴露给页面。
class VolumePanelPeek extends ChangeNotifier {
  void peek() => notifyListeners();
}

/// 音量：图标常驻，悬停弹出竖条滑块；点击图标仍是静音切换。
///
/// 竖条放浮层而不是常驻：播放条右侧宽度紧张（最小窗口只剩两百多像素），
/// 常驻滑块会把进度条挤到几乎没法拖。正在播放页同理——底栏要摆一串按钮，
/// 一条常驻的 120px 滑块是这个「繁杂感」的主要来源。
class VolumeControl extends StatefulWidget {
  const VolumeControl({
    super.key,
    required this.volume,
    required this.enabled,
    this.size = 40,
    this.iconSize = 20,
    this.onChanged,
    this.onToggleMute,
    this.peek,
    this.muteKey,
    this.sliderKey,
  });

  /// 两个页面各用自己的 key：同一进程里播放条和正在播放页同时存在，
  /// 共用一套 key 会让 `find.byKey` 撞车
  final Key? muteKey;
  final Key? sliderKey;

  final double volume;
  final bool enabled;

  /// 静音按钮边长，与其他按钮保持一致
  final double size;

  /// 图标尺寸；页面按钮比播放条大一号时传更大值，图标不该跟着盒子缩
  final double iconSize;

  final ValueChanged<double>? onChanged;
  final VoidCallback? onToggleMute;

  /// 键盘调音量的信号源；收到就弹一次浮层
  final VolumePanelPeek? peek;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  /// 指针是否停在按钮 / 浮层上；两者都不在时才收起
  bool _overButton = false;
  bool _overPanel = false;

  /// 收起延迟：从按钮移向浮层时会先经过一小段空隙，立刻收就没法用
  Timer? _hideTimer;

  /// 键盘调音量后浮层停留多久：足够看清百分比，又不至于一直挡着列表
  static const Duration _peekDuration = Duration(milliseconds: 1200);

  @override
  void initState() {
    super.initState();
    widget.peek?.addListener(_handlePeek);
  }

  @override
  void didUpdateWidget(covariant VolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peek != widget.peek) {
      oldWidget.peek?.removeListener(_handlePeek);
      widget.peek?.addListener(_handlePeek);
    }
  }

  @override
  void dispose() {
    widget.peek?.removeListener(_handlePeek);
    _hideTimer?.cancel();
    super.dispose();
  }

  /// 键盘调音量：弹一次浮层并停留一会儿，鼠标不在上面也会自动收起
  void _handlePeek() {
    if (!mounted || !widget.enabled || widget.onChanged == null) {
      return;
    }
    _hideTimer?.cancel();
    if (!_portal.isShowing) {
      _portal.show();
    }
    _hideTimer = Timer(_peekDuration, () {
      if (!mounted || _overButton || _overPanel) {
        return;
      }
      if (_portal.isShowing) {
        _portal.hide();
      }
    });
  }

  void _syncVisibility() {
    _hideTimer?.cancel();
    if (_overButton || _overPanel) {
      if (!_portal.isShowing) {
        _portal.show();
      }
      return;
    }
    _hideTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || _overButton || _overPanel) {
        return;
      }
      if (_portal.isShowing) {
        _portal.hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double level = widget.volume.clamp(0.0, 1.0);
    final bool showPanel = widget.enabled && widget.onChanged != null;

    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext context) => _panel(level),
      child: CompositedTransformTarget(
        link: _link,
        child: WheelStep(
          onStep: (int direction) => _nudge(direction * 0.05),
          child: MouseRegion(
            onEnter: showPanel
                ? (PointerEnterEvent _) {
                    _overButton = true;
                    _syncVisibility();
                  }
                : null,
            onExit: showPanel
                ? (PointerExitEvent _) {
                    _overButton = false;
                    _syncVisibility();
                  }
                : null,
            child: IconButton(
              key: widget.muteKey,
              onPressed: widget.enabled ? widget.onToggleMute : null,
              tooltip: level > 0 ? '静音' : '取消静音',
              iconSize: widget.iconSize,
              // 与其他播放条按钮同尺寸，否则图标间距会忽大忽小
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              constraints: BoxConstraints.tightFor(
                width: widget.size,
                height: widget.size,
              ),
              padding: EdgeInsets.zero,
              color: scheme.onSurfaceVariant,
              icon: Icon(switch (level) {
                <= 0 => Icons.volume_off,
                < 0.5 => Icons.volume_down,
                _ => Icons.volume_up,
              }),
            ),
          ),
        ),
      ),
    );
  }

  /// 滚轮步进：夹在 0..1，端点上不重复下发
  void _nudge(double delta) {
    final ValueChanged<double>? onChanged = widget.onChanged;
    if (!widget.enabled || onChanged == null) {
      return;
    }
    final double next = (widget.volume + delta).clamp(0.0, 1.0);
    if ((next - widget.volume).abs() < 0.001) {
      return;
    }
    onChanged(next);
  }

  Widget _panel(double level) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ThemeData theme = Theme.of(context);

    return Positioned(
      // 读数只写到滑块下面、不带百分号，
      width: 44,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        // 贴图标右侧对齐：图标在最右边时，居中对齐会让浮层超出窗口被裁
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(8, -8),
        child: MouseRegion(
          onEnter: (PointerEnterEvent _) {
            _overPanel = true;
            _syncVisibility();
          },
          onExit: (PointerExitEvent _) {
            _overPanel = false;
            _syncVisibility();
          },
          child: Material(
            elevation: 8,
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.xs,
                vertical: Spacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 36,
                    height: 120,
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SlimSlider(
                        key: widget.sliderKey,
                        value: level,
                        max: 1,
                        enabled: widget.enabled,
                        onChanged: widget.onChanged,
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '${(level * 100).round()}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

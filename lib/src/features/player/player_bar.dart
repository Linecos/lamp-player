import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../common/widgets/album_cover.dart';
import '../../common/widgets/cover_shape.dart';
import '../../common/widgets/slider_semantics_scope.dart';
import '../../common/widgets/wheel_step.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';
import 'spectrum_bars.dart';
import 'playback_mode.dart';
import 'playback_queue.dart';

/// 请播放条把音量浮层弹出来一下。
///
/// 音量条平时只在悬停时出现；用 Ctrl+↑ / Ctrl+↓ 调音量时若只换图标，
/// 看不出当前百分比。浮层本身仍归 `_VolumeControl` 的 `OverlayPortal` 管，
/// 这里只发「展示一下」的信号，免得把控制器暴露给页面。
class VolumePanelPeek extends ChangeNotifier {
  void peek() => notifyListeners();
}

/// 底部播放条：曲目信息、上一首 / 播放暂停 / 下一首、进度、音量与队列入口。
///
/// 布局是经典三段式：左「封面 + 曲名 / 迷你频谱」与右「时间 + 进度 +
/// 模式 + 音量」各占 flex 1（等宽），中间是三键 —— 两侧等宽，播放键才真正
/// 落在整条播放条的中轴上。
///
/// 右段宽度不够时逐级收：模式按钮 → 音量滑块 → 总时长，宽度永远先给进度条。
class PlayerBar extends StatelessWidget {
  /// 岛卡片高度，不含外边距。
  static const double cardHeight = 88;

  /// 卡片上方留的一点呼吸空间。
  static const double cardTopPadding = 8;

  /// 卡片底部外边距：岛贴窗口底，留一点呼吸空间。
  static const double cardBottomMargin = 12;

  /// 岛在窗口底部占用的总高度。
  ///
  /// 曲库页的列表把底部留白设成它 + 8：列表可以一直滚到岛下面（悬浮感），
  /// 但滚到底时最后一行停在岛上方，不会被压住。
  static const double occupiedHeight =
      cardTopPadding + cardHeight + cardBottomMargin;

  const PlayerBar({
    super.key,
    required this.isPlaying,
    required this.isAvailable,
    this.canSeek = true,
    required this.position,
    required this.duration,
    this.volume = 1,
    this.track,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.onSeekStart,
    this.onSeekChanged,
    this.onSeekEnd,
    this.onVolumeChanged,
    this.onToggleMute,
    this.onShowQueue,
    this.repeat = LoopMode.off,
    this.shuffle = false,
    this.onCyclePlayMode,
    this.onOpenNowPlaying,
    this.spectrum,
    this.volumePanelPeek,
  });

  /// 频谱数据：传了才在曲名右侧显示迷你条（测试不注入就不画）
  final ValueListenable<List<double>>? spectrum;

  /// 键盘调音量时用来弹出音量浮层；不传则只有悬停才显示
  final VolumePanelPeek? volumePanelPeek;

  final Track? track;
  final bool isPlaying;
  final bool isAvailable;

  /// 是否允许拖动进度：播放中 / 暂停中为 true，停止（含播完）为 false，
  /// 否则拖动只会改位置、播放键却从头重播。
  final bool canSeek;

  final double position;
  final double duration;

  /// 当前音量，`0.0..=1.0`。
  final double volume;

  final VoidCallback? onPlayPause;

  /// 上一首 / 下一首；为空或没有曲目时按钮禁用。
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// 打开播放队列面板。
  final VoidCallback? onShowQueue;

  final LoopMode repeat;
  final bool shuffle;

  /// 顺序 / 随机 / 列表循环 / 单曲循环四态轮换
  final VoidCallback? onCyclePlayMode;

  /// 开始拖动进度：上游应暂停位置轮询，否则轮询值会把滑块拉回去。
  final ValueChanged<double>? onSeekStart;

  /// 拖动中的预览位置（秒），用于让时间标签实时跟随。
  final ValueChanged<double>? onSeekChanged;

  /// 松手后的目标位置（秒）。
  final ValueChanged<double>? onSeekEnd;

  final ValueChanged<double>? onVolumeChanged;

  final VoidCallback? onToggleMute;

  /// 点封面 / 曲名打开「正在播放」页
  final VoidCallback? onOpenNowPlaying;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? current = track;
    final bool canControl = isAvailable && current != null;
    final double total = duration > 0 ? duration : 0;
    final double shown = position.clamp(0.0, total).toDouble();

    return Padding(
      // margin 必须放在外层：直接给 Container.margin 时，Column 的 loose
      // 约束会让 Row 先按整宽布局、再加 margin 外扩，右侧会被裁掉 16px
      padding: const EdgeInsets.fromLTRB(
        16,
        cardTopPadding,
        16,
        cardBottomMargin,
      ),
      child: SizedBox(
        height: cardHeight,
        // 整条播放条都能打开正在播放页，不只有左半段。
        //
        // 以前只有封面与曲名各自绑了 InkWell：左段的标题右侧 / 频谱区 /
        // 频谱两侧、右段时间与按钮之间的缝隙、卡片左右 14px 内边距全是死区。
        // 这里在卡片最外层兜一次底。按钮、滑块、InkWell 都在更深的层级，
        // 会先赢得手势竞争，所以点击行为与悬停高亮都不变，外层只接住空白。
        child: MouseRegion(
          cursor: current == null
              ? MouseCursor.defer
              : SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey<String>('player-bar-open-anywhere'),
            behavior: HitTestBehavior.opaque,
            onTap: current == null ? null : onOpenNowPlaying,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: scheme.outlineVariant),
                boxShadow: <BoxShadow>[
                  // 阴影向下收窄：offset 6 配 blur 18 会向上扩散 12px，
                  // 盖住列表最后一行的悬停高亮
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.06),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              // 底色在 Container 上，墨水层要单独垫一层透明 Material 才画得出来。
              child: Material(
                type: MaterialType.transparency,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _PlayerBarLeft(
                        track: current,
                        isPlaying: isPlaying,
                        isAvailable: isAvailable,
                        onOpenNowPlaying: onOpenNowPlaying,
                        spectrum: spectrum,
                      ),
                    ),
                    // 中段宽度固定、两侧 Expanded 等宽 → 三键落在整条中轴上
                    _center(context, canControl: canControl),
                    Expanded(
                      child: _right(
                        context,
                        canControl: canControl,
                        shown: shown,
                        total: total,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 中段：上一首 / 播放暂停 / 下一首
  Widget _center(BuildContext context, {required bool canControl}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _BarIconButton(
          icon: Icons.skip_previous,
          tooltip: '上一首 (Ctrl+←)',
          size: 36,
          onPressed: canControl ? onPrevious : null,
        ),
        IconButton.filled(
          onPressed: canControl ? onPlayPause : null,
          tooltip: isPlaying ? '暂停 (空格)' : '播放 (空格)',
          iconSize: 24,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        _BarIconButton(
          icon: Icons.skip_next,
          tooltip: '下一首 (Ctrl+→)',
          size: 36,
          onPressed: canControl ? onNext : null,
        ),
      ],
    );
  }

  /// 右段：时间 + 进度 + 随机 / 循环 / 队列 + 音量
  ///
  /// 三段式把右段压到最小窗口约 215px、默认窗口约 546px，全塞进去会挤爆，
  /// 所以按可用宽度分档：先收总时长，再收当前时间。音量条改成悬停浮层后
  /// 不占常驻宽度，模式与队列两个按钮始终保留（合并成菜单要点两下才能切模式）。
  Widget _right(
    BuildContext context, {
    required bool canControl,
    required double shown,
    required double total,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle timeStyle =
        (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        // 300 以下先收总时长：模式与队列各占一个按钮后右侧更挤，
        // 进度条是主操作，总时长还能从进度条末端推出来
        final bool showTotal = width >= 300;
        // 再窄连时间标签也去掉（窗口下限 900 时不会触发，纯兜底）
        final bool showTime = width >= 160;
        // 音量条改成悬停浮层后不再占常驻宽度：进度条吃掉这块宽度，
        // 右侧图标自然靠到岛的内边距上，和左段对称
        const double buttonSize = 32;

        return Row(
          children: <Widget>[
            if (showTime) ...<Widget>[
              Text(formatDuration(shown), style: timeStyle),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: SizedBox(
                // Slider 默认 48 高，压到 28 才塞得进 88 的播放条
                height: 28,
                child: _SlimSlider(
                  key: const ValueKey<String>('player-progress'),
                  value: shown,
                  max: total > 0 ? total : 1,
                  enabled: canControl && canSeek && total > 0,
                  onChangeStart: onSeekStart,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                ),
              ),
            ),
            if (showTotal) ...<Widget>[
              const SizedBox(width: 8),
              Text(formatDuration(total), style: timeStyle),
            ],
            const SizedBox(width: 4),
            // 播放模式与队列始终各占一个按钮：合并成菜单后要点两下才能切模式
            _BarIconButton(
              icon: playbackModeIcon(repeat, shuffle),
              tooltip: '播放模式：${playbackModeLabel(repeat, shuffle)}',
              size: buttonSize,
              selected: playbackModeActive(repeat, shuffle),
              onPressed: onCyclePlayMode,
            ),
            _BarIconButton(
              icon: Icons.queue_music,
              tooltip: '播放队列',
              size: buttonSize,
              onPressed: onShowQueue,
            ),
            const SizedBox(width: 4),
            _VolumeControl(
              volume: volume,
              enabled: isAvailable,
              size: buttonSize,
              onChanged: onVolumeChanged,
              onToggleMute: onToggleMute,
              peek: volumePanelPeek,
            ),
          ],
        );
      },
    );
  }
}

/// 左段：封面 + 曲名 / 艺术家，右侧是迷你频谱。
///
/// 这里原来还有一句「当前歌词」预览，占掉一半宽度。歌词在正在播放页有整屏
/// 可以看，播放条上那半行字既挤、又只在换行时闪一下；去掉之后这块宽度给了
/// 频谱——同样是「正在放什么」，但它是连续的，不跳字。
class _PlayerBarLeft extends StatelessWidget {
  const _PlayerBarLeft({
    required this.track,
    required this.isPlaying,
    required this.isAvailable,
    required this.onOpenNowPlaying,
    this.spectrum,
  });

  /// 迷你频谱的数据源；为空时不占位
  final ValueListenable<List<double>>? spectrum;

  final Track? track;
  final bool isPlaying;
  final bool isAvailable;

  final VoidCallback? onOpenNowPlaying;

  /// 封面边长
  static const double _coverSize = 56;

  /// 频谱至少要有这么宽才画：再窄曲名会被挤成几个字，柱子也连成一条线
  static const double _spectrumMinWidth = 340;

  /// 频谱宽度上限：再宽就成了半条播放条，和「迷你」两字不搭
  static const double _spectrumMaxWidth = 240;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? current = track;
    final String subtitle = current != null
        ? trackArtist(current)
        : (isAvailable ? '从曲库中选一首开始' : '播放引擎不可用');
    final ValueListenable<List<double>>? bands = spectrum;

    // widthFactor: 1 —— 让曲名这块按文字宽度收缩，而不是撑满整行：
    // 撑满的话右侧会留一大片空白，频谱被顶到最右边，看着像贴着播放键
    final Widget titleBlock = Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: InkWell(
        key: const ValueKey<String>('player-bar-open-now-playing-title'),
        borderRadius: BorderRadius.circular(12),
        hoverColor: scheme.onSurface.withValues(alpha: 0.08),
        onTap: current == null ? null : onOpenNowPlaying,
        // Align 让高亮收缩到文字块大小，而不是整行高度
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                current?.title ?? '尚未播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final bool showSpectrum = bands != null && width >= _spectrumMinWidth;
        // 频谱宽度：窗口很宽时也封顶，否则会拉成半条播放条，「迷你」就没了
        final double barsWidth = math.min(_spectrumMaxWidth, width * 0.45);
        // 曲名宽度上限：把封面、两侧间距、频谱和频谱两侧各 12 的留白都扣掉，
        // 长标题在这之前就省略，免得把频谱挤扁
        final double titleMax = math.max(
          0,
          width - _coverSize - 12 - 12 - barsWidth - 24,
        );

        return Row(
          children: <Widget>[
            // 封面可点：打开正在播放页（大封面 / 歌词）
            // 高亮只包封面本身：把 12px 间距放进 InkWell 会让高亮比封面
            // 宽出一截，看起来和封面错位
            ValueListenableBuilder<bool>(
              valueListenable: circularCovers,
              builder: (BuildContext context, bool circular, Widget? child) {
                return InkWell(
                  key: const ValueKey<String>('player-bar-open-now-playing'),
                  // 圆形封面时高亮也得是圆的，否则四角会露出方形底色
                  borderRadius: BorderRadius.circular(
                    circular ? _coverSize / 2 : 16,
                  ),
                  hoverColor: scheme.onSurface.withValues(alpha: 0.08),
                  onTap: current == null ? null : onOpenNowPlaying,
                  child: child,
                );
              },
              // Hero：打开正在播放页时封面从这里飞大、返回时飞回来。
              // 插值用普通 RectTween：`MaterialRectArcTween` 是四个角各自沿
              // 弧线挪，56px 飞到 340px 这种尺寸差会让宽高速度错开，
              // 中途变成竖长条；RectTween 是中心+尺寸线性，全程保持正方形。
              // 外面套一层边界：起飞 / 落地把占位换回封面时，脏区只到这一小块，
              // 不会把整个播放条（频谱、按钮）一起拖着重画
              child: RepaintBoundary(
                child: Hero(
                  tag: coverHeroTag,
                  createRectTween: (Rect? begin, Rect? end) =>
                      RectTween(begin: begin, end: end),
                  child: AlbumCover(
                    path: current?.coverPath,
                    size: _coverSize,
                    radius: 16,
                    playing: isPlaying,
                    // 56px 的小图用比大封面更短的过渡、更小的起缩比：幅度一大
                    // 就成了「从别处飞过来」，几乎只留淡入才自然
                    animateOnChange: true,
                    transitionDuration: const Duration(milliseconds: 300),
                    transitionScale: 1.04,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (showSpectrum) ...<Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: titleMax),
                child: titleBlock,
              ),
              const SizedBox(width: 12),
              // 频谱放在「曲名之后」剩下的整块空白正中间：两侧留白相等，
              // 才不会像被播放键挤在右边缘（原来按对半分，左边空一大片）
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: barsWidth,
                    height: 24,
                    child: SpectrumBars(
                      key: const ValueKey<String>('player-bar-spectrum'),
                      bands: bands,
                      height: 24,
                      barWidth: 3,
                      gap: 3,
                      // 铺满这块：柱子按可用宽度均分，24 段全用上
                      stretch: true,
                      minBar: 2,
                    ),
                  ),
                ),
              ),
            ] else
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: titleBlock,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 播放条上的紧凑图标按钮：默认 40×40，避免默认 48 把控件挤出去。
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.size = 40,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  /// 按钮边长：窄窗口收到 32
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      isSelected: selected,
      iconSize: 20,
      // shrinkWrap：M3 默认把点击区撑到 48，会顶破三段式的固定宽度
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      icon: Icon(
        icon,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 音量：图标常驻，悬停弹出竖条滑块；点击图标仍是静音切换。
///
/// 竖条放浮层而不是常驻：播放条右侧宽度紧张（最小窗口只剩两百多像素），
/// 常驻滑块会把进度条挤到几乎没法拖。
class _VolumeControl extends StatefulWidget {
  const _VolumeControl({
    required this.volume,
    required this.enabled,
    this.size = 40,
    this.onChanged,
    this.onToggleMute,
    this.peek,
  });

  final double volume;
  final bool enabled;

  /// 静音按钮边长，与其他按钮保持一致
  final double size;

  final ValueChanged<double>? onChanged;
  final VoidCallback? onToggleMute;

  /// 键盘调音量的信号源；收到就弹一次浮层
  final VolumePanelPeek? peek;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
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
  void didUpdateWidget(covariant _VolumeControl oldWidget) {
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
            onPressed: widget.enabled ? widget.onToggleMute : null,
            tooltip: level > 0 ? '静音' : '取消静音',
            iconSize: 20,
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
      // 不给宽度的话 Material 会吃满 overlay 的约束，变成一整块蒙版
      width: 56,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        // 贴图标右侧对齐：静音图标在最右边，居中对齐会让浮层超出窗口被裁
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
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '${(level * 100).round()}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 36,
                    height: 120,
                    child: WheelStep(
                      // 一格 10%：桌面播放器的常规粒度，拖拽仍是细调
                      onStep: (int direction) => _nudge(direction * 0.1),
                      // 竖过来：上端 100%，下端 0%
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: _SlimSlider(
                          key: const ValueKey<String>('player-volume'),
                          value: level,
                          max: 1,
                          enabled: widget.enabled,
                          onChanged: widget.onChanged,
                        ),
                      ),
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

/// 扁平滑块：播放条的 88px 高度塞不下默认尺寸的 Slider。
class _SlimSlider extends StatelessWidget {
  const _SlimSlider({
    super.key,
    required this.value,
    required this.max,
    required this.enabled,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double max;
  final bool enabled;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SliderThemeData base = SliderTheme.of(context);

    return SliderTheme(
      data: base.copyWith(
        trackHeight: 4,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        disabledActiveTrackColor: scheme.outlineVariant,
        disabledInactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        disabledThumbColor: scheme.outline,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: 7,
          disabledThumbRadius: 5,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: SliderSemanticsScope(
        child: Slider(
          value: value.clamp(0.0, max).toDouble(),
          max: max,
          onChangeStart: enabled ? onChangeStart : null,
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? onChangeEnd : null,
        ),
      ),
    );
  }
}

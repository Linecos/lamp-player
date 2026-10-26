import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../common/widgets/album_cover.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';
import 'playback_queue.dart';

/// 底部播放条：曲目信息、上一首 / 播放暂停 / 下一首、进度、音量与队列入口。
///
/// 布局是经典三段式：左「封面 + 曲名」与右「模式 + 音量」各占 flex 1（等宽），
/// 中间 flex 2 —— 两侧等宽，播放键才真正落在整条播放条的中轴上。以前左 3 右 4
/// 的分配让三键永远偏左。
///
/// 进度条放在中间三键下面而不是右侧：最小窗口（900 宽 + 侧栏展开）时每侧只有
/// 约 245px，右侧还要装时间、随机 / 循环 / 队列、音量，进度条会被挤到 100px
/// 以内；放进中间能拿到整条播放条一半的宽度。
class PlayerBar extends StatelessWidget {
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
    this.onToggleRepeat,
    this.onToggleShuffle,
    this.onOpenNowPlaying,
  });

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
  final VoidCallback? onToggleRepeat;
  final VoidCallback? onToggleShuffle;

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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        height: 88,
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
                Expanded(child: _left(context, current)),
                Expanded(
                  flex: 2,
                  child: _center(
                    context,
                    canControl: canControl,
                    shown: shown,
                    total: total,
                  ),
                ),
                Expanded(child: _right(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 左段：封面 + 曲名 / 艺术家
  Widget _left(BuildContext context, Track? current) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String subtitle = current != null
        ? trackArtist(current)
        : (isAvailable ? '从曲库中选一首开始' : '播放引擎不可用');

    return Row(
      children: <Widget>[
        // 封面可点：打开正在播放页（歌词 / 大封面）
        // 高亮只包封面本身：把 12px 间距放进 InkWell 会让高亮比封面
        // 宽出一截，看起来和封面错位
        InkWell(
          key: const ValueKey<String>('player-bar-open-now-playing'),
          borderRadius: BorderRadius.circular(16),
          hoverColor: scheme.onSurface.withValues(alpha: 0.08),
          onTap: current == null ? null : onOpenNowPlaying,
          child: AlbumCover(
            path: current?.coverPath,
            size: 56,
            radius: 16,
            playing: isPlaying,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
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
          ),
        ),
      ],
    );
  }

  /// 中段：三键 + 进度（时间标签与滑块同行）
  Widget _center(
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

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
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
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: <Widget>[
              Text(formatDuration(shown), style: timeStyle),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  // Slider 默认占 48 高，这里压到 28：三键 40 + 间距 2 + 28
                  // 正好塞进 88 的播放条
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
              const SizedBox(width: 8),
              Text(formatDuration(total), style: timeStyle),
            ],
          ),
        ),
      ],
    );
  }

  /// 右段：随机 / 循环 / 队列 + 音量
  ///
  /// 宽度按三段式分到约 1/4（最小窗口 900 + 侧栏展开时约 140），所以音量滑块
  /// 宽度直接吃剩余空间，而不是写死 88：写死时最小窗口会把这一行挤爆。
  Widget _right(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        // 210 以下把随机 / 循环收进溢出菜单，省出两个按钮的位置给音量；
        // 剩下的宽度全给滑块，上限 120，低于 24 就没法拖了，只留静音按钮。
        final bool compact = width < 210;
        final double buttonSize = compact ? 32 : 36;
        // 窄到连「菜单 + 队列 + 静音」都放不下时省掉队列（窗口下限 900 时不会
        // 触发，这里只是防止布局在极端宽度下溢出）
        final bool showQueue = width >= buttonSize * 3;
        final int buttonCount = (compact ? 2 : 3) + (showQueue ? 1 : 0);
        final double leftover = width - buttonSize * buttonCount;
        final double volumeWidth = leftover < 24
            ? 0
            : leftover.clamp(24.0, 120.0).toDouble();

        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (compact)
              _ModesMenu(
                size: buttonSize,
                shuffle: shuffle,
                repeat: repeat,
                onToggleShuffle: onToggleShuffle,
                onToggleRepeat: onToggleRepeat,
              )
            else ...<Widget>[
              _BarIconButton(
                icon: Icons.shuffle,
                tooltip: shuffle ? '关闭随机播放' : '随机播放',
                size: buttonSize,
                selected: shuffle,
                onPressed: onToggleShuffle,
              ),
              _BarIconButton(
                icon: repeat == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                tooltip: switch (repeat) {
                  LoopMode.off => '循环播放：关',
                  LoopMode.all => '循环播放：列表',
                  LoopMode.one => '循环播放：单曲',
                },
                size: buttonSize,
                selected: repeat != LoopMode.off,
                onPressed: onToggleRepeat,
              ),
            ],
            if (showQueue)
              _BarIconButton(
                icon: Icons.queue_music,
                tooltip: '播放队列',
                size: buttonSize,
                onPressed: onShowQueue,
              ),
            _VolumeControl(
              volume: volume,
              enabled: isAvailable,
              size: buttonSize,
              sliderWidth: volumeWidth,
              onChanged: onVolumeChanged,
              onToggleMute: onToggleMute,
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

/// 窄窗口下把随机 / 循环收进溢出菜单，省出两个按钮的位置给进度和音量
class _ModesMenu extends StatelessWidget {
  const _ModesMenu({
    required this.size,
    required this.shuffle,
    required this.repeat,
    this.onToggleShuffle,
    this.onToggleRepeat,
  });

  final double size;
  final bool shuffle;
  final LoopMode repeat;
  final VoidCallback? onToggleShuffle;
  final VoidCallback? onToggleRepeat;

  Future<void> _show(BuildContext context) async {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Rect rect = Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    final String? picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: 'shuffle',
          checked: shuffle,
          child: const Text('随机播放'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'repeat',
          checked: repeat != LoopMode.off,
          child: const Text('循环播放'),
        ),
      ],
    );
    // 用返回值分发，而不是菜单项自己的 onTap：后者在退出动画还没走完时就
    // 触发，状态一重建菜单会跟着闪一下。
    switch (picked) {
      case 'shuffle':
        onToggleShuffle?.call();
      case 'repeat':
        onToggleRepeat?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool active = shuffle || repeat != LoopMode.off;
    return _BarIconButton(
      icon: Icons.tune,
      tooltip: '播放模式',
      size: size,
      selected: active,
      onPressed: () => unawaited(_show(context)),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.volume,
    required this.enabled,
    this.size = 40,
    this.sliderWidth = 88,
    this.onChanged,
    this.onToggleMute,
  });

  final double volume;
  final bool enabled;

  /// 静音按钮边长，与其他按钮保持一致
  final double size;

  /// 滑块宽度：由右段剩余空间决定（上限 120），0 表示只留静音按钮
  final double sliderWidth;

  final ValueChanged<double>? onChanged;
  final VoidCallback? onToggleMute;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double level = volume.clamp(0.0, 1.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          onPressed: enabled ? onToggleMute : null,
          tooltip: level > 0 ? '静音' : '取消静音',
          iconSize: 20,
          // 与其他播放条按钮同尺寸，否则图标间距会忽大忽小
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          constraints: BoxConstraints.tightFor(width: size, height: size),
          padding: EdgeInsets.zero,
          color: scheme.onSurfaceVariant,
          icon: Icon(switch (level) {
            <= 0 => Icons.volume_off,
            < 0.5 => Icons.volume_down,
            _ => Icons.volume_up,
          }),
        ),
        if (sliderWidth > 0)
          SizedBox(
            width: sliderWidth,
            child: _SlimSlider(
              key: const ValueKey<String>('player-volume'),
              value: level,
              max: 1,
              enabled: enabled,
              onChanged: onChanged,
            ),
          ),
      ],
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
      child: Slider(
        value: value.clamp(0.0, max).toDouble(),
        max: max,
        onChangeStart: enabled ? onChangeStart : null,
        onChanged: enabled ? onChanged : null,
        onChangeEnd: enabled ? onChangeEnd : null,
      ),
    );
  }
}

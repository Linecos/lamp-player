import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';

/// 底部播放条：曲名、播放/暂停、进度拖动、音量调节。
///
/// 只负责展示与转发手势；seek / 音量的实际调用与节流由持有状态的页面负责。
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
    this.onSeekStart,
    this.onSeekChanged,
    this.onSeekEnd,
    this.onVolumeChanged,
    this.onToggleMute,
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

  /// 开始拖动进度：上游应暂停位置轮询，否则轮询值会把滑块拉回去。
  final ValueChanged<double>? onSeekStart;

  /// 拖动中的预览位置（秒），用于让时间标签实时跟随。
  final ValueChanged<double>? onSeekChanged;

  /// 松手后的目标位置（秒）。
  final ValueChanged<double>? onSeekEnd;

  final ValueChanged<double>? onVolumeChanged;

  final VoidCallback? onToggleMute;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? current = track;
    final bool canControl = isAvailable && current != null;
    final double total = duration > 0 ? duration : 0;
    final double shown = position.clamp(0.0, total).toDouble();

    final String subtitle = current != null
        ? trackArtist(current)
        : (isAvailable ? '从曲库中选一首开始' : '播放引擎不可用');

    return Container(
      height: 88,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.fromLTRB(14, 0, 16, 0),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          _BarCover(playing: isPlaying),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  current?.title ?? '尚未播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: canControl ? onPlayPause : null,
            tooltip: isPlaying ? '暂停' : '播放',
            iconSize: 26,
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      formatDuration(shown),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      formatDuration(total),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                _SlimSlider(
                  key: const ValueKey<String>('player-progress'),
                  value: shown,
                  max: total > 0 ? total : 1,
                  enabled: canControl && canSeek && total > 0,
                  onChangeStart: onSeekStart,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _VolumeControl(
            volume: volume,
            enabled: isAvailable,
            onChanged: onVolumeChanged,
            onToggleMute: onToggleMute,
          ),
        ],
      ),
    );
  }
}

class _BarCover extends StatelessWidget {
  const _BarCover({required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        playing ? Icons.graphic_eq : Icons.music_note,
        size: 26,
        color: playing ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.volume,
    required this.enabled,
    this.onChanged,
    this.onToggleMute,
  });

  final double volume;
  final bool enabled;
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
          color: scheme.onSurfaceVariant,
          icon: Icon(switch (level) {
            <= 0 => Icons.volume_off,
            < 0.5 => Icons.volume_down,
            _ => Icons.volume_up,
          }),
        ),
        SizedBox(
          width: 88,
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

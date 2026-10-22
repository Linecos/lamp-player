import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';

/// 底部播放条骨架：曲名、艺术家、播放/暂停、进度展示。
///
/// 进度拖动与音量属于 yjxnb1 的「音量进度交互」任务，这里只做只读进度，
/// 避免两个 PR 改同一个文件。
class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.isPlaying,
    required this.isAvailable,
    required this.position,
    required this.duration,
    this.track,
    this.onPlayPause,
  });

  final Track? track;
  final bool isPlaying;
  final bool isAvailable;
  final double position;
  final double duration;
  final VoidCallback? onPlayPause;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? current = track;
    final bool canControl = isAvailable && current != null;
    final double progress = duration > 0
        ? (position / duration).clamp(0.0, 1.0)
        : 0.0;

    final String subtitle = current != null
        ? trackArtist(current)
        : (isAvailable ? '从曲库中选一首开始' : '播放引擎不可用');

    return Container(
      height: 88,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      formatDuration(position),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      formatDuration(duration),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
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

import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';
import 'playback_queue.dart';

/// 播放队列面板：查看即将播放的曲目，直接跳播，并切换随机 / 循环。
Future<void> showPlaybackQueueDialog(
  BuildContext context, {
  required List<Track> tracks,
  required int currentIndex,
  required LoopMode repeat,
  required bool shuffle,
  required ValueChanged<int> onSelect,
  required ValueChanged<LoopMode> onRepeatChanged,
  required ValueChanged<bool> onShuffleChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => _PlaybackQueueDialog(
      tracks: tracks,
      currentIndex: currentIndex,
      repeat: repeat,
      shuffle: shuffle,
      onSelect: onSelect,
      onRepeatChanged: onRepeatChanged,
      onShuffleChanged: onShuffleChanged,
    ),
  );
}

class _PlaybackQueueDialog extends StatefulWidget {
  const _PlaybackQueueDialog({
    required this.tracks,
    required this.currentIndex,
    required this.repeat,
    required this.shuffle,
    required this.onSelect,
    required this.onRepeatChanged,
    required this.onShuffleChanged,
  });

  final List<Track> tracks;
  final int currentIndex;
  final LoopMode repeat;
  final bool shuffle;
  final ValueChanged<int> onSelect;
  final ValueChanged<LoopMode> onRepeatChanged;
  final ValueChanged<bool> onShuffleChanged;

  @override
  State<_PlaybackQueueDialog> createState() => _PlaybackQueueDialogState();
}

class _PlaybackQueueDialogState extends State<_PlaybackQueueDialog> {
  late LoopMode _repeat = widget.repeat;
  late bool _shuffle = widget.shuffle;

  void _cycleRepeat() {
    final LoopMode next = _repeat.next;
    setState(() => _repeat = next);
    widget.onRepeatChanged(next);
  }

  void _toggleShuffle() {
    final bool next = !_shuffle;
    setState(() => _shuffle = next);
    widget.onShuffleChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return AlertDialog(
      key: const ValueKey<String>('queue-dialog'),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
      contentPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: <Widget>[
          const Icon(Icons.queue_music, size: 22),
          const SizedBox(width: 10),
          const Expanded(child: Text('播放队列')),
          IconButton(
            isSelected: _shuffle,
            tooltip: _shuffle ? '关闭随机播放' : '随机播放',
            onPressed: _toggleShuffle,
            icon: const Icon(Icons.shuffle, size: 20),
          ),
          IconButton(
            isSelected: _repeat != LoopMode.off,
            tooltip: switch (_repeat) {
              LoopMode.off => '循环播放：关',
              LoopMode.all => '循环播放：列表',
              LoopMode.one => '循环播放：单曲',
            },
            onPressed: _cycleRepeat,
            icon: Icon(
              _repeat == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              size: 20,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        height: 420,
        child: widget.tracks.isEmpty
            ? Center(
                child: Text(
                  '队列还是空的，先从曲库播放一首',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.tracks.length,
                itemBuilder: (BuildContext context, int index) {
                  final Track track = widget.tracks[index];
                  final bool current = index == widget.currentIndex;
                  return ListTile(
                    key: ValueKey<String>('queue-item-$index'),
                    selected: current,
                    selectedTileColor: scheme.primaryContainer.withValues(
                      alpha: 0.35,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    leading: SizedBox(
                      width: 28,
                      child: Center(
                        child: current
                            ? Icon(
                                Icons.graphic_eq,
                                size: 18,
                                color: scheme.primary,
                              )
                            : Text(
                                '${index + 1}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                    title: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: current ? scheme.primary : null,
                      ),
                    ),
                    subtitle: Text(
                      trackArtist(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Text(
                      formatDuration(track.durationSecs),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    onTap: current
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.onSelect(index);
                          },
                  );
                },
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

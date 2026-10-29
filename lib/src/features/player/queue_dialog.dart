import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/formatters/duration.dart';
import '../../rust/api/model.dart';
import '../library/library_sort.dart';
import 'playback_queue.dart';

/// 播放队列面板：查看即将播放的曲目，直接跳播。打开时自动定位到当前曲目。
///
/// 面板直接读写传入的 [queue]：移除 / 清空立即生效，[onChanged] 让页面
/// 同步播放状态（移除当前曲目时切到下一首，清空时停下）。
Future<void> showPlaybackQueueDialog(
  BuildContext context, {
  required PlaybackQueue queue,
  required Future<void> Function() onChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        _PlaybackQueueDialog(queue: queue, onChanged: onChanged),
  );
}

class _PlaybackQueueDialog extends StatefulWidget {
  const _PlaybackQueueDialog({required this.queue, required this.onChanged});

  final PlaybackQueue queue;
  final Future<void> Function() onChanged;

  @override
  State<_PlaybackQueueDialog> createState() => _PlaybackQueueDialogState();
}

class _PlaybackQueueDialogState extends State<_PlaybackQueueDialog> {
  /// 行高：列表用 itemExtent 固定，滚动定位才能直接算出位置。
  ///
  /// 之前只按 72 估算、实际 ListTile 被主题的 compact 密度压到 64，
  /// 长队列里越算越偏，当前曲目会滚到可视区外面。
  static const double _itemExtent = 72;

  /// 列表上下各留的 padding
  static const double _listPadding = 4;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 打开面板时定位到当前曲目；队列很长时不用手动找。
  void _scrollToCurrent({bool animate = false}) {
    if (!_scroll.hasClients) {
      return;
    }
    final int index = widget.queue.index;
    if (index < 0) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    final double rowTop = _listPadding + index * _itemExtent;
    // 当前曲目放到可视区中间，首尾会被夹到列表两端
    final double target =
        (rowTop - (position.viewportDimension - _itemExtent) / 2).clamp(
          0.0,
          position.maxScrollExtent,
        );
    if (animate) {
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  /// 拖拽用的稳定 key：路径 + 同名第几次（队列允许同一首出现多次）
  String _slotKey(List<Track> tracks, int index) {
    final String path = tracks[index].path;
    int ordinal = 0;
    for (int i = 0; i < index; i += 1) {
      if (tracks[i].path == path) {
        ordinal += 1;
      }
    }
    return '$path#$ordinal';
  }

  Future<void> _removeAt(int index) async {
    final bool wasCurrent = widget.queue.removeAt(index);
    setState(() {});
    await widget.onChanged();
    if (!mounted) {
      return;
    }
    if (wasCurrent) {
      _scrollToCurrent(animate: true);
    }
  }

  Future<void> _clear() async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空播放队列？'),
        content: const Text('队列里的曲目不会被删除，只是不再排队。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    widget.queue.clear();
    setState(() {});
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<Track> tracks = widget.queue.tracks;
    final int currentIndex = widget.queue.index;

    return AlertDialog(
      key: const ValueKey<String>('queue-dialog'),
      // 子节点不允许画到 28px 圆角外面（主题里也统一设了，这里显式写明意图）
      clipBehavior: Clip.antiAlias,
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
      contentPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: <Widget>[
          const Icon(Icons.queue_music, size: 22),
          const SizedBox(width: 10),
          const Expanded(child: Text('播放队列')),
          IconButton(
            tooltip: '清空队列',
            onPressed: tracks.isEmpty ? null : () => unawaited(_clear()),
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        height: 420,
        // ListTile 的悬停 / 水波纹都画在最近的 Material 上。这里给列表一层
        // 自己的透明 Material，墨迹只会落在列表区域内，不会跑到标题或圆角外。
        child: Material(
          type: MaterialType.transparency,
          child: tracks.isEmpty
              ? Center(
                  child: Text(
                    '队列还是空的，先从曲库播放一首',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  child: ReorderableListView.builder(
                    scrollController: _scroll,
                    // 行高固定，_scrollToCurrent 才能算出准确位置
                    itemExtent: _itemExtent,
                    // 左右各留 8：选中色块才不会顶到弹窗两侧、被 28 圆角切掉
                    padding: const EdgeInsets.fromLTRB(
                      8,
                      _listPadding,
                      8,
                      _listPadding,
                    ),
                    itemCount: tracks.length,
                    buildDefaultDragHandles: false,
                    // newIndex 已扣掉被取走的那一行，直接交给队列
                    onReorderItem: (int from, int to) {
                      setState(() => widget.queue.move(from, to));
                      unawaited(widget.onChanged());
                    },
                    proxyDecorator:
                        (
                          Widget child,
                          int index,
                          Animation<double> animation,
                        ) => Material(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                          child: child,
                        ),
                    itemBuilder: (BuildContext context, int index) {
                      final Track track = tracks[index];
                      final bool current = index == currentIndex;
                      // 选中底色用 DecoratedBox 自己画，不用 selectedTileColor：
                      // 后者是画在 Material 上的墨迹，位置依赖 Material 坐标系，
                      // 曾出现高亮跑到弹窗左上角、露出直角方块的问题。
                      return KeyedSubtree(
                        key: ValueKey<String>(
                          'queue-slot-${_slotKey(tracks, index)}',
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: current
                                ? scheme.primaryContainer.withValues(
                                    alpha: 0.35,
                                  )
                                : null,
                            // 与其它列表行一致：通栏直角色块在圆角弹窗里很扎眼
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ListTile(
                            key: ValueKey<String>('queue-item-$index'),
                            selected: current,
                            contentPadding: const EdgeInsets.only(
                              left: 24,
                              right: 8,
                            ),
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
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
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
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  formatDuration(track.durationSecs),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontFeatures: const <FontFeature>[
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.grab,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      child: Icon(
                                        Icons.drag_indicator,
                                        size: 18,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '从队列移除',
                                  onPressed: () => unawaited(_removeAt(index)),
                                  iconSize: 18,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 36,
                                    height: 36,
                                  ),
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.close,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            onTap: current
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    widget.queue.jumpTo(index);
                                    unawaited(widget.onChanged());
                                  },
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

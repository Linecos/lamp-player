import 'package:flutter/material.dart';

import '../player/lyric_source.dart';

/// 「歌词来源优先级」弹窗：两条来源用六点抓手拖动排序，改完立刻回调。
///
/// 为什么不给整行做拖拽：整行可拖的话和点击、悬停抢手势，鼠标一动就走，
/// 很容易误拖。抓手单独占右侧一小块，只有按住它才开始拖。
Future<void> showLyricSourceOrderDialog(
  BuildContext context, {
  required List<LyricSource> order,
  required ValueChanged<List<LyricSource>> onChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        _LyricSourceOrderDialog(order: order, onChanged: onChanged),
  );
}

class _LyricSourceOrderDialog extends StatefulWidget {
  const _LyricSourceOrderDialog({required this.order, required this.onChanged});

  final List<LyricSource> order;
  final ValueChanged<List<LyricSource>> onChanged;

  @override
  State<_LyricSourceOrderDialog> createState() =>
      _LyricSourceOrderDialogState();
}

class _LyricSourceOrderDialogState extends State<_LyricSourceOrderDialog> {
  late final List<LyricSource> _order = <LyricSource>[...widget.order];

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      // onReorderItem 给的已经是「移走之后」的下标，不必再减一
      _order.insert(newIndex, _order.removeAt(oldIndex));
    });
    widget.onChanged(List<LyricSource>.unmodifiable(_order));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Dialog(
      key: const ValueKey<String>('lyric-source-dialog'),
      backgroundColor: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 4),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.swap_vert_rounded, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('歌词来源优先级', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '按住右侧的六点抓手拖动排序。排在上面的先用，读不到才退到下一个。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: _order.length,
                    onReorderItem: _onReorder,
                    // 都不用默认代理：它会在圆角卡片外面套一个直角 Material，露出
                    // 一块方正底色
                    proxyDecorator: (
                      Widget child,
                      int index,
                      Animation<double> animation,
                    ) => child,
                    itemBuilder: (BuildContext context, int index) {
                      final LyricSource source = _order[index];
                      return _SourceTile(
                        key: ValueKey<String>('lyric-source-${source.id}'),
                        source: source,
                        index: index,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条来源：图标 + 名字 + 出处说明 + 右侧六点抓手
class _SourceTile extends StatelessWidget {
  const _SourceTile({super.key, required this.source, required this.index});

  final LyricSource source;

  /// 在 [ReorderableListView] 里的下标，抓手拖拽要用
  final int index;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 底色交给 Material，水波纹才画得出来；圆角与描边在 Container 上
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: <Widget>[
                Icon(
                  source == LyricSource.sidecar
                      ? Icons.insert_drive_file_outlined
                      : Icons.album_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(source.title, style: theme.textTheme.bodyLarge),
                      const SizedBox(height: 2),
                      Text(
                        source.detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ReorderableDragStartListener(
                  index: index,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Tooltip(
                      message: '拖动排序',
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_indicator,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

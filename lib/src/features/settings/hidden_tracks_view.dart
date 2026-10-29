import 'package:flutter/material.dart';

import '../../common/common.dart';
import '../../rust/api/db.dart' as db;

/// 被隐藏的歌曲列表（纯展示，恢复动作交给外部）。
///
/// 行样式与曲库列表同源：同样的 40px 圆角封面、圆角 16 的悬停高亮、
/// 13 号等宽时长；列宽也照搬（曲名 flex 5、歌手·专辑 flex 3）。
/// 隐藏列表以前只有一行标题和歌手，长歌单里同名曲根本分不清，补封面最直接。
class HiddenTracksView extends StatelessWidget {
  const HiddenTracksView({
    super.key,
    required this.items,
    required this.onRestore,
  });

  final List<db.HiddenTrack> items;

  /// 点行或点「恢复」都走这里
  final ValueChanged<db.HiddenTrack> onRestore;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final db.HiddenTrack item = items[index];
        return _HiddenTrackRow(item: item, onRestore: () => onRestore(item));
      },
    );
  }
}

/// 一行：封面 + 曲名 + 歌手·专辑 + 时长 + 「恢复」。
class _HiddenTrackRow extends StatelessWidget {
  const _HiddenTrackRow({required this.item, required this.onRestore});

  final db.HiddenTrack item;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BorderRadius radius = BorderRadius.circular(16);

    final TextStyle? secondary = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final TextStyle? meta = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 13,
      color: scheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    final String title = item.title.isEmpty ? item.path : item.title;
    final String subtitle = <String>[
      item.artist,
      item.album,
    ].where((String part) => part.isNotEmpty).join(' · ');
    final String coverPath = item.coverPath;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onRestore,
          hoverColor: scheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              children: <Widget>[
                AlbumCover(
                  path: coverPath.isEmpty ? null : coverPath,
                  size: 40,
                  radius: 12,
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (subtitle.isNotEmpty) const SizedBox(width: 16),
                if (subtitle.isNotEmpty)
                  Expanded(
                    flex: 3,
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 56,
                  child: Text(
                    formatDuration(item.durationSecs),
                    textAlign: TextAlign.right,
                    style: meta,
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(onPressed: onRestore, child: const Text('恢复')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

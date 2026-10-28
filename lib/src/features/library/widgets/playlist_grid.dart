import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../../../rust/api/model.dart';

/// 歌单卡片上的操作。
enum PlaylistAction { rename, delete }

/// 歌单网格：封面占位 + 名称 + 曲目数 / 更新时间 + 操作菜单。
class PlaylistGridView extends StatelessWidget {
  const PlaylistGridView({
    super.key,
    required this.playlists,
    required this.onOpen,
    required this.onAction,
    this.storageKey,
  });

  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;
  final void Function(Playlist playlist, PlaylistAction action) onAction;
  final Key? storageKey;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: storageKey,
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 340,
        mainAxisExtent: 92,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) {
        final Playlist playlist = playlists[index];
        return _PlaylistCard(
          playlist: playlist,
          onOpen: () => onOpen(playlist),
          onAction: (PlaylistAction action) => onAction(playlist, action),
        );
      },
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.playlist,
    required this.onOpen,
    required this.onAction,
  });

  final Playlist playlist;
  final VoidCallback onOpen;
  final ValueChanged<PlaylistAction> onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onOpen,
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  // 32 外框 - 12 内边距 = 20，内外圆角才平行
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.queue_music,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${playlist.trackCount} 首 · 更新于 '
                      '${formatPlaylistUpdated(playlist.updatedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<PlaylistAction>(
                tooltip: '歌单操作',
                icon: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                onSelected: onAction,
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<PlaylistAction>>[
                      const PopupMenuItem<PlaylistAction>(
                        value: PlaylistAction.rename,
                        child: Text('重命名'),
                      ),
                      const PopupMenuItem<PlaylistAction>(
                        value: PlaylistAction.delete,
                        child: Text('删除歌单'),
                      ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Unix 秒 → `M月d日`（跨年时带年份）。
String formatPlaylistUpdated(PlatformInt64 timestamp) {
  final DateTime date = DateTime.fromMillisecondsSinceEpoch(
    timestamp.toInt() * 1000,
  );
  final DateTime now = DateTime.now();
  if (date.year == now.year) {
    return '${date.month}月${date.day}日';
  }
  return '${date.year}年${date.month}月${date.day}日';
}

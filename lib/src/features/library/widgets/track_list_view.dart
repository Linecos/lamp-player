import 'dart:async';

import 'package:flutter/material.dart';

import '../../../common/formatters/duration.dart';
import '../../../common/widgets/album_cover.dart';
import '../../../rust/api/model.dart';
import '../library_sort.dart';

/// 曲目右键菜单动作；具体行为由页面实现（测试里可只验证回调）。
enum TrackContextAction {
  play,
  playNext,
  addToQueue,
  toggleFavorite,
  addToPlaylist,
  revealInExplorer,
  copyPath,
}

/// 曲库列表：固定表头 + 虚拟滚动（`ListView.builder` + `itemExtent`）。
///
/// 只负责展示与点击回调，数据与播放由页面决定，因此可以在 `test/` 下
/// 用普通 `Track` 列表直接渲染，不依赖 Rust。
class TrackListView extends StatelessWidget {
  const TrackListView({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.playingPath,
    this.onRemove,
    this.favoritePaths = const <String>{},
    this.onToggleFavorite,
    this.onContextAction,
  });

  final List<Track> tracks;
  final ValueChanged<Track> onPlay;
  final String? playingPath;

  /// 提供后在行尾显示「更多」菜单，用于从歌单移除等操作。
  final ValueChanged<Track>? onRemove;

  /// 已收藏的路径集合，用于绘制爱心状态。
  final Set<String> favoritePaths;

  /// 提供后在行尾显示爱心按钮。
  final ValueChanged<Track>? onToggleFavorite;

  /// 提供后行内支持右键菜单（播放、下一首播放、加入歌单等）。
  final void Function(Track track, TrackContextAction action)? onContextAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showArtist = constraints.maxWidth >= 720;
        final bool showAlbum = constraints.maxWidth >= 900;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _TrackHeader(
              showArtist: showArtist,
              showAlbum: showAlbum,
              showMenu: onRemove != null,
              showFavorite: onToggleFavorite != null,
            ),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemExtent: 56,
                padding: EdgeInsets.zero,
                itemBuilder: (BuildContext context, int index) {
                  final Track track = tracks[index];
                  return _TrackRow(
                    track: track,
                    index: index,
                    playing: track.path == playingPath,
                    showArtist: showArtist,
                    showAlbum: showAlbum,
                    onPlay: () => onPlay(track),
                    onRemove: onRemove == null ? null : () => onRemove!(track),
                    favored: favoritePaths.contains(track.path),
                    onToggleFavorite: onToggleFavorite == null
                        ? null
                        : () => onToggleFavorite!(track),
                    onContextAction: onContextAction == null
                        ? null
                        : (TrackContextAction action) =>
                              onContextAction!(track, action),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({
    required this.showArtist,
    required this.showAlbum,
    required this.showMenu,
    required this.showFavorite,
  });

  final bool showArtist;
  final bool showAlbum;
  final bool showMenu;
  final bool showFavorite;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 32, child: Text('#', style: style)),
          const SizedBox(width: 40),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: Text('标题', style: style)),
          if (showArtist) Expanded(flex: 2, child: Text('艺术家', style: style)),
          if (showAlbum) Expanded(flex: 2, child: Text('专辑', style: style)),
          SizedBox(
            width: 64,
            child: Text('时长', textAlign: TextAlign.right, style: style),
          ),
          if (showFavorite) const SizedBox(width: 40),
          if (showMenu) const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.index,
    required this.playing,
    required this.showArtist,
    required this.showAlbum,
    required this.onPlay,
    this.onRemove,
    required this.favored,
    this.onToggleFavorite,
    this.onContextAction,
  });

  final Track track;
  final int index;
  final bool playing;
  final bool showArtist;
  final bool showAlbum;
  final VoidCallback onPlay;
  final VoidCallback? onRemove;
  final bool favored;
  final VoidCallback? onToggleFavorite;
  final ValueChanged<TrackContextAction>? onContextAction;

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    if (onContextAction == null) {
      return;
    }
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final TrackContextAction? selected = await showMenu<TrackContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<TrackContextAction>>[
        _menuItem(TrackContextAction.play, Icons.play_arrow, '播放'),
        _menuItem(TrackContextAction.playNext, Icons.playlist_play, '下一首播放'),
        _menuItem(TrackContextAction.addToQueue, Icons.queue_music, '添加到队列'),
        _menuItem(
          TrackContextAction.toggleFavorite,
          favored ? Icons.favorite : Icons.favorite_border,
          favored ? '取消收藏' : '收藏',
        ),
        _menuItem(
          TrackContextAction.addToPlaylist,
          Icons.playlist_add,
          '加入歌单…',
        ),
        const PopupMenuDivider(),
        _menuItem(
          TrackContextAction.revealInExplorer,
          Icons.folder_open,
          '在资源管理器中显示',
        ),
        _menuItem(TrackContextAction.copyPath, Icons.copy, '复制文件路径'),
      ],
    );
    if (selected != null) {
      onContextAction?.call(selected);
    }
  }

  PopupMenuItem<TrackContextAction> _menuItem(
    TrackContextAction action,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<TrackContextAction>(
      value: action,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final BorderRadius radius = BorderRadius.circular(16);

    final TextStyle? secondary = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: playing
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPlay,
          onSecondaryTapDown: onContextAction == null
              ? null
              : (TapDownDetails details) => unawaited(
                  _showContextMenu(context, details.globalPosition),
                ),
          hoverColor: scheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 32,
                  child: Center(
                    child: playing
                        ? Icon(
                            Icons.graphic_eq,
                            size: 18,
                            color: scheme.primary,
                          )
                        : Text(
                            '${index + 1}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                  ),
                ),
                AlbumCover(
                  path: track.coverPath,
                  size: 40,
                  radius: 12,
                  playing: playing,
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: playing ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                ),
                if (showArtist)
                  Expanded(
                    flex: 2,
                    child: Text(
                      trackArtist(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ),
                if (showAlbum)
                  Expanded(
                    flex: 2,
                    child: Text(
                      trackAlbum(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ),
                SizedBox(
                  width: 64,
                  child: Text(
                    formatDuration(track.durationSecs),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                if (onToggleFavorite != null)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      tooltip: favored ? '取消收藏' : '收藏',
                      padding: EdgeInsets.zero,
                      iconSize: 20,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      onPressed: onToggleFavorite,
                      icon: Icon(
                        favored ? Icons.favorite : Icons.favorite_border,
                        color: favored
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (onRemove != null)
                  SizedBox(
                    width: 40,
                    child: PopupMenuButton<String>(
                      tooltip: '更多操作',
                      icon: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      onSelected: (_) => onRemove!(),
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                            const PopupMenuItem<String>(
                              value: 'remove',
                              child: Text('从歌单中移除'),
                            ),
                          ],
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

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

/// 列表行被选中：`toggle` 表示 Ctrl / 复选框（切换该行），`range` 表示 Shift。
typedef TrackSelectCallback = void Function(
  Track track, {
  required bool toggle,
  required bool range,
});

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
    this.storageKey,
    this.selectionMode = false,
    this.selectedPaths = const <String>{},
    this.onSelect,
  });

  final List<Track> tracks;
  final ValueChanged<Track> onPlay;
  final String? playingPath;

  /// 滚动位置用的 key；不同分区传不同值，切页 / 重启后回到原位置。
  final Key? storageKey;

  /// 提供后在行尾显示「更多」菜单，用于从歌单移除等操作。
  final ValueChanged<Track>? onRemove;

  /// 已收藏的路径集合，用于绘制爱心状态。
  final Set<String> favoritePaths;

  /// 提供后在行尾显示爱心按钮。
  final ValueChanged<Track>? onToggleFavorite;

  /// 提供后行内支持右键菜单（播放、下一首播放、加入歌单等）。
  final void Function(Track track, TrackContextAction action)? onContextAction;

  /// 多选模式：行首显示复选框，点击行只改选择、不播放。
  final bool selectionMode;

  /// 已选中的路径集合。
  final Set<String> selectedPaths;

  /// 选择回调；为空时多选模式只展示复选框。
  final TrackSelectCallback? onSelect;

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
              showSelection: selectionMode,
            ),
            Expanded(
              child: ListView.builder(
                key: storageKey,
                itemCount: tracks.length,
                itemExtent: 56,
                // 底部留一点空：滚到底时最后一行不贴着播放岛，
                // 悬停高亮的圆角也不会被盖住
                padding: const EdgeInsets.only(bottom: 12),
                itemBuilder: (BuildContext context, int index) {
                  final Track track = tracks[index];
                  return _TrackRow(
                    track: track,
                    index: index,
                    playing: track.path == playingPath,
                    showArtist: showArtist,
                    showAlbum: showAlbum,
                    selectionMode: selectionMode,
                    selected: selectedPaths.contains(track.path),
                    onSelect: onSelect,
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
    required this.showSelection,
  });

  final bool showArtist;
  final bool showAlbum;
  final bool showMenu;
  final bool showFavorite;
  final bool showSelection;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          if (showSelection) const SizedBox(width: 40),
          // 行里的序号是居中的，列头也要居中，否则差半个字宽
          SizedBox(
            width: 32,
            child: Text('#', textAlign: TextAlign.center, style: style),
          ),
          const SizedBox(width: 40),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: Text('标题', style: style)),
          if (showArtist) ...<Widget>[
            const SizedBox(width: 16),
            Expanded(flex: 2, child: Text('艺术家', style: style)),
          ],
          if (showAlbum) ...<Widget>[
            const SizedBox(width: 16),
            Expanded(flex: 2, child: Text('专辑', style: style)),
          ],
          const SizedBox(width: 16),
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
    required this.selectionMode,
    required this.selected,
    this.onSelect,
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
  final bool selectionMode;
  final bool selected;
  final TrackSelectCallback? onSelect;
  final VoidCallback? onRemove;
  final bool favored;
  final VoidCallback? onToggleFavorite;
  final ValueChanged<TrackContextAction>? onContextAction;

  /// 多选模式下普通点击切换该行；Ctrl 切换、Shift 范围选择。
  ///
  /// 不在多选模式时按 Ctrl / Shift 点击也能直接进入多选。
  void _handleTap() {
    final bool ctrl = HardwareKeyboard.instance.isControlPressed;
    final bool shift = HardwareKeyboard.instance.isShiftPressed;
    if (selectionMode || ctrl || shift) {
      onSelect?.call(track, toggle: selectionMode || ctrl, range: shift);
      return;
    }
    onPlay();
  }

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

    // 序号与时长同档：13 + 等宽数字，跟着副列走但比正文小一号
    final TextStyle? meta = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 13,
      color: scheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
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
          onTap: _handleTap,
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
                if (selectionMode)
                  SizedBox(
                    width: 40,
                    child: Checkbox(
                      key: ValueKey<String>('track-select-${track.path}'),
                      value: selected,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: onSelect == null
                          ? null
                          : (_) => onSelect!(track, toggle: true, range: false),
                    ),
                  ),
                SizedBox(
                  width: 32,
                  child: Center(
                    child: playing
                        ? Icon(
                            Icons.graphic_eq,
                            size: 18,
                            color: scheme.primary,
                          )
                        : Text('${index + 1}', style: meta),
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
                if (showArtist) const SizedBox(width: 16),
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
                if (showAlbum) const SizedBox(width: 16),
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
                const SizedBox(width: 16),
                SizedBox(
                  width: 64,
                  child: Text(
                    formatDuration(track.durationSecs),
                    textAlign: TextAlign.right,
                    style: meta,
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

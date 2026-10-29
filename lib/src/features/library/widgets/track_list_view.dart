import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../../../common/formatters/duration.dart';
import '../../../common/widgets/album_cover.dart';
import '../../../rust/api/model.dart';
import '../../player/player_bar.dart';
import '../library_sort.dart';

/// 曲目右键菜单动作；具体行为由页面实现（测试里可只验证回调）。
enum TrackContextAction {
  play,
  playNext,
  addToQueue,
  toggleFavorite,
  addToPlaylist,

  /// 隐藏歌曲：移出曲库并记入隐藏列表，扫描时跳过；不删文件、不打断播放
  removeFromLibrary,
  revealInExplorer,
  copyPath,

  /// 用外部 MusicTag 编辑这首的标签
  openWithMusicTag,
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
///
/// 宽高变化（侧栏展开 / 收起每帧都在变宽）会走 `LayoutBuilder`：如果每次都
/// 重新 build 出新的 `ListView`，`SliverChildBuilderDelegate` 判定 builder 变了，
/// 可见行会整批重建——实测展开动画每帧 60~90ms。这里按「列可见性」缓存整棵
/// 子树：宽度变化但没跨过列阈值时返回**同一个 widget 实例**，Element 直接复用，
/// 只剩布局与绘制。
class TrackListView extends StatefulWidget {
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
    this.onReorder,
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

  /// 提供后每行末尾出现拖拽把手，列表可上下拖动改顺序（歌单手动排序）。
  ///
  /// `to` 是「取走该行之后」的插入位置，直接拿它落库即可。
  final void Function(int from, int to)? onReorder;

  @override
  State<TrackListView> createState() => _TrackListViewState();
}

class _TrackListViewState extends State<TrackListView> {
  /// 上一次按哪组列可见性构建的子树；仅用于跨「纯宽度变化」复用
  Widget? _cached;
  bool _cachedArtist = false;
  bool _cachedAlbum = false;

  List<Track> get tracks => widget.tracks;
  ValueChanged<Track> get onPlay => widget.onPlay;
  String? get playingPath => widget.playingPath;
  Key? get storageKey => widget.storageKey;
  ValueChanged<Track>? get onRemove => widget.onRemove;
  Set<String> get favoritePaths => widget.favoritePaths;
  ValueChanged<Track>? get onToggleFavorite => widget.onToggleFavorite;
  void Function(Track, TrackContextAction)? get onContextAction =>
      widget.onContextAction;
  bool get selectionMode => widget.selectionMode;
  Set<String> get selectedPaths => widget.selectedPaths;
  TrackSelectCallback? get onSelect => widget.onSelect;
  void Function(int from, int to)? get onReorder => widget.onReorder;

  @override
  void didUpdateWidget(covariant TrackListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据 / 选择 / 回调变了：缓存必须作废，否则会显示旧内容
    _cached = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showArtist = constraints.maxWidth >= 720;
        final bool showAlbum = constraints.maxWidth >= 900;
        final Widget? cached = _cached;
        if (cached != null &&
            showArtist == _cachedArtist &&
            showAlbum == _cachedAlbum) {
          return cached;
        }
        _cachedArtist = showArtist;
        _cachedAlbum = showAlbum;
        _cached = _build(context, showArtist, showAlbum);
        return _cached!;
      },
    );
  }

  Widget _build(BuildContext context, bool showArtist, bool showAlbum) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _TrackHeader(
          showArtist: showArtist,
          showAlbum: showAlbum,
          showMenu: onRemove != null,
          showFavorite: onToggleFavorite != null,
          showSelection: selectionMode,
          showHandle: onReorder != null,
        ),
        Expanded(
          child: onReorder == null
              ? ListView.builder(
                  key: storageKey,
                  itemCount: tracks.length,
                  itemExtent: 56,
                  // 列表铺到窗口底，行可以从播放岛下面穿过；留白保证滚到底时
                  // 最后一行停在岛上方，悬停高亮的圆角也不会被压住
                  padding: const EdgeInsets.only(
                    bottom: PlayerBar.occupiedHeight + 8,
                  ),
                  itemBuilder: (BuildContext context, int index) =>
                      _rowAt(index, showArtist, showAlbum),
                )
              // 可拖拽排序：行自己带 key，拖拽把手只在行尾，点击仍然是播放
              : ReorderableListView.builder(
                  key: storageKey,
                  itemCount: tracks.length,
                  itemExtent: 56,
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(
                    bottom: PlayerBar.occupiedHeight + 8,
                  ),
                  // onReorderItem 的 newIndex 已经扣掉被取走的那一行
                  onReorderItem: onReorder!,
                  proxyDecorator:
                      (Widget child, int index, Animation<double> animation) =>
                          Material(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(16),
                            child: child,
                          ),
                  itemBuilder: (BuildContext context, int index) =>
                      KeyedSubtree(
                        key: ValueKey<String>(tracks[index].path),
                        child: _rowAt(index, showArtist, showAlbum),
                      ),
                ),
        ),
      ],
    );
  }

  Widget _rowAt(int index, bool showArtist, bool showAlbum) {
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
          : (TrackContextAction action) => onContextAction!(track, action),
      dragIndex: onReorder == null ? null : index,
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
    this.showHandle = false,
  });

  final bool showArtist;
  final bool showAlbum;
  final bool showMenu;
  final bool showFavorite;
  final bool showSelection;
  final bool showHandle;

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
          if (showHandle) const SizedBox(width: 36),
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
    this.dragIndex,
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

  /// 非空表示这一行可拖拽排序，值是该行在当前列表里的下标
  final int? dragIndex;

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
        _menuItem(
          TrackContextAction.removeFromLibrary,
          Icons.visibility_off_outlined,
          '隐藏歌曲',
        ),
        const PopupMenuDivider(),
        _menuItem(
          TrackContextAction.revealInExplorer,
          Icons.folder_open,
          '在资源管理器中显示',
        ),
        _menuItem(TrackContextAction.copyPath, Icons.copy, '复制文件路径'),
        const PopupMenuDivider(),
        _menuItem(
          TrackContextAction.openWithMusicTag,
          Icons.sell_outlined,
          '用 MusicTag 打开',
        ),
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
        // 不裁剪：每行一个 ClipRRect 就是一层裁剪层，滚动 / 变宽时整行都要
        // 重新裁剪；圆角高亮与墨迹交给 InkWell 的 borderRadius 约束。
        clipBehavior: Clip.none,
        child: InkWell(
          borderRadius: radius,
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
                if (dragIndex != null)
                  SizedBox(
                    width: 36,
                    height: 40,
                    child: ReorderableDragStartListener(
                      index: dragIndex!,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
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
